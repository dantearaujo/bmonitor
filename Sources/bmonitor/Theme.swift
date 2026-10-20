import SwiftUI

/// Tokens do contrato "padrão da categoria" (`.impeccable/surfaces/`): o sistema dá tipo,
/// vidro e destaque; o app só reserva o vermelho para REC e erro e o laranja para alerta.
enum Theme {
    static let rec = Color(nsColor: .systemRed)
    static let warn = Color.orange

    static func value(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold).monospacedDigit() }
}

/// Liquid Glass do macOS 26, com material translúcido nas versões anteriores.
private struct HUDGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func hudGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(HUDGlass(shape: shape, interactive: interactive))
    }
}

/// Um valor da barra: rótulo pequeno em cima, valor embaixo. Pendente mostra um indicador
/// de progresso até a câmera confirmar; falha fica vermelha por um instante.
struct ValueItem: View {
    let label: String
    let value: String
    var pending = false
    var failed = false
    var tint: Color?
    /// Janela estreita: mesmo rótulo, letra e respiro menores.
    var compact = false
    /// Janela em pé estreita: respiro mínimo para a barra ficar numa linha só.
    var tight = false

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: compact ? 9 : 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .font(Theme.value(compact ? 13 : 15))
                    .truncationMode(.middle)
                    .foregroundStyle(failed ? Theme.rec : tint ?? .primary)
                if pending { ProgressView().controlSize(.mini) }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, tight ? 4 : compact ? 6 : 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Botão da barra: realce no hover, como os controles do QuickTime.
struct HUDItemStyle: ButtonStyle {
    var isOn = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Ligado ou aberto aparece como cápsula preenchida, como um toggle de toolbar do
            // macOS; o texto fica primary para continuar legível sobre o vidro.
            .foregroundStyle(.primary)
            // Cápsula: concêntrica com a borda da barra, que também é cápsula.
            .background(
                Capsule().fill(.white.opacity(configuration.isPressed ? 0.28 : isOn ? 0.2 : hovering ? 0.12 : 0)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }
}
