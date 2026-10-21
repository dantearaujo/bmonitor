import AVFoundation
import CoreMedia

/// Grava no Mac uma cópia do stream que chega do iPhone, sem recodificar: o HEVC e o AAC vão
/// do jeito que vieram para um `.mov`. É a qualidade do stream (1080p, 8 Mb/s), não o arquivo
/// original do iPhone.
///
/// Tudo roda numa fila própria: quem recebe o stream só entrega e volta. O vídeo vai para a
/// tela antes de chegar aqui, então a cópia não soma atraso ao monitor.
///
/// O REC chega pela rede depois que a câmera já começou a gravar, e o stream vem uns 0,3 s
/// atrás. Por isso a cópia guarda o vídeo desde o último quadro-chave (o arquivo começa um
/// pouco antes do REC) e continua `tail` segundos depois do STOP.
public final class TakeRecorder {
    /// Chamado na thread principal quando um arquivo fecha: o endereço e o erro, se houve.
    public var onFinish: ((URL, Error?) -> Void)?
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
    private var take: Take?
    /// Pedido de gravar ainda sem arquivo: espera o próximo quadro-chave.
    private var armed: (url: URL, quarterTurns: Int, part: Int)?
    private var stopping = false
    private var lastSeenVideo = CMTime.negativeInfinity

    private struct Take {
        var writer: AVAssetWriter
        var video: AVAssetWriterInput
        var audio: AVAssetWriterInput?
        var format: CMFormatDescription
        var start: CMTime
        var lastVideo: CMTime
        var lastAudio: CMTime = .negativeInfinity
        var url: URL
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
            stopping = false
            armed = (url, quarterTurns, 1)
            if let key = preroll.first, Self.isKeyframe(key) { open(at: key) }
        }
    }

    /// Fecha o arquivo depois de `tail` segundos.
    public func end() {
        queue.async { [self] in
            armed = nil
            guard take != nil else { return }
            stopping = true
            queue.asyncAfter(deadline: .now() + tail) { [self] in
                if stopping { close() }
            }
        }
    }

    /// Fecha já e espera o arquivo ficar pronto. Para o encerramento do app.
    public func endBlocking(timeout: TimeInterval = 3) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            armed = nil
            stopping = false
            if take != nil { close { done.signal() } } else { done.signal() }
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Um quadro de vídeo já pronto para o decodificador (NAL com tamanho de 4 bytes).
    public func appendVideo(_ sample: CMSampleBuffer, keyframe: Bool) {
        queue.async { [self] in video(sample, keyframe: keyframe) }
    }

    /// Um PES de áudio com seus quadros ADTS.
    public func appendAudio(_ unit: AudioAccessUnit) {
        queue.async { [self] in audio(unit) }
    }

    // MARK: - Na fila

    private func video(_ sample: CMSampleBuffer, keyframe: Bool) {
        Self.markSync(sample, keyframe: keyframe)
        let pts = sample.presentationTimeStamp
        // O pré-roll só vale do quadro-chave em diante e no mesmo relógio.
        if keyframe || pts <= lastSeenVideo { preroll.removeAll() }
        lastSeenVideo = pts
        if !preroll.isEmpty || keyframe { preroll.append(sample) }
        // Teto de memória se os quadros-chave sumirem: a cópia espera o próximo.
        if preroll.count > 900 { preroll.removeAll() }

        if var current = take {
            guard let format = sample.formatDescription else { return }
            // Stream reiniciado (o relógio voltou) ou formato novo: este arquivo fecha e o
            // take continua num arquivo "(2)" a partir do próximo quadro-chave.
            if pts <= current.lastVideo || !CMFormatDescriptionEqual(format, otherFormatDescription: current.format) {
                let next = (current.url, current.quarterTurns, current.part + 1)
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
            audioPreroll.append(sample)
            if var current = take, let input = current.audio, sample.presentationTimeStamp >= current.start,
                sample.presentationTimeStamp > current.lastAudio, input.isReadyForMoreMediaData, input.append(sample)
            {
                current.lastAudio = sample.presentationTimeStamp
                take = current
            }
        }
        // Mais que o pré-roll de vídeo precisa: um quadro-chave a cada poucos segundos.
        if audioPreroll.count > 500 { audioPreroll.removeFirst(audioPreroll.count - 500) }
    }

    private func open(at keyframe: CMSampleBuffer) {
        guard let armed, let format = keyframe.formatDescription else { return }
        self.armed = nil
        let url = armed.part == 1 ? armed.url : Self.partURL(armed.url, armed.part)
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
            if let audioFormat {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audio = input
                }
            }
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            let start = keyframe.presentationTimeStamp
            writer.startSession(atSourceTime: start)
            take = Take(
                writer: writer, video: video, audio: audio, format: format, start: start, lastVideo: .negativeInfinity,
                url: url, quarterTurns: armed.quarterTurns, part: armed.part)
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
        for sample in audioPreroll where sample.presentationTimeStamp >= start(of: take) {
            guard var current = take, let input = current.audio, sample.presentationTimeStamp > current.lastAudio,
                input.isReadyForMoreMediaData, input.append(sample)
            else { continue }
            current.lastAudio = sample.presentationTimeStamp
            take = current
        }
    }

    private func start(of take: Take?) -> CMTime { take?.start ?? .positiveInfinity }

    private func close(_ completion: (() -> Void)? = nil) {
        guard let current = take else {
            completion?()
            return
        }
        take = nil
        stopping = false
        current.video.markAsFinished()
        current.audio?.markAsFinished()
        current.writer.finishWriting { [self] in
            let error = current.writer.status == .completed ? nil : current.writer.error ?? CocoaError(.fileWriteUnknown)
            print("cópia no Mac: \(error == nil ? "salva" : "falhou") \(current.url.lastPathComponent)\(error.map { ": \($0)" } ?? "")")
            finished(current.url, error)
            completion?()
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
