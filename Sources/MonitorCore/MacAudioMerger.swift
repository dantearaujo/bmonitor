import AVFoundation
import CoreMedia

/// Junta num só arquivo a imagem de um vídeo e o som do microfone do Mac, sem recodificar:
/// as amostras são copiadas como estão (`AVMutableMovie`), então a trilha de timecode e o
/// resto do original do iPhone continuam lá.
///
/// O som do iPhone que já está no vídeo serve de referência: `AudioAlignment` acha onde o som
/// do Mac encaixa. Serve para a cópia que o bmonitor grava do stream e para o clipe original
/// trazido do iPhone depois.
public enum MacAudioMerger {
    public struct Result: Equatable {
        /// Segundos do vídeo em que começa o som do Mac.
        public var offset: Double
        /// Nil quando não houve como comparar (vídeo sem som) e valeu `expectedOffset`.
        public var confidence: Double?
        /// O alinhamento automático achou um pico claro.
        public var synced: Bool
    }

    public enum MergeError: LocalizedError {
        case noVideo, noMicrophone, noReference, noMatch

        public var errorDescription: String? {
            switch self {
            case .noVideo: String(localized: "O arquivo não tem trilha de vídeo.")
            case .noMicrophone: String(localized: "O arquivo do microfone do Mac não tem áudio.")
            case .noReference:
                String(localized: "O clipe não tem o som do iPhone, que é a referência para sincronizar. Deixe uma origem de áudio ligada no iPhone.")
            case .noMatch: String(localized: "O som do Mac não combinou com o som do clipe. Confira se é o take certo.")
            }
        }
    }

    /// Taxa usada só para comparar: a banda da voz cabe em 8 kHz e a precisão fica em 0,125 ms.
    static let analysisRate = 8_000.0
    /// Quanto de cada lado entra na comparação; o atraso não muda ao longo do take.
    static let analysisSeconds = 120.0

    /// - Parameters:
    ///   - expectedOffset: onde se espera o som do Mac, em segundos do vídeo; nil procura em tudo.
    ///   - window: quanto o alinhamento pode se afastar de `expectedOffset`.
    ///   - keepPhoneAudio: mantém o som do iPhone como segunda trilha, desligada na reprodução.
    public static func merge(
        video: URL, microphone: URL, output: URL, keepPhoneAudio: Bool,
        expectedOffset: Double? = nil, window: Double = 1
    ) async throws -> Result {
        let videoAsset = AVURLAsset(url: video)
        let micAsset = AVURLAsset(url: microphone)
        guard try await !videoAsset.loadTracks(withMediaType: .video).isEmpty else { throw MergeError.noVideo }
        guard let micTrack = try await micAsset.loadTracks(withMediaType: .audio).first else {
            throw MergeError.noMicrophone
        }
        let phoneTrack = try await videoAsset.loadTracks(withMediaType: .audio).first

        let result: Result
        if let phoneTrack {
            let reference = try await samples(of: videoAsset, track: phoneTrack)
            let candidate = try await samples(of: micAsset, track: micTrack)
            let match = AudioAlignment.match(
                reference: reference, candidate: candidate, sampleRate: analysisRate,
                expected: expectedOffset, window: expectedOffset == nil ? nil : window)
            if let match, match.confidence >= AudioAlignment.minimumConfidence {
                result = Result(offset: match.offset, confidence: match.confidence, synced: true)
            } else if let expectedOffset {
                result = Result(offset: expectedOffset, confidence: match?.confidence, synced: false)
            } else {
                throw MergeError.noMatch
            }
        } else if let expectedOffset {
            result = Result(offset: expectedOffset, confidence: nil, synced: false)
        } else {
            throw MergeError.noReference
        }

        try await write(
            video: videoAsset, microphone: micTrack, micAsset: micAsset, offset: result.offset,
            keepPhoneAudio: keepPhoneAudio, output: output)
        return result
    }

    /// Mono em `analysisRate`, cada amostra no seu instante da linha do tempo (o começo vazio
    /// de uma trilha vira silêncio).
    static func samples(of asset: AVAsset, track: AVAssetTrack) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let duration = try await asset.load(.duration)
        let limit = min(duration.isNumeric ? duration.seconds : analysisSeconds, analysisSeconds)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analysisRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MergeError.noReference }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MergeError.noReference }

        var result = [Float](repeating: 0, count: Int(limit * analysisRate))
        var cursor: Int?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMSampleBufferGetNumSamples(sample)
            let pts = sample.presentationTimeStamp
            // Amostras contíguas seguem o cursor; só um salto de verdade (> 5 ms) reposiciona.
            let atPTS = pts.isNumeric ? Int((pts.seconds * analysisRate).rounded()) : (cursor ?? 0)
            var start = cursor ?? atPTS
            if abs(atPTS - start) > Int(analysisRate / 200) { start = atPTS }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }
            let frames = min(count, length / MemoryLayout<Float>.size)
            pointer.withMemoryRebound(to: Float.self, capacity: frames) { floats in
                for i in 0..<frames {
                    let index = start + i
                    if index >= 0, index < result.count { result[index] = floats[i] }
                }
            }
            cursor = start + frames
        }
        if reader.status == .failed { throw reader.error ?? MergeError.noReference }
        return result
    }

    private static func write(
        video: AVURLAsset, microphone: AVAssetTrack, micAsset: AVURLAsset, offset: Double,
        keepPhoneAudio: Bool, output: URL
    ) async throws {
        try? FileManager.default.removeItem(at: output)
        let source = AVMovie(url: video.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await video.load(.duration)
        let movie = try AVMutableMovie(settingsFrom: source, options: nil)
        movie.defaultMediaDataStorage = AVMediaDataStorage(url: output, options: nil)
        try movie.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero, copySampleData: true)

        for track in movie.tracks(withMediaType: .audio) {
            if keepPhoneAudio {
                // Fica no arquivo para o editor, mas não toca junto com o Mac (eco).
                track.isEnabled = false
            } else {
                movie.removeTrack(track)
            }
        }

        let micDuration = try await micAsset.load(.duration)
        let shift = CMTime(seconds: offset, preferredTimescale: 48_000)
        // Só o pedaço do som do Mac que cai dentro do vídeo.
        let sourceStart = CMTimeMaximum(.zero, CMTimeMultiply(shift, multiplier: -1))
        let sourceEnd = CMTimeMinimum(micDuration, duration - shift)
        guard sourceEnd > sourceStart,
            let track = movie.addMutableTrack(withMediaType: .audio, copySettingsFrom: microphone, options: nil)
        else { throw MergeError.noMicrophone }
        try track.insertTimeRange(
            CMTimeRange(start: sourceStart, end: sourceEnd), of: microphone, at: sourceStart + shift, copySampleData: true)
        track.isEnabled = true
        let title = AVMutableMetadataItem()
        title.identifier = .quickTimeUserDataFullName
        title.value = "Mac Microphone" as NSString
        track.metadata = [title]

        do {
            try movie.writeHeader(to: output, fileType: .mov, options: .addMovieHeaderToDestination)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
