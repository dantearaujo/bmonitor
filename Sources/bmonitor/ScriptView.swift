import AppKit
import MonitorCore
import SwiftUI

/// O roteiro dentro da janela do monitor, ao lado do vídeo e no mesmo preto: texto grande,
/// a frase atual em branco a um terço da altura. O canto de cima diz em que fala você está e
/// se o Mac está ouvindo; os controles ficam numa cápsula na base, que aparece e some com a
/// barra do vídeo.
struct ScriptPanel: View {
    let app: AppModel
    @State private var draft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: ScriptModel { app.script }
    private var cameraConnected: Bool { app.phase == .connected }

    /// Altura da faixa dos botões da janela, a mesma do monitor.
    private let titlebarInset: CGFloat = 28

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if model.editing {
                editor
            } else if model.script.isEmpty {
                empty
            } else {
                // Com a cápsula à vista, o texto some antes dela: nenhuma letra por trás do vidro.
                ScriptReading(model: model, bottomClearance: app.controlsVisible ? 84 : 0)
            }
            header
            // Sem roteiro, a cápsula fica só com destacar e o menu (colar, abrir).
            if !model.editing {
                controls
                    .opacity(app.controlsVisible ? 1 : 0)
                    .offset(y: app.controlsVisible || reduceMotion ? 0 : 12)
                    .animation(.easeOut(duration: 0.25), value: app.controlsVisible)
                    .allowsHitTesting(app.controlsVisible)
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        // Fio de 1 pt entre o texto e o vídeo: um app só, duas áreas. Destacado, não há vídeo ao lado.
        .overlay(alignment: dividerEdge) {
            if !model.detached {
                let side = app.scriptSide
                Rectangle().fill(.white.opacity(0.1))
                    .frame(width: side.isVertical ? nil : 1, height: side.isVertical ? 1 : nil)
            }
        }
        // Na janela própria, o mouse sobre o roteiro também mostra os controles.
        .onContinuousHover { phase in
            if model.detached, case .active = phase { app.pokeControls() }
        }
        // A edição pode começar pelo menu (⌘E): o rascunho parte do texto atual.
        .onChange(of: model.editing, initial: true) { _, editing in
            if editing { draft = model.text }
        }
    }

    /// A borda do roteiro que encosta no vídeo.
    private var dividerEdge: Alignment {
        switch app.scriptSide {
        case .right: .leading
        case .left: .trailing
        case .top: .bottom
        case .bottom: .top
        }
    }

    // MARK: - Canto de cima

    /// Do lado de fora dos botões da janela: sempre no canto direito do painel.
    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if model.editing {
                Text("Editando o roteiro").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Button("Concluído") { finishEditing() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else if !model.script.isEmpty {
                status
            }
        }
        .padding(.horizontal, 16)
        .frame(height: titlebarInset + 12)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if model.following {
                Image(systemName: followAlert ? "exclamationmark.triangle.fill" : "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: listening)
                    .foregroundStyle(followAlert ? Theme.warn : listening ? Color.accentColor : .secondary)
            }
            if let note = followNote {
                // Mensagem do reconhecedor pode ser longa: quebra em vez de cortar.
                Text(note).foregroundStyle(followAlert ? Theme.warn : .secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress = model.progress {
                Text("Fala \(progress.current) de \(progress.total)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .accessibilityElement(children: .combine)
    }

    private var listening: Bool {
        model.following && model.listening == .listening && (cameraConnected || CommandLine.arguments.contains("--script-audio"))
    }

    /// Só quando seguir a fala não está ouvindo: o motivo no lugar do número da fala.
    private var followNote: String? {
        guard model.following else { return nil }
        switch model.listening {
        case .off, .preparing: return String(localized: "Preparando o reconhecimento…")
        case .unavailable(let message): return message
        case .listening:
            return listening ? nil : String(localized: "Sem áudio da câmera")
        }
    }

    private var followAlert: Bool {
        guard model.following else { return false }
        if case .unavailable = model.listening { return true }
        return model.listening == .listening && !listening
    }

    // MARK: - Controles

    /// Na mesma altura e no mesmo vidro da barra do vídeo. O tamanho do texto sai primeiro
    /// quando o painel é estreito; ele também está no menu "…" e em ⌘+ e ⌘−.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(withSize: true)
            controlRow(withSize: false)
        }
    }

    private func controlRow(withSize: Bool) -> some View {
        HStack(spacing: 4) {
            if !model.script.isEmpty {
                Button { model.toggleFollowing() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.following ? "waveform" : "waveform.slash")
                            .font(.system(size: 15, weight: .medium))
                            .symbolEffect(.variableColor.iterative, isActive: listening)
                            .frame(width: 20)
                        Text("Seguir a fala").font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Theme.barItem)
                }
                .buttonStyle(HUDItemStyle(isOn: model.following))
                .help(String(localized: "O roteiro anda sozinho enquanto você fala, pelo som da câmera (\(Shortcut.follow.glyph))"))
                if withSize {
                    Divider().frame(height: 26).padding(.horizontal, 2)
                    Button { model.adjustFont(by: -2) } label: { icon("textformat.size.smaller") }
                        .buttonStyle(HUDItemStyle())
                        .help(String(localized: "Texto menor (⌘−)"))
                    Button { model.adjustFont(by: 2) } label: { icon("textformat.size.larger") }
                        .buttonStyle(HUDItemStyle())
                        .help(String(localized: "Texto maior (⌘+)"))
                }
            }
            // Alterna entre barra lateral e janela: o ícone mostra o que ele vira (janela, ou a
            // barra do lado em que vai encaixar).
            Button { model.detached ? app.attachScript() : app.detachScript() } label: {
                icon(model.detached ? app.scriptSide.symbol : "macwindow")
            }
            .buttonStyle(HUDItemStyle())
            .help(
                model.detached
                    ? String(localized: "Juntar o roteiro à janela da câmera")
                    : String(localized: "Destacar o roteiro numa janela própria"))
            Menu {
                ScriptActions(model: app)
            } label: {
                icon("ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(HUDItemStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Mais do roteiro"))
        }
        .padding(6)
        .hudGlass(Capsule())
        .fixedSize()
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: Theme.barItem, height: Theme.barItem)
    }

    // MARK: - Estados

    private var empty: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Cole o seu roteiro")
                    .font(.system(size: 22, weight: .semibold))
                Text("Texto ou Markdown, com títulos, negrito e listas. O bmonitor guarda o último roteiro.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { emptyButtons }
                VStack(spacing: 8) { emptyButtons }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var emptyButtons: some View {
        Button("Colar") { model.paste() }
            .buttonStyle(.borderedProminent)
        Button("Abrir arquivo…") { model.open() }
        Button("Escrever") { model.editing = true }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 17))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(.horizontal, 28)
            .padding(.top, titlebarInset + 20)
            // A linha que rola para fora esmaece na base, como na leitura, em vez de cortar seca.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 44)
                }
            }
            .onExitCommand { finishEditing() }
    }

    private func finishEditing() {
        if draft != model.text { model.replace(with: draft) }
        model.editing = false
    }
}

/// O texto do roteiro, rolando para manter a frase atual a um terço da altura.
private struct ScriptReading: View {
    let model: ScriptModel
    /// Altura da base que fica livre de texto (a cápsula de controles, quando aparece).
    let bottomClearance: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                                fontSize: model.fontSize
                            )
                            .id(block.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.moveToBlock(block.id) }
                            // `set`, não `push`: com a pilha, o painel fechando sob o mouse deixava a mão presa.
                            .onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 40)
                    // Folga em cima e embaixo: a primeira e a última frase também chegam ao terço.
                    .padding(.top, geometry.size.height * 0.3)
                    .padding(.bottom, geometry.size.height * 0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                // O texto esmaece nas bordas em vez de cortar seco sob os botões da janela e a barra.
                .mask {
                    let height = max(geometry.size.height, 1)
                    let end = max(height - bottomClearance, height * 0.5) / height
                    // Acima ou abaixo do vídeo o roteiro é baixo: o esmaecido de cima encolhe junto.
                    let clearTop = min(40, height * 0.1) / height
                    let fullTop = min(110, height * 0.25) / height
                    LinearGradient(
                        stops: [
                            // Em cima, livre até abaixo do canto de status ("Fala 6 de 18").
                            .init(color: .clear, location: 0), .init(color: .clear, location: clearTop),
                            .init(color: .black, location: fullTop),
                            .init(color: .black, location: end - 0.12), .init(color: .clear, location: end),
                        ], startPoint: .top, endPoint: .bottom)
                    .animation(.easeOut(duration: 0.25), value: bottomClearance)
                }
                .onAppear { proxy.scrollTo(currentBlock, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                .onChange(of: currentBlock) { _, block in
                    // Reduzir Movimento: salta para a frase, sem rolar.
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                        proxy.scrollTo(block, anchor: UnitPoint(x: 0.5, y: 0.3))
                    }
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

    /// Escada de opacidade do branco: dito 22%, por vir 60% (legível, para ler adiante), frase
    /// atual 100%.
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
