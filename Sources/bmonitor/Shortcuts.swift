import SwiftUI

/// Atalhos do teclado num lugar só: o menu os registra e a tela de atalhos os lista.
enum Shortcut: CaseIterable {
    case record, focusNow, iso, shutter, whiteBalance, tint, format, lens, audio, gainUp, gainDown, mute, grid, safeZone, rotate,
        script, follow, help

    var keyboard: KeyboardShortcut {
        switch self {
        case .record: KeyboardShortcut("r")
        case .focusNow: KeyboardShortcut("f", modifiers: [])
        case .iso: KeyboardShortcut("i", modifiers: [])
        case .shutter: KeyboardShortcut("s", modifiers: [])
        case .whiteBalance: KeyboardShortcut("w", modifiers: [])
        case .tint: KeyboardShortcut("t", modifiers: [])
        case .format: KeyboardShortcut("k", modifiers: [])
        case .lens: KeyboardShortcut("l", modifiers: [])
        case .audio: KeyboardShortcut("a", modifiers: [])
        // Setas com ⌥: iguais em qualquer teclado, ao contrário de + e -.
        case .gainUp: KeyboardShortcut(.upArrow, modifiers: .option)
        case .gainDown: KeyboardShortcut(.downArrow, modifiers: .option)
        case .mute: KeyboardShortcut("m", modifiers: [])
        case .grid: KeyboardShortcut("g", modifiers: [])
        case .safeZone: KeyboardShortcut("z", modifiers: [])
        // Longe do ⌘R: girar a janela nunca pode parar uma gravação por um Shift esquecido.
        case .rotate: KeyboardShortcut(.rightArrow, modifiers: .command)
        // Segunda janela do app, como ⌘2 em outros apps de várias janelas.
        case .script: KeyboardShortcut("2", modifiers: .command)
        case .follow: KeyboardShortcut("v", modifiers: [])
        case .help: KeyboardShortcut("/", modifiers: .command)
        }
    }

    var title: String {
        switch self {
        case .record: String(localized: "Gravar ou parar")
        case .focusNow: String(localized: "Focar agora")
        case .iso: "ISO"
        case .shutter: "Shutter"
        case .whiteBalance: String(localized: "Balanço de branco")
        case .tint: "Tint"
        case .format: String(localized: "Formato de gravação")
        case .lens: String(localized: "Lente e zoom")
        case .audio: String(localized: "Origem de áudio")
        case .gainUp: String(localized: "Subir o ganho do áudio")
        case .gainDown: String(localized: "Baixar o ganho do áudio")
        case .mute: String(localized: "Som da câmera no Mac (ligar ou mudo)")
        case .grid: String(localized: "Mostrar ou esconder a grade")
        case .safeZone: String(localized: "Mostrar ou esconder a área segura")
        case .rotate: String(localized: "Girar 90°")
        case .script: String(localized: "Mostrar o roteiro")
        case .follow: String(localized: "Seguir a fala no roteiro")
        case .help: String(localized: "Atalhos do teclado")
        }
    }

    /// Como o atalho aparece escrito: "⌘R", "F", "⌘→".
    var glyph: String {
        let mods = keyboard.modifiers
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        switch keyboard.key {
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .escape: text += "esc"
        default: text += String(keyboard.key.character).uppercased()
        }
        return text
    }
}

extension View {
    /// `typing`: o roteiro está em edição. Atalho de uma tecla só sairia do menu no lugar da
    /// letra digitada, então ele fica desligado até a edição acabar.
    func keyboardShortcut(_ shortcut: Shortcut, typing: Bool = false) -> some View {
        keyboardShortcut(typing && shortcut.keyboard.modifiers.isEmpty ? nil : shortcut.keyboard)
    }
}

/// Lista de atalhos sobre o vídeo, aberta por ⌘/ ou pelo menu Ajuda. Fecha com esc, ⌘/
/// ou clique fora.
struct ShortcutsOverlay: View {
    @Bindable var model: AppModel

    private struct Row: Identifiable {
        let keys: String
        let title: String
        var id: String { title }
    }

    private static func rows(_ shortcuts: [Shortcut]) -> [Row] {
        shortcuts.map { Row(keys: $0.glyph, title: $0.title) }
    }

    private let sections: [(title: String, rows: [Row])] = [
        (
            String(localized: "Gravação e foco"),
            rows([.record, .focusNow])
                + [Row(keys: String(localized: "Clique"), title: String(localized: "Focar no ponto do vídeo"))]
        ),
        (String(localized: "Abrir controle"), rows([.iso, .shutter, .whiteBalance, .tint, .format, .lens, .audio, .gainUp, .gainDown])),
        (
            String(localized: "No Mac"),
            rows([.mute, .grid, .safeZone, .rotate]) + [Row(keys: "esc", title: String(localized: "Fechar o controle aberto"))]
                + rows([.script, .follow])
                + [Row(keys: "↑ ↓", title: String(localized: "Frase anterior ou próxima no roteiro"))]
                + rows([.help])
        ),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { model.showsShortcuts = false }
            // Lado a lado na janela deitada; empilhado (com rolagem) na janela em pé ou pequena.
            // O cartão abraça o conteúdo: não se estica até as bordas da janela.
            ViewThatFits(in: .horizontal) {
                card { HStack(alignment: .top, spacing: 32) { columns } }.fixedSize()
                card { ScrollView { VStack(alignment: .leading, spacing: 18) { columns } } }
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .transition(.opacity)
    }

    private func card<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Atalhos do teclado").font(.title3.weight(.semibold))
                Spacer(minLength: 24)
                Button("Fechar") { model.showsShortcuts = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            }
            body()
        }
        .padding(22)
        .hudGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var columns: some View {
        ForEach(sections, id: \.title) { section in
            PanelSection(title: section.title) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    ForEach(section.rows) { row in
                        GridRow {
                            // Largura fixa: os nomes alinham entre as seções, não só dentro de cada uma.
                            KeyCap(text: row.keys).frame(width: 56, alignment: .leading)
                            Text(row.title).font(.system(size: 13)).fixedSize()
                        }
                    }
                }
            }
            .fixedSize()
        }
    }
}

/// Tecla desenhada: o rótulo numa placa clara, como nas listas de atalhos do macOS.
private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 22)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityLabel(text)
    }
}
