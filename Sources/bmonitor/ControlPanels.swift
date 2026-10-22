import MonitorCore
import SwiftUI

// Painéis dos popovers. Os valores vêm das listas que a câmera publica (`supportedISOs`,
// `supportedShutters`, faixas de WB, tint e zoom); nada aqui inventa valor aceito.

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

/// Grade de valores para escolher um: o escolhido fica invertido.
struct ChoiceGrid<Value: Hashable>: View {
    let values: [Value]
    let selected: Value?
    var columns = 4
    let label: (Value) -> String
    var marked: (Value) -> Bool = { _ in false }
    let choose: (Value) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(values, id: \.self) { value in
                Button { choose(value) } label: {
                    HStack(spacing: 4) {
                        Text(label(value))
                        if marked(value) { FlickerFreeMark() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ChoiceStyle(isOn: value == selected))
            }
        }
    }
}

struct ISOPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: String(localized: "Exposição automática")) {
                Picker(
                    "Exposição automática",
                    selection: Binding(
                        get: { model.state.autoExposure },
                        set: { model.set("/video/autoExposure", ["mode": $0]) })
                ) {
                    Text("Manual").tag("Off")
                    Text("Contínua").tag("Continuous")
                    Text("Uma vez").tag("OneShot")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            PanelSection(title: "ISO") {
                ChoiceGrid(
                    values: model.state.supportedISOs, selected: model.state.iso, columns: 5, label: String.init
                ) { model.setISO($0) }
            }
            if model.state.autoExposure != "Off" {
                Text("Escolher um ISO desliga a exposição automática.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct ShutterPanel: View {
    @Bindable var model: AppModel
    @State private var byAngle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Unidade", selection: $byAngle) {
                Text("Velocidade").tag(false)
                Text("Ângulo").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            PanelSection(title: byAngle ? String(localized: "Ângulo do obturador") : String(localized: "Velocidade do obturador")) {
                ChoiceGrid(
                    values: byAngle
                        ? model.state.shutterAngles.map(Shutter.angle) : model.state.shutterSpeeds.map(Shutter.speed),
                    selected: model.state.shutter, columns: 4, label: \.label,
                    marked: model.state.isFlickerFree
                ) { model.setShutter($0) }
            }
            HStack(spacing: 6) {
                FlickerFreeMark()
                Text("sem cintilação de luz da rede")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            if case .angle = model.state.shutter { byAngle = true }
        }
    }
}

/// Marca das velocidades que não cintilam com a luz da rede elétrica.
struct FlickerFreeMark: View {
    var body: some View {
        Image(systemName: "lightbulb.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("sem cintilação")
    }
}

/// Slider que segue a câmera quando parado e manda o valor enquanto é arrastado.
struct CameraSlider: View {
    let value: Double?
    let range: ClosedRange<Double>
    var step: Double = 1
    let send: (Double) -> Void

    @State private var local = 0.0
    @State private var editing = false

    var body: some View {
        // Sem `step` no Slider: o macOS desenharia uma marca por passo. O passo vale no envio.
        Slider(value: $local, in: range) { editing = $0 }
            .onAppear { local = value ?? range.lowerBound }
            .onChange(of: value) { _, new in
                if !editing, let new { local = new }
            }
            .onChange(of: local) { _, new in
                if editing { send((new / step).rounded() * step) }
            }
    }
}

struct WhiteBalancePanel: View {
    @Bindable var model: AppModel

    /// Presets de luz do app da Blackmagic: valores lidos do próprio app em 20/10
    /// (cada toque no iPhone mudou WB e tint juntos).
    private static let presets: [(symbol: String, title: String, kelvin: Int, tint: Int)] = [
        ("sun.max", "Sol", 5600, 10),
        ("cloud", "Nublado", 6500, 10),
        ("lightbulb", "Lâmpada", 3200, 0),
        ("light.panel", "Fluorescente", 4000, 15),
        ("circle.lefthalf.filled", "Luz mista", 4500, 15),
    ]

    var body: some View {
        let range = model.state.whiteBalanceRange
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: String(localized: "Luz")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Self.presets, id: \.title) { preset in
                        Button { model.applyPreset(kelvin: preset.kelvin, tint: preset.tint) } label: {
                            VStack(spacing: 4) {
                                // Altura fixa: os símbolos têm alturas diferentes e desalinhavam os nomes.
                                Image(systemName: preset.symbol).font(.system(size: 17)).frame(height: 20)
                                Text(LocalizedStringKey(preset.title)).font(.system(size: 11, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(
                            ChoiceStyle(
                                isOn: model.state.whiteBalance == preset.kelvin && model.state.tint == preset.tint))
                        .help("\(preset.kelvin) K, tint \(preset.tint > 0 ? "+" : "")\(preset.tint)")
                    }
                }
                // Ação, não escolha: fora da grade de presets e com cara de botão.
                Button {
                    model.set("/video/whiteBalance/doAuto", nil, awaitsEvent: false)
                } label: {
                    Label("Medir o branco agora", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .help("A câmera mede o branco da cena uma vez")
            }
            PanelSection(title: String(localized: "Balanço de branco")) {
                Text(verbatim: model.state.whiteBalance.map { "\($0) K" } ?? "—").font(Theme.value(28))
                CameraSlider(
                    value: model.state.whiteBalance.map(Double.init),
                    range: Double(range.lowerBound)...Double(range.upperBound), step: 50
                ) { model.set("/video/whiteBalance", ["whiteBalance": Int($0)], awaitsEvent: false) }
            }
            Text("A API remota do iPhone não tem WB automático contínuo nem trava; “Medir o branco agora” é o automático disponível.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TintPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let range = model.state.tintRange
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: String(localized: "Tint (verde ↔ magenta)")) {
                Text(verbatim: model.state.tint.map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "—").font(Theme.value(28))
                CameraSlider(
                    value: model.state.tint.map(Double.init),
                    range: Double(range.lowerBound)...Double(range.upperBound)
                ) { model.set("/video/whiteBalanceTint", ["whiteBalanceTint": Int($0)], awaitsEvent: false) }
            }
            Button("Zerar") { model.setTint(0) }
                .buttonStyle(.bordered)
        }
    }
}

struct FocusPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: String(localized: "Foco automático")) {
                Picker(
                    "Foco automático",
                    selection: Binding(
                        get: { model.autoFocusEnabled ? model.autoFocusMode : "Manual" },
                        set: { mode in
                            if mode == "Manual" {
                                model.setAutoFocus(enabled: false, mode: model.autoFocusMode)
                            } else {
                                model.setAutoFocus(enabled: true, mode: mode)
                            }
                        })
                ) {
                    // Sem "OneShot": em 20/10 esse modo fechou o Blackmagic Camera no iPhone.
                    // "Focar agora" e o clique no vídeo fazem o foco único sem esse risco.
                    Text("Contínuo").tag("Continuous")
                    Text("Manual").tag("Manual")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Button("Focar agora (\(Shortcut.focusNow.glyph))") { model.focusNow() }
                .buttonStyle(.bordered)
            PanelSection(title: String(localized: "Distância de foco")) {
                CameraSlider(value: model.state.focus, range: 0...1, step: 0.005) { model.setFocus($0) }
                Text("Mexer na distância passa para foco manual.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Clique no vídeo para focar num ponto.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct LensPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let lenses = model.state.lenses.filter(\.isAvailable)
        let ordered = lenses.filter { $0.facing != "front" }.sorted { $0.focalLength < $1.focalLength }
            + lenses.filter { $0.facing == "front" }
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: String(localized: "Lente")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(ordered) { lens in
                        Button { model.setLens(lens.id) } label: {
                            VStack(spacing: 3) {
                                LensIcon(lens: lens, rank: ordered.firstIndex(of: lens) ?? 0).frame(width: 26, height: 26)
                                Text(lens.facing == "front" ? String(localized: "Frontal") : lens.shortName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(verbatim: lens.isWideFront ? String(localized: "ampla \(lens.focalLength) mm") : "\(lens.focalLength) mm")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 66)
                        }
                        .buttonStyle(ChoiceStyle(isOn: lens.id == model.state.activeLensID, inset: 3))
                    }
                }
            }
            PanelSection(title: zoomTitle) {
                CameraSlider(value: model.state.zoomNormalized, range: 0...1, step: 0.005) {
                    model.set("/lens/zoom", ["normalised": $0], awaitsEvent: false)
                }
            }
            Toggle(
                "Estabilização óptica",
                isOn: Binding(
                    get: { model.state.stabilization },
                    set: { model.set("/lens/opticalImageStabilization", ["enabled": $0]) })
            )
            .toggleStyle(.switch)
        }
    }

    private var zoomTitle: String {
        guard let focal = model.state.zoomFocalLength else { return "Zoom" }
        if let range = model.state.zoomRange {
            return "Zoom · \(Int(focal.rounded())) mm (\(Int(range.lowerBound))–\(Int(range.upperBound)))"
        }
        return "Zoom · \(Int(focal.rounded())) mm"
    }
}

/// Ícone da lente: traseiras como anéis que crescem com a distância focal, como no app da
/// Blackmagic; frontais com o rosto de quem está diante do iPhone.
struct LensIcon: View {
    let lens: Lens
    let rank: Int

    var body: some View {
        if lens.facing == "front" {
            // Mesma família e peso dos anéis das traseiras: círculo com rosto.
            Image(systemName: lens.isWideFront ? "person.2.circle" : "person.crop.circle")
                .font(.system(size: 19, weight: .regular))
        } else {
            let diameter = 12 + CGFloat(min(rank, 5)) * 3
            ZStack {
                Circle().strokeBorder(lineWidth: 1.5).frame(width: diameter, height: diameter)
                Circle().frame(width: diameter * 0.38, height: diameter * 0.38)
            }
        }
    }
}

extension Lens {
    /// Frontal grande-angular ("LensFrontUltraWide").
    var isWideFront: Bool { facing == "front" && id.contains("UltraWide") }

    /// Rótulo curto da barra, sem quebra: "0.5×", "4×", "Frontal", "Frontal ampla".
    var shortName: String {
        if facing == "front" { return isWideFront ? String(localized: "Frontal ampla") : String(localized: "Frontal") }
        return zoomFactor.replacingOccurrences(of: "x", with: "×")
    }
}

struct GridPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: String(localized: "Grade")) {
                VStack(spacing: 6) {
                    ForEach(AppModel.GridStyle.allCases) { style in
                        Button { model.grid = style } label: {
                            HStack(spacing: 10) {
                                GridOverlay(style: style, thumbnail: true)
                                    .frame(width: 36, height: 22)
                                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
                                Text(style.title)
                                Spacer()
                            }
                        }
                        .buttonStyle(ChoiceStyle(isOn: model.grid == style))
                    }
                }
            }
            PanelSection(title: String(localized: "Área segura")) {
                VStack(spacing: 6) {
                    ForEach([SafeZone?.none] + SafeZone.allCases.map(Optional.some), id: \.self) { zone in
                        Button { model.safeZone = zone } label: {
                            HStack(spacing: 10) {
                                Group {
                                    if let zone { SafeZoneOverlay(zone: zone, thumbnail: true) } else { Color.clear }
                                }
                                .frame(width: 36, height: 22)
                                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
                                Text(zone?.title ?? String(localized: "Sem área segura"))
                                Spacer()
                            }
                        }
                        .buttonStyle(ChoiceStyle(isOn: model.safeZone == zone))
                    }
                }
                Text("Medidas que cada rede publica para vídeo vertical, conferidas em outubro de 2026. Com o vídeo deitado, mostra o recorte vertical do meio.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Quadros por segundo, item próprio da barra ao lado do shutter. As opções são as que o iPhone
/// publica para a resolução atual.
struct FrameRatePanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let state = model.state
        let current = state.recordFormat
        let option = state.supportedFormats.first { $0.resolution == current?.resolution }
        VStack(alignment: .leading, spacing: 16) {
            if state.recording {
                Label("Gravando: o formato fica travado até parar.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            PanelSection(title: String(localized: "Quadros por segundo")) {
                ChoiceGrid(values: option?.frameRates ?? [], selected: current?.frameRate, columns: 4, label: { $0 }) {
                    model.setFormat(frameRate: $0)
                }
            }
            .disabled(state.recording)
            .opacity(state.recording ? 0.4 : 1)
            Text("Trocar o formato reinicia o vídeo no Mac por um instante.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Resolução, codec e espaço de cor, com as opções que o iPhone publica; o fps tem painel
/// próprio. Os codecs ficam como a Blackmagic escreve; o espaço de cor usa os nomes da tela do
/// Blackmagic Camera, porque a API chama de `dynamicRange` com outros nomes.
struct FormatPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let state = model.state
        let current = state.recordFormat
        let option = state.supportedFormats.first { $0.resolution == current?.resolution }
        let families = Self.families(option?.codecs ?? [])
        let family = current.map { RecordFormat.family($0.codec) }
        let qualities = (option?.codecs ?? []).filter { RecordFormat.family($0) == family }.map(RecordFormat.quality)
        VStack(alignment: .leading, spacing: 16) {
            if state.recording {
                Label("Gravando: o formato fica travado até parar.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Group {
                PanelSection(title: String(localized: "Resolução")) {
                    ChoiceGrid(
                        values: state.supportedFormats.map(\.resolution), selected: current?.resolution, columns: 4,
                        label: { $0 }
                    ) { model.setFormat(resolution: $0) }
                }
                PanelSection(title: "Codec") {
                    ChoiceGrid(values: families, selected: family, columns: 2, label: Self.short) { chosen in
                        // Mesma qualidade na família nova, se ela tiver; senão a primeira dela.
                        let quality = current.map { RecordFormat.quality($0.codec) } ?? "Default"
                        let codecs = (option?.codecs ?? []).filter { RecordFormat.family($0) == chosen }
                        model.setFormat(codec: codecs.first { RecordFormat.quality($0) == quality } ?? codecs.first)
                    }
                }
                if qualities.count > 1, let family {
                    PanelSection(title: String(localized: "Qualidade")) {
                        ChoiceGrid(
                            values: qualities, selected: current.map { RecordFormat.quality($0.codec) }, columns: 4,
                            label: Self.quality
                        ) { model.setFormat(codec: "\(family):\($0)") }
                    }
                }
                if !state.supportedDynamicRanges.isEmpty {
                    PanelSection(title: String(localized: "Espaço de cor")) {
                        ChoiceGrid(
                            values: Self.colorSpaces(state.supportedDynamicRanges), selected: state.dynamicRange,
                            columns: 2, label: Self.colorSpace
                        ) { model.setDynamicRange($0) }
                        if state.dynamicRange == "Film" {
                            Text("O Apple Log 2 só se escolhe no iPhone. Com ele ligado, aqui aparece Apple Log.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .disabled(state.recording)
            .opacity(state.recording ? 0.4 : 1)
            Text("Trocar o formato reinicia o vídeo no Mac por um instante.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Famílias na ordem do uso comum: HEVC e H.264 antes dos ProRes.
    private static func families(_ codecs: [String]) -> [String] {
        var seen: [String] = []
        for family in codecs.map(RecordFormat.family) where !seen.contains(family) { seen.append(family) }
        let common = seen.filter { !$0.contains("ProRes") }
        return common + seen.filter { $0.contains("ProRes") }
    }

    /// "HEVC (H.265)" vira "HEVC"; "Apple ProRes 422 HQ" vira "ProRes 422 HQ".
    static func short(_ family: String) -> String {
        if family.hasPrefix("HEVC") { return "HEVC" }
        return family.hasPrefix("Apple ") ? String(family.dropFirst(6)) : family
    }

    /// Valores da API na ordem SDR e depois HDR; um valor desconhecido vai para o fim.
    private static func colorSpaces(_ values: [String]) -> [String] {
        let order = ["Video", "Extended Video", "HLG", "Film"]
        return order.filter(values.contains) + values.filter { !order.contains($0) }
    }

    /// Nome do espaço de cor no Blackmagic Camera. "Film" é o Apple Log: o Apple Log 2 não tem
    /// valor na API e, ligado no iPhone, também é lido como "Film" (visto em 21/10/2026).
    private static func colorSpace(_ raw: String) -> String {
        switch raw {
        case "Video": "Rec.709"
        case "Extended Video": "P3 D65"
        case "HLG": "Rec.2020 · HDR"
        case "Film": "Apple Log · HDR"
        default: raw
        }
    }

    private static func quality(_ raw: String) -> String {
        switch raw {
        case "Max": String(localized: "Máxima")
        case "High": String(localized: "Alta")
        case "Medium": String(localized: "Média")
        case "Low": String(localized: "Baixa")
        default: raw
        }
    }
}

struct AudioPanel: View {
    @Bindable var model: AppModel
    @State private var confirmSilence = false

    var body: some View {
        let current = model.state.audioInputs[0]
        let silent = model.state.silentInput
        let inputs = model.state.availableAudioInputs.filter { $0 != silent }
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: String(localized: "Nível (dBFS)")) {
                LiveAudioMeter(model: model, large: true)
            }
            if let gain = model.state.audioGain {
                // Logo abaixo do medidor: o efeito do ganho aparece enquanto se arrasta.
                PanelSection(title: String(localized: "Ganho (\(Shortcut.gainDown.glyph) \(Shortcut.gainUp.glyph))")) {
                    HStack(spacing: 10) {
                        CameraSlider(value: gain, range: 0...1, step: 0.01) { model.setAudioGain($0) }
                        Text(gain, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                    .disabled(!model.gainAdjustable)
                    if let input = current, model.gainRefusedInput == input
                        || model.state.audioGainRange.map({ $0.upperBound <= $0.lowerBound }) == true
                    {
                        Text("\(input) não aceita ajuste de ganho. Um microfone externo aceita.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PanelSection(title: String(localized: "Origem de áudio no iPhone")) {
                VStack(spacing: 6) {
                    ForEach(inputs, id: \.self) { input in
                        Button { model.setAudioInput(input) } label: {
                            Text(input).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(ChoiceStyle(isOn: input == current))
                    }
                }
            }
            if model.state.availableAudioInputs.contains(silent) {
                Divider()
                // Separado no fim da lista: um clique aqui deixa a gravação sem som. Vermelho só
                // quando escolhido, porque aí é o alarme.
                Button {
                    if model.state.recording { confirmSilence = true } else { model.setAudioInput(silent) }
                } label: {
                    Label("Sem áudio", systemImage: "mic.slash").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ChoiceStyle(isOn: current == silent, fill: Theme.rec))
                .confirmationDialog("Gravar sem áudio?", isPresented: $confirmSilence) {
                    Button("Desligar o áudio", role: .destructive) { model.setAudioInput(silent) }
                } message: {
                    Text("O clipe que está sendo gravado fica sem som a partir de agora.")
                }
            }
            Text("Um microfone sem fio aparece aqui quando o iPhone o reconhece.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            // Local, não muda a câmera: com o iPhone na mesma sala, som no Mac dá microfonia.
            Toggle("Ouvir no Mac (\(Shortcut.mute.glyph))", isOn: Binding(get: { !model.muted }, set: { model.muted = !$0 }))
                .toggleStyle(.switch)
        }
    }
}

/// Opção de uma lista: a escolhida fica preenchida na cor de destaque do sistema.
struct ChoiceStyle: ButtonStyle {
    var isOn: Bool
    /// Cor do preenchimento quando escolhida (vermelho para "Sem áudio").
    var fill: Color = .accentColor
    /// Respiro lateral; os botões de lente usam menos para "ampla 19 mm" caber inteiro.
    var inset: CGFloat = 8
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(isOn ? Color.white : .primary)
            .padding(.horizontal, inset)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? fill : .white.opacity(configuration.isPressed ? 0.2 : hovering ? 0.14 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
    }
}
