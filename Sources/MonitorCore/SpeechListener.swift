import AVFoundation
import Speech

/// Reconhece a fala no áudio da câmera, só no Mac: nada sai do computador.
///
/// No macOS 26 usa o `SpeechAnalyzer` com o `SpeechTranscriber`; no 14 e no 15, o
/// `SFSpeechRecognizer` com reconhecimento no aparelho obrigatório. Recebe os buffers
/// decodificados do stream (`append`, de qualquer thread) e entrega as últimas palavras
/// ouvidas, já como chaves de `Script`, na thread principal.
public final class SpeechListener: @unchecked Sendable {
    public enum State: Equatable {
        case off
        /// Preparando o reconhecedor (no macOS 26 pode baixar o modelo do idioma).
        case preparing
        case listening
        case unavailable(String)
    }

    /// Últimas palavras ouvidas, a mais recente no fim.
    public var onHeard: (([String]) -> Void)?
    public var onState: ((State) -> Void)?

    private let lock = NSLock()
    private var backend: Backend?
    private var finalized: [String] = []
    private var partialCount = 0
    private var discardedPrefix = 0
    private var deliveryRevision = 0
    private var generation = 0

    public init() {}

    /// Liga o reconhecimento no idioma do roteiro.
    public func start(locale: Locale) {
        stop()
        let generation = lock.withLock {
            self.generation += 1
            return self.generation
        }
        report(.preparing, generation: generation)
        Task { [weak self] in
            guard let self else { return }
            do {
                let backend: Backend
                if #available(macOS 26.0, *) {
                    backend = try await AnalyzerBackend.make(locale: locale)
                } else {
                    backend = try await RecognizerBackend.make(locale: locale)
                }
                let current = lock.withLock { () -> Bool in
                    guard self.generation == generation else { return false }
                    self.backend = backend
                    self.finalized = []
                    self.partialCount = 0
                    self.discardedPrefix = 0
                    return true
                }
                guard current else { return backend.stop() }
                backend.onText = { [weak self] text, isFinal in self?.received(text, isFinal: isFinal, generation: generation) }
                backend.onFailure = { [weak self] message in
                    guard let self, self.lock.withLock({ self.generation == generation }) else { return }
                    self.report(.unavailable(message), generation: generation)
                }
                report(.listening, generation: generation)
            } catch {
                guard lock.withLock({ self.generation == generation }) else { return }
                report(.unavailable(Self.message(for: error)), generation: generation)
            }
        }
    }

    public func stop() {
        let (backend, generation) = lock.withLock {
            self.generation += 1
            let previous = self.backend
            self.backend = nil
            return (previous, self.generation)
        }
        backend?.stop()
        report(.off, generation: generation)
    }

    /// Esquece o que já foi ouvido, quando o marcador muda de lugar à mão.
    public func forget() {
        lock.withLock {
            finalized = []
            discardedPrefix = partialCount
            deliveryRevision += 1
        }
    }

    /// Áudio decodificado da câmera; descartado quando o reconhecimento está desligado.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { backend }?.append(buffer)
    }

    private func received(_ text: String, isFinal: Bool, generation: Int) {
        let keys = Script.keys(in: text)
        let update = lock.withLock { () -> ([String], Int)? in
            guard self.generation == generation else { return nil }
            let newWords = keys.dropFirst(discardedPrefix)
            partialCount = isFinal ? 0 : keys.count
            if isFinal { discardedPrefix = 0 }
            guard !newWords.isEmpty else { return nil }
            let heard = Array((finalized + newWords).suffix(64))
            if isFinal { finalized = heard }
            return (heard, deliveryRevision)
        }
        guard let (heard, revision) = update else { return }
        DispatchQueue.main.async {
            guard self.lock.withLock({ self.generation == generation && self.deliveryRevision == revision }) else { return }
            self.onHeard?(heard)
        }
    }

    private func report(_ state: State, generation: Int) {
        DispatchQueue.main.async {
            guard self.lock.withLock({ self.generation == generation }) else { return }
            self.onState?(state)
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? ListenerError { return error.message }
        return error.localizedDescription
    }
}

struct ListenerError: Error {
    var message: String
}

/// Um motor de reconhecimento: recebe áudio, devolve texto parcial e final.
protocol Backend: AnyObject {
    var onText: ((String, Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

/// Converte o áudio da câmera (48 kHz, estéreo) para o formato que o reconhecedor pede.
final class Resampler {
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to output: AVAudioFormat) { self.output = output }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 32
        guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: result, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return result.frameLength > 0 ? result : nil
    }
}

// MARK: - macOS 26

@available(macOS 26.0, *)
final class AnalyzerBackend: Backend {
    var onText: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let resampler: Resampler
    private var results: Task<Void, Never>?

    static func make(locale: Locale) async throws -> AnalyzerBackend {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(
                locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [])
            return try await make(module: transcriber, results: transcriber.results) { String($0.text.characters) }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .progressiveLongDictation)
            return try await make(module: transcriber, results: transcriber.results) { String($0.text.characters) }
        }
        throw ListenerError(message: String(localized: "O reconhecimento de fala do Mac não tem esse idioma."))
    }

    private static func make<Results: AsyncSequence>(
        module: any SpeechModule, results: Results, text: @escaping (Results.Element) -> String
    ) async throws -> AnalyzerBackend where Results.Element: SpeechModuleResult {
        // O modelo do idioma vem do sistema; na primeira vez o macOS baixa (uma vez só).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw ListenerError(message: String(localized: "O reconhecimento de fala do Mac não abriu."))
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(100))
        try await analyzer.start(inputSequence: stream)
        let backend = AnalyzerBackend(analyzer: analyzer, input: input, resampler: Resampler(to: format))
        backend.results = Task { [weak backend] in
            do {
                for try await result in results {
                    backend?.onText?(text(result), result.isFinal)
                }
            } catch {
                backend?.onFailure?(error.localizedDescription)
            }
        }
        return backend
    }

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, resampler: Resampler) {
        self.analyzer = analyzer
        self.input = input
        self.resampler = resampler
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resampler.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        input.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

// MARK: - macOS 14 e 15

/// `SFSpeechRecognizer` só no aparelho. Uma tarefa longa fica lenta, então a cada ~40
/// palavras a tarefa fecha (o texto dela vira final) e outra começa.
final class RecognizerBackend: Backend {
    var onText: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private let resampler = Resampler(to: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!)
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopped = false

    static func make(locale: Locale) async throws -> RecognizerBackend {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw ListenerError(
                message: String(localized: "Permita o reconhecimento de fala em Ajustes do Sistema › Privacidade e Segurança."))
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw ListenerError(message: String(localized: "O reconhecimento de fala do Mac não tem esse idioma."))
        }
        let backend = RecognizerBackend(recognizer: recognizer)
        backend.begin()
        return backend
    }

    private init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    private func begin() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        var delivered = false
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    if !delivered { self.onText?(text, true) }
                    delivered = true
                    self.restart()
                } else {
                    self.onText?(text, false)
                    if result.bestTranscription.segments.count > 40 {
                        delivered = true
                        self.onText?(text, true)
                        request.endAudio()
                    }
                }
            } else if error != nil {
                self.onText?("", true)
                self.restart()
            }
        }
        lock.withLock {
            self.request = request
            self.task = task
        }
    }

    private func restart() {
        let again = lock.withLock { () -> Bool in
            request = nil
            task = nil
            return !stopped
        }
        guard again else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.begin() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resampler.convert(buffer) else { return }
        lock.withLock { request }?.append(converted)
    }

    func stop() {
        let (request, task) = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            stopped = true
            return (self.request, self.task)
        }
        request?.endAudio()
        task?.cancel()
    }
}
