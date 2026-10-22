import AppKit
import MonitorCore
import SwiftUI

/// Janela do roteiro, ao lado do monitor: texto grande sobre preto, legível do tripé.
///
/// A frase atual fica em branco cheio com uma barra na cor de destaque ao lado; o que já foi
/// dito apaga e o resto fica no meio. Os controles ficam numa cápsula de vidro na base, que
/// some quando o mouse para, como no monitor.
struct ScriptView: View {
    @Bindable var model: ScriptModel
    let cameraConnected: Bool
    @State private var draft = ""
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if model.editing {
                editor
            } else if model.script.isEmpty {
                empty
            } else {
                ScriptReading(model: model)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress(keys: [.downArrow, .rightArrow, .space, .upArrow, .leftArrow, .home]) { press in
                        switch press.key {
                        case .downArrow, .rightArrow: model.nextSentence()
                        case .space where press.modifiers.contains(.shift): model.previousSentence()
                        case .space: model.nextSentence()
                        case .home: model.restart()
                        default: model.previousSentence()
                        }
                        return .handled
                    }
                    .onAppear { focused = true }
            }
            if model.editing || (controlsVisible && !model.script.isEmpty) {
                controls
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 380, minHeight: 360)
        .navigationTitle(String(localized: "Roteiro"))
        .onContinuousHover { phase in
            if case .active = phase { pokeControls() }
        }
        .onAppear { pokeControls() }
        // A edição pode começar pelo menu (⌘E): o rascunho parte do texto atual.
        .onChange(of: model.editing, initial: true) { _, editing in
            if editing { draft = model.text }
        }
        .background(ScriptWindowPlacement())
    }

    // MARK: - Estados

    private var empty: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Cole o seu roteiro")
                    .font(.system(size: 26, weight: .semibold))
                Text("Texto ou Markdown, com títulos, negrito e listas. O bmonitor guarda o último roteiro.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Colar") { model.paste() }
                    .keyboardShortcut("v")
                    .buttonStyle(.borderedProminent)
                Button("Abrir arquivo…") { model.open() }
                Button("Escrever") { startEditing() }
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 17))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 88)
            .onExitCommand { finishEditing() }
    }

    // MARK: - Controles

    private var controls: some View {
        HStack(spacing: 2) {
            if model.editing {
                Button { finishEditing() } label: { item("checkmark", String(localized: "Concluído")) }
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button { startEditing() } label: { item("pencil", String(localized: "Editar")) }
                if !model.script.isEmpty {
                    Divider().frame(height: 24).padding(.horizontal, 4)
                    Button { model.adjustFont(by: -4) } label: { icon("textformat.size.smaller") }
                        .help(String(localized: "Texto menor"))
                    Button { model.adjustFont(by: 4) } label: { icon("textformat.size.larger") }
                        .help(String(localized: "Texto maior"))
                    Button { model.restart() } label: { icon("arrow.up.to.line") }
                        .help(String(localized: "Voltar ao início"))
                    Divider().frame(height: 24).padding(.horizontal, 4)
                    Button { model.toggleFollowing() } label: { follow }
                        .buttonStyle(HUDItemStyle(isOn: model.following))
                }
            }
        }
        .buttonStyle(HUDItemStyle())
        .padding(4)
        .hudGlass(Capsule(), interactive: true)
    }

    private var follow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.following ? "waveform" : "waveform.slash")
                .font(.system(size: 15, weight: .medium))
                .symbolEffect(.variableColor.iterative, isActive: model.following && model.listening == .listening && cameraConnected)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Seguir a fala").font(.system(size: 13, weight: .semibold))
                Text(followStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(followAlert ? Theme.warn : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.barItem)
        .accessibilityElement(children: .combine)
    }

    private var followStatus: String {
        guard model.following else { return String(localized: "desligado") }
        switch model.listening {
        case .off, .preparing: return String(localized: "preparando…")
        case .unavailable(let message): return message
        case .listening:
            guard cameraConnected || CommandLine.arguments.contains("--script-audio") else {
                return String(localized: "sem áudio da câmera")
            }
            return model.language.language.languageCode == .portuguese
                ? String(localized: "ouvindo em português") : String(localized: "ouvindo em inglês")
        }
    }

    private var followAlert: Bool {
        guard model.following else { return false }
        if case .unavailable = model.listening { return true }
        return model.listening == .listening && !cameraConnected && !CommandLine.arguments.contains("--script-audio")
    }

    private func item(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.barItem)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .frame(width: Theme.barItem, height: Theme.barItem)
    }

    private func pokeControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { controlsVisible = false }
        }
    }

    private func startEditing() { model.editing = true }

    private func finishEditing() {
        if draft != model.text { model.replace(with: draft) }
        model.editing = false
        focused = true
    }
}

/// O texto do roteiro, rolando para manter a frase atual a um terço da altura.
private struct ScriptReading: View {
    let model: ScriptModel

    var body: some View {
        let script = model.script
        let current = model.currentSentence
        let currentBlock = model.currentBlock
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: model.fontSize * 0.7) {
                        ForEach(script.blocks) { block in
                            ScriptBlockView(
                                block: block, script: script, position: model.position, sentence: current,
                                fontSize: model.fontSize, isCurrent: block.id == currentBlock
                            )
                            .id(block.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.moveToBlock(block.id) }
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, 48)
                    // Folga em cima e embaixo: a primeira e a última frase também chegam ao terço.
                    .padding(.top, geometry.size.height * 0.3)
                    .padding(.bottom, geometry.size.height * 0.6)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                // O texto esmaece nas bordas em vez de cortar seco sob os botões da janela e a barra.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                            .init(color: .black, location: 0.86), .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                }
                .onAppear { proxy.scrollTo(currentBlock, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                .onChange(of: currentBlock) { _, block in
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(block, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
                .onChange(of: model.fontSize) { _, _ in proxy.scrollTo(currentBlock, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
    }
}

/// Um bloco do roteiro, com as palavras pintadas pelo estado: dita, frase atual ou por vir.
private struct ScriptBlockView: View {
    let block: Script.Block
    let script: Script
    let position: Int
    let sentence: Int?
    let fontSize: Double
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.4) {
            switch block.kind {
            case .bullet: Text("•").font(font).foregroundStyle(.secondary)
            case .numbered(let number): Text("\(number).").font(font).foregroundStyle(.secondary).monospacedDigit()
            default: EmptyView()
            }
            Text(painted)
                .font(font)
                .lineSpacing(fontSize * 0.28)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, block.kind == .quote ? fontSize * 0.6 : 0)
        .overlay(alignment: .leading) {
            if block.kind == .quote {
                Rectangle().fill(.secondary).frame(width: 3).padding(.vertical, 4)
            }
        }
        // A barra da frase atual: forma além da cor, como os outros estados do app.
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Color.accentColor).frame(width: 5).offset(x: -24)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: position)
    }

    private var font: Font {
        switch block.kind {
        case .heading(1): .system(size: fontSize * 1.3, weight: .bold)
        case .heading(2): .system(size: fontSize * 1.15, weight: .bold)
        case .heading: .system(size: fontSize * 1.05, weight: .semibold)
        default: .system(size: fontSize, weight: .medium)
        }
    }

    private var strongFont: Font {
        switch block.kind {
        case .heading: .system(size: fontSize * 1.15, weight: .heavy)
        default: .system(size: fontSize, weight: .bold)
        }
    }

    /// Escada de opacidade do branco: dito 22%, por vir 60% (ainda legível do tripé, para ler
    /// adiante), frase atual 100%.
    private var painted: AttributedString {
        var text = block.text
        let characters = text.characters
        text.foregroundColor = .white.opacity(0.6)
        // O peso do bloco anularia o negrito do Markdown: ênfase forte ganha a fonte por trecho.
        for (intent, range) in text.runs[\.inlinePresentationIntent] where intent?.contains(.stronglyEmphasized) == true {
            text[range].font = intent!.contains(.emphasized) ? strongFont.italic() : strongFont
        }
        let words = block.words
        guard !words.isEmpty else { return text }
        func index(_ offset: Int) -> AttributedString.Index { characters.index(characters.startIndex, offsetBy: offset) }
        // Dito: do começo do bloco até a próxima palavra, com a pontuação de quem já foi dito.
        if position > words.lowerBound {
            let end = position < words.upperBound ? script.words[position].range.lowerBound : characters.count
            text[index(0)..<index(end)].foregroundColor = .white.opacity(0.22)
        }
        // Frase atual, só a parte que ainda falta dizer.
        if let sentence {
            let range = script.sentences[sentence]
            let from = max(range.lowerBound, position, words.lowerBound)
            let to = min(range.upperBound, words.upperBound)
            if from < to {
                let end = to < words.upperBound ? script.words[to].range.lowerBound : characters.count
                text[index(script.words[from].range.lowerBound)..<index(end)].foregroundColor = .white
            }
        }
        return text
    }
}

/// Na primeira vez, abre o roteiro ao lado do monitor, sem cobrir o vídeo. Depois o macOS
/// lembra onde você deixou a janela.
private struct ScriptWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, !UserDefaults.standard.bool(forKey: "scriptWindowPlaced") else { return }
            UserDefaults.standard.set(true, forKey: "scriptWindowPlaced")
            guard let monitor = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil && $0.level == .normal }),
                let screen = monitor.screen ?? NSScreen.main
            else { return }
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.height = min(max(monitor.frame.height, 560), visible.height)
            frame.size.width = min(frame.width, 640)
            frame.origin.y = monitor.frame.maxY - frame.height
            if monitor.frame.maxX + 12 + frame.width <= visible.maxX {
                frame.origin.x = monitor.frame.maxX + 12
            } else if monitor.frame.minX - 12 - frame.width >= visible.minX {
                frame.origin.x = monitor.frame.minX - 12 - frame.width
            } else {
                return
            }
            frame.origin.y = max(frame.origin.y, visible.minY)
            window.setFrame(frame, display: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
