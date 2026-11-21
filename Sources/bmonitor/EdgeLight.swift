import AppKit
import SwiftUI

/// Luz de borda, como a do Photo Booth: a borda das telas escolhidas acende e ilumina o rosto.
/// Mora só no Mac: não fala com o iPhone nem passa pelo caminho do vídeo. Cada tela acesa
/// ganha uma janela transparente por cima de tudo, que deixa o clique passar.
@MainActor @Observable
final class EdgeLight {
    enum Mode: String, CaseIterable, Identifiable {
        /// Cor parada.
        case steady
        /// A cor escolhida sobe e desce de brilho.
        case breathe
        /// A borda inteira passa por todas as cores.
        case rainbow
        /// As cores correm em volta da tela.
        case flow

        var id: String { rawValue }
        var title: String {
            switch self {
            case .steady: String(localized: "Fixa")
            case .breathe: String(localized: "Respirar")
            case .rainbow: String(localized: "Arco-íris")
            case .flow: String(localized: "Correr")
            }
        }
        var animated: Bool { self != .steady }
        /// Os modos de arco-íris fazem a própria cor; a escolhida só vale nos outros.
        var usesColor: Bool { self == .steady || self == .breathe }
    }

    /// Uma tela ligada ao Mac, pelo UUID do monitor: o número do `NSScreen` muda ao religar.
    struct Display: Identifiable, Hashable {
        let id: String
        let name: String
    }

    var isOn = false { didSet { store(isOn, "isOn"); refresh() } }
    var mode: Mode { didSet { store(mode.rawValue, "mode") } }
    /// Branca na temperatura escolhida, ou a cor escolhida.
    var white: Bool { didSet { store(white, "white") } }
    var kelvin: Double { didSet { store(kelvin, "kelvin") } }
    var color: Color { didSet { store(Self.hex(color), "color") } }
    /// 0,1 a 1.
    var brightness: Double { didSet { store(brightness, "brightness") } }
    /// Espessura da faixa acesa, em pontos.
    var thickness: Double { didSet { store(thickness, "thickness") } }
    /// Segundos de uma volta nos modos animados.
    var period: Double { didSet { store(period, "period") } }
    /// Telas escolhidas, pelo UUID. Vazio = a tela principal.
    var selected: Set<String> { didSet { store(Array(selected), "screens"); refresh() } }
    private(set) var displays: [Display] = []

    static let kelvinRange: ClosedRange<Double> = 2700...7500
    static let thicknessRange: ClosedRange<Double> = 24...160
    static let periodRange: ClosedRange<Double> = 2...20
    static let swatches: [Color] = [
        Color(red: 1, green: 0.23, blue: 0.19), Color(red: 1, green: 0.58, blue: 0), Color(red: 1, green: 0.18, blue: 0.57),
        Color(red: 0.69, green: 0.32, blue: 0.87), Color(red: 0.2, green: 0.35, blue: 1), Color(red: 0.2, green: 0.78, blue: 0.95),
        Color(red: 0.2, green: 0.84, blue: 0.4),
    ]

    private var windows: [String: NSPanel] = [:]
    private var screenObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        func value<T>(_ key: String) -> T? { defaults.object(forKey: "edgeLight." + key) as? T }
        mode = value("mode").flatMap(Mode.init(rawValue:)) ?? .steady
        white = value("white") ?? true
        kelvin = value("kelvin") ?? 5000
        color = value("color").flatMap(Self.color(hex:)) ?? Self.swatches[4]
        brightness = value("brightness") ?? 1
        thickness = value("thickness") ?? 60
        period = value("period") ?? 8
        selected = Set(value("screens") ?? [String]())
        displays = Self.connectedDisplays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displays = Self.connectedDisplays()
                // Tela que mudou de tamanho ou de lugar: as janelas voltam no tamanho novo.
                self.windows.values.forEach { $0.orderOut(nil) }
                self.windows.removeAll()
                self.refresh()
            }
        }
        // `isOn` não é lido do disco: luz que acende sozinha ao abrir o app assusta.
        // Desenvolvimento: `--edge-light <modo>` acende ao abrir, para capturas de revisão.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--edge-light") {
            if i + 1 < args.count, let mode = Mode(rawValue: args[i + 1]) { self.mode = mode }
            DispatchQueue.main.async { self.isOn = true }
        }
    }

    func toggle() { isOn.toggle() }

    func isLit(_ display: Display) -> Bool { litIDs.contains(display.id) }

    /// Liga ou desliga uma tela. A última acesa não apaga por aqui: para isso há a chave.
    func toggle(_ display: Display) {
        var ids = litIDs
        if ids.contains(display.id) {
            guard ids.count > 1 else { return }
            ids.remove(display.id)
        } else {
            ids.insert(display.id)
        }
        selected = ids
    }

    /// Telas acesas de fato: as escolhidas que estão ligadas ou, sem nenhuma, a principal.
    private var litIDs: Set<String> {
        let connected = Set(displays.map(\.id))
        let chosen = selected.intersection(connected)
        if !chosen.isEmpty { return chosen }
        return displays.first.map { [$0.id] } ?? []
    }

    /// Cor de base, já com a temperatura quando branca.
    var baseColor: Color { white ? Self.color(kelvin: kelvin) : color }

    private func refresh() {
        let lit = isOn ? litIDs : []
        for (id, window) in windows where !lit.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }
        for screen in NSScreen.screens {
            guard let id = Self.uuid(of: screen), lit.contains(id), windows[id] == nil else { continue }
            windows[id] = makeWindow(on: screen)
        }
    }

    private func makeWindow(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        // Acima da barra de menus e das janelas, abaixo dos menus e popovers.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSHostingView(rootView: EdgeGlow(light: self))
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        return panel
    }

    // MARK: - Telas

    private static func connectedDisplays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            uuid(of: screen).map { Display(id: $0, name: screen.localizedName) }
        }
    }

    private static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: - Cor

    /// Branco de uma lâmpada nessa temperatura (aproximação de Tanner Helland do corpo negro).
    static func color(kelvin: Double) -> Color {
        let t = kelvin / 100
        let red = t <= 66 ? 1 : min(max(329.698727446 * pow(t - 60, -0.1332047592) / 255, 0), 1)
        let green =
            t <= 66
            ? min(max((99.4708025861 * log(t) - 161.1195681661) / 255, 0), 1)
            : min(max(288.1221695283 * pow(t - 60, -0.0755148492) / 255, 0), 1)
        let blue = t >= 66 ? 1 : t <= 19 ? 0 : min(max((138.5177312231 * log(t - 10) - 305.0447927307) / 255, 0), 1)
        return Color(red: red, green: green, blue: blue)
    }

    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private static func color(hex: String) -> Color? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: "edgeLight." + key)
    }
}

/// A borda acesa de uma tela: faixa cheia junto da borda e um degradê suave para dentro.
/// Em faixas concêntricas, não em desfoque: o desfoque da tela inteira a cada quadro pesaria
/// na GPU que também mostra o vídeo.
struct EdgeGlow: View {
    let light: EdgeLight

    var body: some View {
        // Lido aqui, no corpo, para a tela redesenhar quando um ajuste muda com a luz parada.
        let style = Style(
            mode: light.mode, color: light.baseColor, brightness: light.brightness, thickness: light.thickness,
            period: light.period)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !style.mode.animated)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in Self.draw(style, in: &context, size: size, time: time) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private struct Style {
        let mode: EdgeLight.Mode
        let color: Color
        let brightness: Double
        let thickness: Double
        let period: Double
    }

    private static func draw(_ light: Style, in context: inout GraphicsContext, size: CGSize, time: Double) {
        let phase = (time / light.period).truncatingRemainder(dividingBy: 1)
        var alpha = light.brightness
        let shading: GraphicsContext.Shading
        switch light.mode {
        case .steady:
            shading = .color(light.color)
        case .breathe:
            alpha *= 0.55 + 0.45 * (0.5 + 0.5 * cos(phase * 2 * .pi))
            shading = .color(light.color)
        case .rainbow:
            shading = .color(Color(hue: phase, saturation: 1, brightness: 1))
        case .flow:
            let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) }
            shading = .conicGradient(
                Gradient(colors: stops), center: CGPoint(x: size.width / 2, y: size.height / 2),
                angle: .degrees(phase * 360))
        }
        // Tudo numa camada a brilho cheio e o brilho na camada inteira: assim as faixas que se
        // sobrepõem não clareiam a borda.
        context.opacity = alpha
        context.drawLayer { layer in
            let band = light.thickness
            let rect = CGRect(origin: .zero, size: size)
            let radius = max(band * 0.9, 18)
            func edge(inset: Double) -> Path {
                // A tela inteira menos o miolo arredondado.
                var path = Path(rect)
                path.addPath(Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: radius + inset - band, style: .continuous))
                return path
            }
            layer.fill(edge(inset: band), with: shading, style: FillStyle(eoFill: true))
            // Degradê para dentro: bordas cada vez mais largas e fracas, uma sobre a outra. Cada
            // contorno é desenhado uma vez só, sem as emendas que anéis lado a lado deixam.
            let fade = band * 0.9
            let steps = 28
            for i in 0..<steps {
                var faint = layer
                faint.opacity = 2.4 / Double(steps)
                faint.fill(edge(inset: band + fade * Double(i + 1) / Double(steps)), with: shading, style: FillStyle(eoFill: true))
            }
        }
    }
}

/// Popover da luz de borda.
struct EdgeLightPanel: View {
    @Bindable var light: EdgeLight

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $light.isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Luz de borda").font(.headline)
                    Text("A borda da tela acende e ilumina o rosto, como no Photo Booth.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            PanelSection(title: String(localized: "Efeito")) {
                ChoiceGrid(values: EdgeLight.Mode.allCases, selected: light.mode, columns: 2, label: \.title) { light.mode = $0 }
            }

            if light.mode.usesColor {
                PanelSection(title: String(localized: "Cor")) {
                    HStack(spacing: 6) {
                        Button("Branca") { light.white = true }.buttonStyle(ChoiceStyle(isOn: light.white))
                        Button("Colorida") { light.white = false }.buttonStyle(ChoiceStyle(isOn: !light.white))
                    }
                    if light.white {
                        LabeledSlider(
                            title: String(localized: "Temperatura"), value: $light.kelvin, range: EdgeLight.kelvinRange,
                            text: "\(Int(light.kelvin / 100) * 100) K")
                    } else {
                        HStack(spacing: 8) {
                            ForEach(Array(EdgeLight.swatches.enumerated()), id: \.offset) { _, swatch in
                                Button { light.color = swatch } label: {
                                    Circle().fill(swatch).frame(width: 22, height: 22)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: EdgeLight.hex(light.color) == EdgeLight.hex(swatch) ? 2 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                            ColorPicker("", selection: $light.color, supportsOpacity: false).labelsHidden()
                        }
                    }
                }
            }

            PanelSection(title: String(localized: "Ajustes")) {
                LabeledSlider(
                    title: String(localized: "Brilho"), value: $light.brightness, range: 0.1...1,
                    text: "\(Int((light.brightness * 100).rounded()))%")
                LabeledSlider(
                    title: String(localized: "Espessura"), value: $light.thickness, range: EdgeLight.thicknessRange,
                    text: "\(Int(light.thickness)) pt")
                if light.mode.animated {
                    // Mais rápido à direita: o slider vai do período longo para o curto.
                    LabeledSlider(
                        title: String(localized: "Velocidade"),
                        value: Binding(
                            get: { EdgeLight.periodRange.upperBound + EdgeLight.periodRange.lowerBound - light.period },
                            set: { light.period = EdgeLight.periodRange.upperBound + EdgeLight.periodRange.lowerBound - $0 }),
                        range: EdgeLight.periodRange, text: String(format: "%.0f s", light.period))
                }
            }

            PanelSection(title: String(localized: "Telas")) {
                VStack(spacing: 6) {
                    ForEach(light.displays) { display in
                        Button { light.toggle(display) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: light.isLit(display) ? "checkmark.circle.fill" : "circle")
                                Text(display.name)
                                Spacer()
                            }
                        }
                        .buttonStyle(ChoiceStyle(isOn: light.isLit(display)))
                    }
                }
            }
        }
    }
}

/// Slider com o nome à esquerda e o valor à direita.
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range)
        }
    }
}
