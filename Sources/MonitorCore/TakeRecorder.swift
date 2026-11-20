import AVFoundation
import CoreMedia

/// Grava no Mac uma cópia do stream que chega do iPhone, sem recodificar: o HEVC e o AAC vão
/// do jeito que vieram para um `.mov`. O áudio opcional do Mac é codificado em AAC.
/// A imagem tem a qualidade do stream (resolução da câmera, 8 Mb/s), não
/// o arquivo original do iPhone.
///
/// Tudo roda numa fila própria: quem recebe o stream só entrega e volta. O vídeo vai para a
/// tela antes de chegar aqui, então a cópia não soma atraso ao monitor.
///
/// O REC chega pela rede depois que a câmera já começou a gravar, e o stream vem uns 0,3 s
/// atrás. Por isso a cópia guarda o vídeo desde o último quadro-chave (o arquivo começa um
/// pouco antes do REC) e continua `tail` segundos depois do STOP.
public final class TakeRecorder {
    public enum MicrophoneMode: String, CaseIterable, Identifiable {
        case replace, separate, both

        public var id: String { rawValue }
    }

    private enum RecordingError: LocalizedError {
        case noVideo, noMicrophone, interruptedMicrophone, noPhoneAudio

        var errorDescription: String? {
            switch self {
            case .noVideo: String(localized: "Nenhum quadro de vídeo chegou para a cópia.")
            case .noMicrophone: String(localized: "A cópia não recebeu áudio do microfone do Mac.")
            case .interruptedMicrophone: String(localized: "A cópia foi salva com interrupções no áudio do Mac.")
            case .noPhoneAudio: String(localized: "A cópia foi salva sem uma trilha de áudio do iPhone.")
            }
        }
    }
    /// Chamado na thread principal quando um arquivo fecha: o endereço e o erro, se houve.
    public var onFinish: ((URL, Error?) -> Void)?
    public var onWarning: ((String) -> Void)?
    /// Segundos que a cópia continua depois de `end()`.
    public let tail: TimeInterval

    private let queue = DispatchQueue(label: "bmonitor.take-recorder", qos: .utility)

    // Tudo abaixo só é tocado na fila.
    /// Vídeo desde o último quadro-chave, para o arquivo começar antes do REC.
    private var preroll: [CMSampleBuffer] = []
    /// Áudio dos últimos segundos, já com formato e PTS de cada quadro AAC.
    private var audioPreroll: [CMSampleBuffer] = []
    private var audioFormat: CMAudioFormatDescription?
    private var audioConfig: [Int] = []
    private var microphoneMode: MicrophoneMode?
    private var microphoneDelay: CMTime = .zero
    private var microphonePreroll: [CMSampleBuffer] = []
    private var microphoneSync = MicrophoneSync()
    private var take: Take?
    /// Pedido de gravar ainda sem arquivo: espera o próximo quadro-chave.
    private var armed: (url: URL, quarterTurns: Int, part: Int)?
    private var stopping = false
    private var lastSeenVideo = CMTime.negativeInfinity

    private struct Take {
        var writer: AVAssetWriter
        var video: AVAssetWriterInput
        var audio: AVAssetWriterInput?
        var microphone: AVAssetWriterInput?
        var sidecar: AVAssetWriter?
        var lastMicrophone: CMTime = .negativeInfinity
        var microphoneGap = false
        var expectsPhoneAudio = false
        /// Modo do microfone no começo do take; trocar no meio não muda este arquivo.
        var mode: MicrophoneMode?
        var format: CMFormatDescription
        var start: CMTime
        var lastVideo: CMTime
        var lastAudio: CMTime = .negativeInfinity
        var url: URL
        /// Endereço pedido em `begin`, de onde saem os nomes das continuações.
        var base: URL
        var quarterTurns: Int
        var part: Int
    }

    public init(tail: TimeInterval = 1) {
        self.tail = tail
    }

    /// Começa um arquivo em `url`, a partir do último quadro-chave já recebido.
    /// `quarterTurns` grava a rotação do monitor no arquivo, para o take em pé abrir em pé.
    public func begin(url: URL, quarterTurns: Int) {
        queue.async { [self] in
            if take != nil { close() }
            cancelArmed()
            stopping = false
            armed = (url, quarterTurns, 1)
            if let key = preroll.first, Self.isKeyframe(key) { open(at: key) }
        }
    }

    /// Fecha o arquivo depois de `tail` segundos.
    public func end() {
        queue.async { [self] in
            cancelArmed()
            guard let url = take?.url else { return }
            stopping = true
            queue.asyncAfter(deadline: .now() + tail) { [self] in
                if stopping, take?.url == url { close() }
            }
        }
    }

    /// Fecha já e espera o arquivo ficar pronto. Para o encerramento do app.
    public func endBlocking(timeout: TimeInterval = 3) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            cancelArmed()
            stopping = false
            if take != nil { close { done.signal() } } else { done.signal() }
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Um quadro de vídeo já pronto para o decodificador (NAL com tamanho de 4 bytes).
    public func appendVideo(_ sample: CMSampleBuffer, keyframe: Bool) {
        appendVideo(sample, keyframe: keyframe, hostTime: CMClock.hostTimeClock.time)
    }

    func appendVideo(_ sample: CMSampleBuffer, keyframe: Bool, hostTime: CMTime) {
        queue.async { [self] in video(sample, keyframe: keyframe, hostTime: hostTime) }
    }

    /// Um PES de áudio com seus quadros ADTS.
    public func appendAudio(_ unit: AudioAccessUnit) {
        queue.async { [self] in audio(unit) }
    }

    func configureMicrophone(_ mode: MicrophoneMode?, delay: CMTime, resetInput: Bool = false) -> Bool {
        queue.sync {
            guard take == nil, armed == nil else { return false }
            microphoneMode = mode
            if resetInput || mode == nil || delay != microphoneDelay { microphonePreroll.removeAll() }
            microphoneDelay = delay
            return true
        }
    }

    func appendMicrophone(_ sample: CMSampleBuffer, hostTime: CMTime) {
        guard sample.numSamples > 0 else { return }
        queue.async { [self] in
            guard microphoneMode != nil,
                let pts = microphoneSync.presentationTime(for: hostTime, delay: microphoneDelay),
                var timing = try? sample.sampleTimingInfo(at: 0)
            else { return }
            timing.presentationTimeStamp = pts
            timing.decodeTimeStamp = .invalid
            var retimed: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed
            ) == noErr, let retimed else { return }
            bufferAudio(retimed, in: &microphonePreroll)
            writeAudio(retimed, microphone: true)
        }
    }

    private func cancelArmed() {
        if microphoneMode != nil, let armed { finished(armed.url, RecordingError.noVideo) }
        armed = nil
    }

    // MARK: - Na fila

    private func video(_ sample: CMSampleBuffer, keyframe: Bool, hostTime: CMTime) {
        Self.markSync(sample, keyframe: keyframe)
        let pts = sample.presentationTimeStamp
        // O pré-roll só vale do quadro-chave em diante e no mesmo relógio.
        if keyframe || pts <= lastSeenVideo { preroll.removeAll() }
        let clockReset = microphoneSync.observe(video: pts, arrival: hostTime)
        if clockReset { microphonePreroll.removeAll() }
        lastSeenVideo = pts
        if !preroll.isEmpty || keyframe { preroll.append(sample) }
        // Teto de memória se os quadros-chave sumirem: a cópia espera o próximo.
        if preroll.count > 900 { preroll.removeAll() }

        if var current = take {
            guard let format = sample.formatDescription else { return }
            // Stream reiniciado (o relógio voltou) ou formato novo: este arquivo fecha e o
            // take continua num arquivo "(2)" a partir do próximo quadro-chave.
            if pts <= current.lastVideo || !CMFormatDescriptionEqual(format, otherFormatDescription: current.format) {
                let next = (current.base, current.quarterTurns, current.part + 1)
                let continues = !stopping
                close()
                if continues { armed = next }
                if keyframe, armed != nil { open(at: sample) }
                return
            }
            if current.video.isReadyForMoreMediaData, current.video.append(sample) {
                current.lastVideo = pts
                take = current
            }
        } else if keyframe, armed != nil {
            open(at: sample)
        }
    }

    private func audio(_ unit: AudioAccessUnit) {
        guard let base = unit.pts else { return }
        var offset: Int64 = 0
        for frame in AudioDecoder.adtsFrames(unit.data) {
            guard let sample = audioSample(frame, pts: CMTime(value: base, timescale: 90_000) + CMTime(value: offset, timescale: Int32(frame.sampleRate)))
            else { continue }
            offset += 1024
            bufferAudio(sample, in: &audioPreroll)
            writeAudio(sample, microphone: false)
        }
    }

    private func bufferAudio(_ sample: CMSampleBuffer, in samples: inout [CMSampleBuffer]) {
        samples.append(sample)
        if samples.count > 500 { samples.removeFirst(samples.count - 500) }
    }

    private func writeAudio(_ sample: CMSampleBuffer, microphone: Bool) {
        guard var current = take, let input = microphone ? current.microphone : current.audio else { return }
        let last = microphone ? current.lastMicrophone : current.lastAudio
        let pts = sample.presentationTimeStamp
        guard pts >= current.start, pts > last, input.isReadyForMoreMediaData, input.append(sample) else { return }
        if microphone {
            let previous = last.isNumeric ? last : current.start
            if (pts - previous).seconds > 1 { current.microphoneGap = true }
            current.lastMicrophone = pts
        } else {
            current.lastAudio = pts
        }
        take = current
    }

    private func open(at keyframe: CMSampleBuffer) {
        guard let armed, let format = keyframe.formatDescription else { return }
        self.armed = nil
        var part = armed.part
        var url = part == 1 ? armed.url : Self.partURL(armed.url, part)
        // O AVAssetWriter falha se o arquivo existe: a continuação pula para o próximo número livre.
        while FileManager.default.fileExists(atPath: url.path)
            || (microphoneMode != nil && FileManager.default.fileExists(atPath: Self.microphoneURL(url).path))
        {
            part += 1
            url = Self.partURL(armed.url, part)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Fragmentos a cada 2 s: se o app cair no meio do take, o que já foi gravado abre.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            video.expectsMediaDataInRealTime = true
            let size = CMVideoFormatDescriptionGetDimensions(format)
            video.transform = Self.transform(quarterTurns: armed.quarterTurns, width: CGFloat(size.width), height: CGFloat(size.height))
            writer.add(video)
            var audio: AVAssetWriterInput?
            var sidecar: AVAssetWriter?
            // O microfone do Mac vai sempre para um arquivo ao lado, em PCM: é dele que sai o som
            // do take e é ele que depois se junta ao original do iPhone.
            if microphoneMode != nil {
                sidecar = try AVAssetWriter(outputURL: Self.microphoneURL(url), fileType: .mov)
            }
            // O som do iPhone entra até no modo substituir: é a referência que sincroniza o Mac,
            // e a junção no fim do take tira a trilha.
            if let audioFormat {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                input.expectsMediaDataInRealTime = true
                if microphoneMode != nil { input.metadata = Self.trackTitle("iPhone") }
                if writer.canAdd(input) {
                    writer.add(input)
                    audio = input
                }
            }
            var microphone: AVAssetWriterInput?
            if microphoneMode != nil {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                input.expectsMediaDataInRealTime = true
                input.metadata = Self.trackTitle("Mac Microphone")
                let destination = sidecar ?? writer
                guard destination.canAdd(input) else { throw CocoaError(.featureUnsupported) }
                destination.add(input)
                microphone = input
            }
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            if let sidecar, !sidecar.startWriting() {
                writer.cancelWriting()
                throw sidecar.error ?? CocoaError(.fileWriteUnknown)
            }
            let start = keyframe.presentationTimeStamp
            writer.startSession(atSourceTime: start)
            sidecar?.startSession(atSourceTime: start)
            take = Take(
                writer: writer, video: video, audio: audio, microphone: microphone, sidecar: sidecar,
                expectsPhoneAudio: microphoneMode == .both, mode: microphoneMode, format: format, start: start, lastVideo: .negativeInfinity,
                url: url, base: armed.url, quarterTurns: armed.quarterTurns, part: part)
            print("cópia no Mac: gravando \(url.lastPathComponent)")
        } catch {
            print("cópia no Mac: não abriu \(url.path): \(error)")
            finished(url, error)
            return
        }
        // O que já chegou desde o quadro-chave entra agora.
        let held = preroll.first === keyframe ? preroll : [keyframe]
        for sample in held where sample.presentationTimeStamp >= start(of: take) {
            guard var current = take, current.video.isReadyForMoreMediaData, current.video.append(sample) else { continue }
            current.lastVideo = sample.presentationTimeStamp
            take = current
        }
        for sample in audioPreroll { writeAudio(sample, microphone: false) }
        for sample in microphonePreroll { writeAudio(sample, microphone: true) }
    }

    private static func trackTitle(_ title: String) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        return [item]
    }

    static func microphoneURL(_ movie: URL) -> URL {
        movie.deletingLastPathComponent()
            .appendingPathComponent(movie.deletingPathExtension().lastPathComponent + " - Mac Mic.mov")
    }

    private func start(of take: Take?) -> CMTime { take?.start ?? .positiveInfinity }

    private func close(_ completion: (() -> Void)? = nil) {
        guard let current = take else {
            completion?()
            return
        }
        take = nil
        stopping = false
        let writers = [current.writer, current.sidecar].compactMap { $0 }
        let group = DispatchGroup()
        for writer in writers where writer.status == .writing {
            group.enter()
            writer.finishWriting { group.leave() }
        }
        group.notify(queue: queue) { [self] in
            let failedWriter = writers.first { $0.status != .completed }
            let audioError: RecordingError?
            if current.microphone != nil && !current.lastMicrophone.isNumeric {
                audioError = .noMicrophone
            } else if current.microphone != nil
                && (current.microphoneGap || (current.lastVideo - current.lastMicrophone).seconds > 1)
            {
                audioError = .interruptedMicrophone
            } else if current.expectsPhoneAudio && !current.lastAudio.isNumeric {
                audioError = .noPhoneAudio
            } else {
                audioError = nil
            }
            let error = failedWriter.map { $0.error ?? CocoaError(.fileWriteUnknown) }
            let report = { [self] (warning: String?) in
                finished(failedWriter?.outputURL ?? current.url, error)
                if error == nil, let warning = warning ?? audioError?.errorDescription {
                    DispatchQueue.main.async { [onWarning] in onWarning?(warning) }
                }
                completion?()
            }
            guard error == nil, let mode = current.mode, mode != .separate, current.lastMicrophone.isNumeric else {
                report(nil)
                return
            }
            Task.detached { [queue] in
                let warning = await Self.mergeMicrophone(into: current.url, keepPhoneAudio: mode == .both)
                queue.async { report(warning) }
            }
        }
    }

    /// Junta o microfone do Mac ao vídeo do take, alinhado pelo som do iPhone. Os dois já estão
    /// na mesma linha do tempo pelo relógio (`MicrophoneSync`); a comparação corrige o atraso
    /// da rede, que o relógio não vê. Se não juntar, os dois arquivos ficam como estão.
    static func mergeMicrophone(into movie: URL, keepPhoneAudio: Bool) async -> String? {
        let microphone = microphoneURL(movie)
        do {
            let folder = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: movie, create: true)
            let merged = folder.appendingPathComponent(movie.lastPathComponent)
            defer { try? FileManager.default.removeItem(at: folder) }
            let result = try await MacAudioMerger.merge(
                video: movie, microphone: microphone, output: merged, keepPhoneAudio: keepPhoneAudio,
                expectedOffset: 0, window: 1)
            _ = try FileManager.default.replaceItemAt(movie, withItemAt: merged)
            print("cópia no Mac: microfone em \(String(format: "%+.3f", result.offset)) s, confiança \(result.confidence.map { String(format: "%.1f", $0) } ?? "-")")
            return result.synced
                ? nil
                : String(localized: "O som do Mac não pôde ser sincronizado pelo som do iPhone; valeu o atraso do microfone.")
        } catch {
            print("cópia no Mac: não juntou o microfone em \(movie.lastPathComponent): \(error)")
            return String(localized: "O som do Mac ficou em um arquivo separado: \(error.localizedDescription)")
        }
    }

    private func finished(_ url: URL, _ error: Error?) {
        DispatchQueue.main.async { [onFinish] in onFinish?(url, error) }
    }

    private func audioSample(_ frame: AudioDecoder.ADTSFrame, pts: CMTime) -> CMSampleBuffer? {
        let config = [frame.objectType, frame.sampleRateIndex, frame.channels]
        if config != audioConfig {
            var description = AudioStreamBasicDescription(
                mSampleRate: Double(frame.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: AudioFormatFlags(frame.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
                mBytesPerFrame: 0, mChannelsPerFrame: UInt32(frame.channels), mBitsPerChannel: 0, mReserved: 0)
            let cookie = Self.esdsCookie(frame)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: cookie, extensions: nil, formatDescriptionOut: &format)
            guard let format else { return nil }
            audioFormat = format
            audioConfig = config
        }
        guard let audioFormat else { return nil }

        let size = frame.payload.count
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard let block else { return nil }
        frame.payload.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
        }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat, sampleCount: 1,
            presentationTimeStamp: pts, packetDescriptions: &packet, sampleBufferOut: &sample)
        return sample
    }

    /// Configuração do AAC no formato que o QuickTime grava no arquivo (ES_Descriptor do
    /// MPEG-4, ISO/IEC 14496-1). Com só os 2 bytes do AudioSpecificConfig, que bastam para
    /// decodificar, o arquivo sai com uma trilha de som que o AVFoundation ignora.
    static func esdsCookie(_ frame: AudioDecoder.ADTSFrame) -> [UInt8] {
        // AudioSpecificConfig de 2 bytes, montado do próprio ADTS, como no decodificador.
        let asc = UInt16(frame.objectType) << 11 | UInt16(frame.sampleRateIndex) << 7 | UInt16(frame.channels) << 3
        let specific: [UInt8] = [0x05, 2, UInt8(asc >> 8), UInt8(asc & 0xFF)]
        // Áudio MPEG-4 (0x40), stream de áudio (0x15); buffer e bitrates em zero ficam livres.
        let config: [UInt8] = [0x04, UInt8(13 + specific.count), 0x40, 0x15] + [UInt8](repeating: 0, count: 11) + specific
        let sl: [UInt8] = [0x06, 1, 0x02]
        return [0x03, UInt8(3 + config.count + sl.count), 0, 0, 0] + config + sl
    }

    /// Quadro-chave pela marca de sincronia que `markSync` deixou.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first
        else { return true }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }

    /// Sem a marca, o arquivo trataria todo quadro como chave e o editor não acharia onde cortar.
    static func markSync(_ sample: CMSampleBuffer, keyframe: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        let value = Unmanaged.passUnretained(keyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
        CFDictionarySetValue(dictionary, key, value)
    }

    /// Rotação do monitor no sentido horário, em quartos de volta, como transformação da trilha
    /// num quadro de `width` x `height`.
    public static func transform(quarterTurns: Int, width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: .identity
        }
    }

    /// "nome (2).mov" ao lado de "nome.mov", como o Finder numera cópias.
    static func partURL(_ url: URL, _ part: Int) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(name) (\(part))").appendingPathExtension(url.pathExtension)
    }
}
