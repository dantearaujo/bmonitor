import AVFoundation
import AppKit
import MonitorCore
import NaturalLanguage
import Observation
import UniformTypeIdentifiers

/// O roteiro do painel ao lado do vídeo: o texto, a frase em que você está e o
/// acompanhamento pela voz, ouvindo o áudio da câmera.
@MainActor @Observable
final class ScriptModel {
    /// Onde o roteiro fica em relação ao vídeo. Acima e abaixo só com o vídeo deitado: em pé,
    /// a janela já é alta e o lado sobra.
    enum Side: String, CaseIterable, Identifiable {
        case top, bottom, left, right
        var id: String { rawValue }
        var isVertical: Bool { self == .top || self == .bottom }
        var title: String {
            switch self {
            case .top: String(localized: "Acima do vídeo")
            case .bottom: String(localized: "Abaixo do vídeo")
            case .left: String(localized: "À esquerda do vídeo")
            case .right: String(localized: "À direita do vídeo")
            }
        }
        var symbol: String {
            switch self {
            case .top: "rectangle.topthird.inset.filled"
            case .bottom: "rectangle.bottomthird.inset.filled"
            case .left: "sidebar.left"
            case .right: "sidebar.right"
            }
        }
        static func choices(landscape: Bool) -> [Side] { landscape ? allCases : [.left, .right] }
    }

    private(set) var text: String
    private(set) var script: Script
    private var follower: ScriptFollower
    /// Próxima palavra a ser dita; as anteriores aparecem apagadas.
    var position: Int { follower.position }
    var editing = false
    /// O painel aberto na janela do monitor; a janela cresce para o lado dele.
    var isOpen: Bool { didSet { UserDefaults.standard.set(isOpen, forKey: "scriptOpen") } }
    /// Numa janela própria, fora da janela da câmera.
    var detached: Bool { didSet { UserDefaults.standard.set(detached, forKey: "scriptDetached") } }
    /// Uma escolha por orientação: girar o vídeo leva o roteiro para o lugar daquela orientação.
    var portraitSide: Side { didSet { UserDefaults.standard.set(portraitSide.rawValue, forKey: "scriptSide") } }
    var landscapeSide: Side { didSet { UserDefaults.standard.set(landscapeSide.rawValue, forKey: "scriptSideLandscape") } }
    var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "scriptFontSize") } }
    private(set) var following = false
    private(set) var listening: SpeechListener.State = .off
    /// Idioma em que a fala é reconhecida, deduzido do texto.
    private(set) var language: Locale

    static let fontSizes: ClosedRange<Double> = 18...96

    @ObservationIgnored let speech = SpeechListener()
    @ObservationIgnored private var feeder: Task<Void, Never>?

    init() {
        let saved = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
        let parsed = Script(markdown: saved)
        text = saved
        script = parsed
        follower = ScriptFollower(script: parsed)
        language = Self.language(of: saved)
        isOpen = UserDefaults.standard.bool(forKey: "scriptOpen")
        detached = UserDefaults.standard.bool(forKey: "scriptDetached")
        let portrait = UserDefaults.standard.string(forKey: "scriptSide").flatMap(Side.init(rawValue:)) ?? .right
        portraitSide = portrait.isVertical ? .right : portrait
        // Deitado, acima: com o iPhone em cima do monitor, o olho fica perto da lente.
        landscapeSide = UserDefaults.standard.string(forKey: "scriptSideLandscape").flatMap(Side.init(rawValue:)) ?? .top
        // Lido perto do Mac, à distância de computador (não do tripé).
        fontSize = UserDefaults.standard.object(forKey: "scriptFontSize") as? Double ?? 28
        if let i = UserDefaults.standard.object(forKey: "scriptPosition") as? Int { follower.move(to: i) }
        speech.onHeard = { [weak self] heard in self?.heard(heard) }
        speech.onState = { [weak self] state in self?.listening = state }

        // Desenvolvimento: `--script-file <md>` carrega um roteiro ao abrir.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--script-file"), i + 1 < args.count,
            let markdown = try? String(contentsOfFile: args[i + 1], encoding: .utf8)
        {
            replace(with: markdown)
        }
    }

    // MARK: - Texto

    func replace(with markdown: String) {
        text = markdown
        script = Script(markdown: markdown)
        follower = ScriptFollower(script: script)
        language = Self.language(of: markdown)
        savePosition()
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? markdown.write(to: Self.fileURL, atomically: true, encoding: .utf8)
        if following { startListening() }
    }

    func paste() {
        guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        replace(with: pasted)
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let markdown = try? String(contentsOf: url, encoding: .utf8) else { return }
        replace(with: markdown)
    }

    /// O roteiro mora em Application Support: sobrevive a fechar o app e não depende de pasta.
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "bmonitor/roteiro.md")
    }

    // MARK: - Onde você está

    var currentSentence: Int? { script.sentence(containing: position) }

    /// Número da fala atual e total, para o canto do painel; títulos e listas contam como falas.
    var progress: (current: Int, total: Int)? {
        guard let block = currentBlock else { return nil }
        let spoken = script.blocks.filter { !$0.words.isEmpty }
        guard let index = spoken.firstIndex(where: { $0.id == block }) else { return nil }
        return (index + 1, spoken.count)
    }

    var currentBlock: Int? {
        currentSentence.map { script.words[script.sentences[$0].lowerBound].block }
    }

    func move(to word: Int) {
        follower.move(to: word)
        savePosition()
        // O que já foi ouvido não pode puxar o marcador de volta para o lugar antigo.
        speech.forget()
    }

    func moveToBlock(_ block: Int) {
        guard script.blocks.indices.contains(block), !script.blocks[block].words.isEmpty else { return }
        move(to: script.blocks[block].words.lowerBound)
    }

    func nextSentence() {
        guard let sentence = currentSentence, sentence + 1 < script.sentences.count else { return }
        move(to: script.sentences[sentence + 1].lowerBound)
    }

    func previousSentence() {
        guard let sentence = currentSentence else { return }
        let start = script.sentences[sentence].lowerBound
        move(to: position > start ? start : sentence > 0 ? script.sentences[sentence - 1].lowerBound : 0)
    }

    func restart() { move(to: 0) }

    func adjustFont(by step: Double) {
        fontSize = min(max(fontSize + step, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
    }

    private func savePosition() { UserDefaults.standard.set(position, forKey: "scriptPosition") }

    // MARK: - Pela voz

    func toggleFollowing() {
        following.toggle()
        if following { startListening() } else { stopListening() }
    }

    private func startListening() {
        speech.start(locale: language)
        feedFileIfAsked()
    }

    private func stopListening() {
        feeder?.cancel()
        feeder = nil
        speech.stop()
    }

    private func heard(_ heard: [String]) {
        guard following, follower.follow(heard) else { return }
        savePosition()
    }

    /// Português ou inglês, pelo próprio texto; sem texto, o idioma do Mac.
    static func language(of text: String) -> Locale {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.portuguese, .english]
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .portuguese?: return Locale(identifier: "pt_BR")
        case .english?: return Locale(identifier: "en_US")
        default: return Locale.current.language.languageCode == .portuguese ? Locale(identifier: "pt_BR") : Locale(identifier: "en_US")
        }
    }

    /// Desenvolvimento: `--script-audio <arquivo>` toca um áudio gravado no lugar do som da
    /// câmera, em tempo real, para testar o acompanhamento sem o iPhone.
    private func feedFileIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--script-audio"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        let speech = speech
        feeder?.cancel()
        feeder = Task.detached {
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            // Espera o reconhecedor abrir.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled, file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                    (try? file.read(into: buffer, frameCount: chunk)) != nil
                else { return }
                speech.append(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
