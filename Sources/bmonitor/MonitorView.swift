import MonitorCore
import SwiftUI

/// O monitor: vídeo na janela inteira, grade, status nos cantos e a barra de controles em
/// vidro na base. A janela tem a proporção do vídeo (ver `WindowShaper`).
struct MonitorView: View {
    @Bindable var model: AppModel

    /// Altura da barra de título oculta: os cantos de cima ficam abaixo dos botões da janela.
    private let titlebarInset: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let rect = videoRect(in: geometry.size)
            ZStack {
                Color.black
                switch model.phase {
                case .searching:
                    SearchingCard(model: model)
                case .connecting(let host):
                    MessageCard(title: String(localized: "Conectando"), detail: host, spinning: true)
                case .connected:
                    VideoLayerView(layer: model.displayLayer, quarterTurns: model.quarterTurns)
                    if model.videoFrozen {
                        // Quadro parado não pode parecer ao vivo: escurece até o vídeo voltar.
                        Color.black.opacity(0.6).allowsHitTesting(false)
                    }
                    if model.grid != .off {
                        GridOverlay(style: model.grid).frame(width: rect.width, height: rect.height).position(rect.center)
                    }
                    if let zone = model.safeZone {
                        SafeZoneOverlay(zone: zone).frame(width: rect.width, height: rect.height).position(rect.center)
                    }
                    // Sem câmera, o estado de gravação é desconhecido: a borda não afirma nada.
                    if model.state.recording, model.signal != .cameraGone {
                        // Tally: de longe, a borda vermelha diz que está gravando.
                        Rectangle()
                            .strokeBorder(Theme.rec, lineWidth: 3)
                            .frame(width: rect.width, height: rect.height)
                            .position(rect.center)
                            .allowsHitTesting(false)
                    }
                    focusArea(rect)
                    if let mark = model.focusMark { FocusReticle(mark: mark.point, at: mark.at) }
                    switch model.signal {
                    case .cameraGone:
                        MessageCard(
                            title: String(localized: "Sem câmera"),
                            detail: String(localized: "Abra o Blackmagic Camera no iPhone. Reconecto sozinho."),
                            spinning: true)
                    case .lost:
                        MessageCard(
                            title: String(localized: "Vídeo parado"),
                            detail: model.streamError ?? String(localized: "Pedindo o vídeo de novo ao iPhone."),
                            spinning: true)
                    case .waiting:
                        MessageCard(title: String(localized: "Aguardando vídeo"), detail: model.streamError, spinning: true)
                    case .ok, .lossy:
                        EmptyView()
                    }
                    HUD(model: model).padding(.top, titlebarInset)
                }
                if model.showsShortcuts { ShortcutsOverlay(model: model) }
            }
            .coordinateSpace(name: "monitor")
        }
        .ignoresSafeArea()
        .onContinuousHover { _ in model.pokeControls() }
        .onChange(of: model.controlsVisible) { _, visible in WindowShaper.setTitlebarVisible(visible) }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            WindowShaper.fit(aspect: model.displayAspect, animate: false)
        }
        .preferredColorScheme(.dark)
    }

    /// Clique no vídeo foca naquele ponto.
    private func focusArea(_ rect: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .position(rect.center)
            .onTapGesture(coordinateSpace: .named("monitor")) { point in
                guard model.acceptsVideoClick else { return }
                if model.panel != nil {
                    model.panel = nil
                    return
                }
                let u = (point.x - rect.minX) / rect.width
                let v = (point.y - rect.minY) / rect.height
                guard (0...1).contains(u), (0...1).contains(v) else { return }
                model.focus(atDisplay: CGPoint(x: u, y: v), windowPoint: point)
            }
            .help("Clique para focar neste ponto")
    }

    /// Retângulo que o vídeo ocupa depois de girar e caber (aspect fit).
    private func videoRect(in container: CGSize) -> CGRect {
        let video = model.displayAspect
        let fit = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * fit, height: video.height * fit)
        return CGRect(
            x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - HUD

/// Cantos de cima sempre visíveis (gravação e saúde); barra de controles na base só com
/// o mouse em movimento.
struct HUD: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Janela estreita (em pé): primeiro aperta o respiro; o nome do microfone só sai
            // em último caso, porque é o que se confere de longe.
            ViewThatFits(in: .horizontal) {
                topRow(showsMicName: true, tight: false)
                topRow(showsMicName: true, tight: true)
                topRow(showsMicName: true, tight: true, compactHealth: true)
                topRow(showsMicName: true, tight: true, compactHealth: true, stacked: true)
                topRow(showsMicName: false, tight: true, compactHealth: true, stacked: true)
            }
            Spacer(minLength: 0)
            ControlBar(model: model)
                .opacity(model.controlsVisible ? 1 : 0)
                .offset(y: model.controlsVisible ? 0 : 12)
                .animation(.easeOut(duration: 0.25), value: model.controlsVisible)
                .allowsHitTesting(model.controlsVisible)
        }
        .padding(16)
    }

    private func topRow(showsMicName: Bool, tight: Bool, compactHealth: Bool = false, stacked: Bool = false)
        -> some View
    {
        HStack(alignment: .top) {
            RecordingChip(model: model, showsMicName: showsMicName, tight: tight, stacked: stacked)
            Spacer(minLength: tight ? 6 : 12)
            HealthChip(model: model, tight: tight, compact: compactHealth)
        }
    }
}

/// REC ou STBY com o timecode, e o áudio: o que se confere de longe, num lugar só.
struct RecordingChip: View {
    @Bindable var model: AppModel
    var showsMicName = true
    var tight = false
    /// Janela em pé e estreita: o áudio desce para uma segunda linha em vez de perder o nome.
    var stacked = false

    var body: some View {
        // Sem câmera não há mic conhecido nem som para medir: o áudio sai da cápsula.
        let known = model.signal != .cameraGone
        Group {
            if stacked && known {
                VStack(alignment: .leading, spacing: 6) {
                    recording(known: known)
                    AudioStatus(model: model, showsName: showsMicName)
                }
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .hudGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                HStack(spacing: tight ? 6 : 8) {
                    recording(known: known)
                    if known {
                        Divider().frame(height: 20).padding(.horizontal, 2)
                        AudioStatus(model: model, showsName: showsMicName)
                    }
                }
                // Tamanho natural sempre: quem cede espaço é o ViewThatFits do HUD, nunca o texto.
                .fixedSize()
                .padding(.horizontal, tight ? 10 : 14)
                .padding(.vertical, 8)
                .hudGlass(Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Ponto, REC ou STBY e timecode. Sem câmera não há como saber se grava: tudo vira "—".
    private func recording(known: Bool) -> some View {
        let recording = known && model.state.recording
        return HStack(spacing: tight ? 6 : 8) {
            Circle()
                .fill(recording ? Theme.rec : Color.secondary)
                .frame(width: 12, height: 12)
            Text(!known ? "—" : recording ? "REC" : "STBY")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(recording ? Theme.rec : .secondary)
            if known {
                TimelineView(.periodic(from: .now, by: 1 / max(model.state.frameRate, 1))) { context in
                    Text(model.state.timecode(at: context.date)).font(Theme.value(20))
                }
            } else {
                Text(verbatim: "—").font(Theme.value(20)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Espaço restante e sinal. Normal fica discreto; alerta ganha cor.
struct HealthChip: View {
    @Bindable var model: AppModel
    var tight = false
    /// Janela em pé e estreita: o sinal bom fica só no ícone, para o nome do mic caber.
    var compact = false

    var body: some View {
        HStack(spacing: tight ? 10 : 14) {
            copy
            remaining
            signal
        }
        .font(.system(size: 17, weight: .semibold).monospacedDigit())
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .padding(.horizontal, tight ? 10 : 14)
        .padding(.vertical, 8)
        .hudGlass(Capsule())
    }

    @ViewBuilder private var remaining: some View {
        if model.signal == .cameraGone {
            // O último valor lido envelheceu: não fingir que ainda vale.
            Label("—", systemImage: "internaldrive").foregroundStyle(.secondary)
        } else if let seconds = model.state.remainingRecordTime {
            let level = model.state.remainingLevel
            // Alerta com forma além da cor: o ícone vira triângulo.
            Label("\(seconds / 60) min", systemImage: level == .normal ? "internaldrive" : "exclamationmark.triangle.fill")
                .foregroundStyle(level == .critical ? Theme.rec : level == .warning ? Theme.warn : .primary)
                .help("Tempo de gravação restante no iPhone")
        }
    }

    /// A cópia no Mac só aparece gravando, ou quando a última falhou.
    @ViewBuilder private var copy: some View {
        if let failure = model.copyFailure {
            copyLabel("exclamationmark.triangle.fill").foregroundStyle(Theme.rec).help(failure)
        } else if model.savesCopy, model.state.recording, model.signal != .cameraGone {
            copyLabel("laptopcomputer.and.arrow.down")
                .help("Copiando o stream para o Mac, na resolução da câmera e a 8 Mb/s, mais leve que o original. O arquivo original fica no iPhone.")
        }
    }

    @ViewBuilder private func copyLabel(_ symbol: String) -> some View {
        if compact { Image(systemName: symbol) } else { Label("Mac", systemImage: symbol) }
    }

    @ViewBuilder private var signal: some View {
        switch model.signal {
        // Antena: é a transmissão do iPhone para o Mac, não o Wi‑Fi.
        case .ok:
            let fps = model.health?.fps ?? 0
            // Medindo: só o ícone com um indicador, para não parecer falta de sinal.
            if fps < 1 {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    ProgressView().controlSize(.mini)
                }
            } else if compact {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .help("\(Int(fps.rounded())) quadros por segundo chegando do iPhone")
            } else {
                Label("\(Int(fps.rounded())) fps", systemImage: "antenna.radiowaves.left.and.right")
                    .help("Quadros por segundo chegando do iPhone")
            }
        case .lossy:
            Label("Perdas", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(Theme.warn)
        case .waiting:
            Label("Aguardando", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .lost:
            Label("Caiu", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(Theme.rec)
        case .cameraGone:
            Label("Sem câmera", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(Theme.rec)
        }
    }
}

/// Barra de vidro: exposição à esquerda, gravar no meio, lente, áudio e janela à direita.
/// Em janela estreita ela compacta (letra e respiro menores, mesmos rótulos) antes de, em
/// último caso, virar duas linhas. Sem câmera, fica apagada: os valores são velhos.
struct ControlBar: View {
    @Bindable var model: AppModel

    private var state: CameraState { model.state }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
            // Janela em pé estreita (~470 a 520 pt): uma linha só, mais apertada, antes de virar
            // duas linhas que cobrem mais vídeo.
            bar(compact: true, tight: true)
            VStack(spacing: 8) {
                HStack(spacing: 2) { exposure(compact: true) }.padding(5).hudGlass(Capsule())
                HStack(spacing: 2) {
                    RecordButton(model: model)
                    copyButton(tight: true)
                    separator
                    cameraAndWindow(compact: true)
                }
                .padding(5)
                .hudGlass(Capsule())
            }
        }
        .disabled(model.signal == .cameraGone)
    }

    private func bar(compact: Bool, tight: Bool = false) -> some View {
        HStack(spacing: compact ? 0 : 4) {
            exposure(compact: compact, tight: tight)
            separator
            RecordButton(model: model)
            copyButton(tight: tight)
            separator
            cameraAndWindow(compact: compact, tight: tight)
        }
        .padding(compact ? 5 : 6)
        .hudGlass(Capsule())
    }

    /// Cópia no Mac colada no gravar: aceso, cada take vai também para o Mac. O clique direito
    /// escolhe a pasta e abre as cópias no Finder.
    private func copyButton(tight: Bool) -> some View {
        Button { model.savesCopy.toggle() } label: {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 15, weight: .medium)).frame(width: tight ? 28 : 34, height: tight ? 28 : 34)
        }
        .buttonStyle(HUDItemStyle(isOn: model.savesCopy))
        .help(
            model.savesCopy
                ? String(localized: "Cada take também vai para o Mac, em \(model.copyFolder.lastPathComponent). Clique com o botão direito para trocar a pasta.")
                : String(localized: "Salvar também no Mac uma cópia de cada take"))
        .accessibilityLabel(model.savesCopy ? String(localized: "Cópia no Mac ligada") : String(localized: "Cópia no Mac desligada"))
        .contextMenu {
            Button("Escolher pasta das cópias…") { model.chooseCopyFolder() }
            Button("Mostrar cópias no Finder") { model.showCopies() }
        }
    }

    private var separator: some View {
        Divider().frame(height: 26).padding(.horizontal, 2)
    }

    @ViewBuilder private func exposure(compact: Bool, tight: Bool = false) -> some View {
        ValueButton(model: model, panel: .iso) {
            ValueItem(
                label: state.autoExposure == "Off" ? "ISO" : "ISO · auto", value: state.iso.map(String.init) ?? "—",
                pending: model.pending.contains("/video/iso"), failed: model.failed.contains("/video/iso"),
                compact: compact, tight: tight)
        } content: {
            ISOPanel(model: model)
        }
        ValueButton(model: model, panel: .shutter) {
            ValueItem(
                label: "Shutter", value: state.shutter?.label ?? "—",
                pending: model.pending.contains("/video/shutter"), failed: model.failed.contains("/video/shutter"),
                compact: compact, tight: tight)
        } content: {
            ShutterPanel(model: model)
        }
        ValueButton(model: model, panel: .whiteBalance) {
            ValueItem(
                label: "WB", value: state.whiteBalance.map { "\($0) K" } ?? "—",
                pending: model.pending.contains("/video/whiteBalance"),
                failed: model.hasFailed("/video/whiteBalance", "/video/whiteBalance/doAuto"), compact: compact, tight: tight)
        } content: {
            WhiteBalancePanel(model: model)
        }
        ValueButton(model: model, panel: .tint) {
            ValueItem(
                label: "Tint", value: state.tint.map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "—",
                pending: model.pending.contains("/video/whiteBalanceTint"),
                failed: model.failed.contains("/video/whiteBalanceTint"), compact: compact, tight: tight)
        } content: {
            TintPanel(model: model)
        }
        ValueButton(model: model, panel: .focus) {
            ValueItem(
                label: String(localized: "Foco"), value: focusText, pending: model.pending.contains("/lens/focus"),
                failed: model.hasFailed("/lens/focus", "/lens/focus/autoFocus", "/lens/focus/doAutoFocus"),
                compact: compact, tight: tight)
        } content: {
            FocusPanel(model: model)
        }
    }

    @ViewBuilder private func cameraAndWindow(compact: Bool, tight: Bool = false) -> some View {
        ValueButton(model: model, panel: .lens) {
            ValueItem(
                label: compact
                    ? String(localized: "Lente")
                    : state.zoomFocalLength.map { String(localized: "Lente · \(Int($0.rounded())) mm") } ?? String(localized: "Lente"),
                value: model.activeLens?.shortName ?? state.lens ?? "—",
                pending: model.pending.contains("/lens/cameras/active"),
                failed: model.hasFailed("/lens/cameras/active", "/lens/zoom", "/lens/opticalImageStabilization"),
                compact: compact, tight: tight)
        } content: {
            LensPanel(model: model)
        }
        ValueButton(model: model, panel: .audio) {
            ValueItem(
                label: String(localized: "Áudio"), value: compact ? shortAudioName : audioName,
                pending: model.pending.contains("/audio/channel/0/input"),
                failed: model.failed.contains("/audio/channel/0/input"), tint: noAudio ? Theme.rec : nil,
                compact: compact, tight: tight)
                .help(compact ? String(localized: "Áudio: \(audioName)") : "")
        } content: {
            AudioPanel(model: model)
        }
        Button { model.muted.toggle() } label: {
            Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .medium)).frame(width: tight ? 28 : 34, height: tight ? 28 : 34)
        }
        .buttonStyle(HUDItemStyle(isOn: !model.muted))
        .help(
            model.muted
                ? String(localized: "Ligar o som da câmera no Mac (\(Shortcut.mute.glyph))")
                : String(localized: "Silenciar o som no Mac (\(Shortcut.mute.glyph))"))
        .accessibilityLabel(model.muted ? String(localized: "Som no Mac desligado") : String(localized: "Som no Mac ligado"))
        separator
        ValueButton(model: model, panel: .grid, isOn: model.grid != .off || model.safeZone != nil) {
            Image(systemName: "squareshape.split.3x3").font(.system(size: 15, weight: .medium)).frame(width: tight ? 28 : 34, height: tight ? 28 : 34)
                .accessibilityLabel("Grade")
        } content: {
            GridPanel(model: model)
        }
        .help("Grade")
        Button { model.rotate() } label: {
            Image(systemName: "rotate.right").font(.system(size: 15, weight: .medium)).frame(width: tight ? 28 : 34, height: tight ? 28 : 34)
        }
        .buttonStyle(HUDItemStyle())
        .help("Girar 90°: a janela fica em pé (\(Shortcut.rotate.glyph))")
        .accessibilityLabel("Girar")
    }

    private var focusText: String {
        if model.autoFocusEnabled { return "AF" }
        return state.focus.map { "\(Int(($0 * 100).rounded()))%" } ?? "MF"
    }

    private var noAudio: Bool { state.audioInputs[0] == "None" }

    /// Nome curto para janela estreita: "iPhone Microphone" vira "iPhone Mic".
    private var shortAudioName: String {
        audioName.replacingOccurrences(of: "Microphone", with: "Mic")
    }

    private var audioName: String {
        let inputs = Set(state.audioInputs.values.map { $0 == "None" ? String(localized: "Sem áudio") : $0 })
        return inputs.isEmpty ? "—" : inputs.sorted().joined(separator: " · ")
    }
}

/// Microfone ativo no iPhone e medidor L/R do som que chega. Sem áudio escolhido, ou som que
/// parou de chegar com o vídeo chegando, fica vermelho.
struct AudioStatus: View {
    @Bindable var model: AppModel
    var showsName = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let gone = model.signal == .cameraGone
            let none = model.state.audioInputs.values.contains("None")
            let missing = model.audioMissing
            let alarm = !gone && (none || missing)
            HStack(spacing: 6) {
                Image(systemName: alarm ? "mic.slash.fill" : "mic.fill").font(.system(size: 14, weight: .semibold))
                if showsName {
                    Text(none ? String(localized: "Sem áudio") : missing ? String(localized: "Sem som") : micName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 140, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                LiveAudioMeter(model: model)
            }
            .foregroundStyle(alarm ? Theme.rec : gone ? .secondary : .primary)
            .help(
                alarm
                    ? (none
                        ? String(localized: "O iPhone está gravando sem áudio")
                        : String(localized: "O som parou de chegar do iPhone"))
                    : String(localized: "Áudio: \(fullName)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Áudio")
            .accessibilityValue(none ? String(localized: "Sem áudio") : fullName)
        }
    }

    private var fullName: String {
        let names = Set(model.state.audioInputs.values.filter { $0 != "None" })
        return names.isEmpty ? "—" : names.sorted().joined(separator: " · ")
    }

    /// "iPhone Microphone" vira "iPhone Mic": a cápsula precisa ler de longe.
    private var micName: String { fullName.replacingOccurrences(of: "Microphone", with: "Mic") }

}

/// Medidor ao vivo, redesenhado a 30 Hz. Som parado há meio segundo apaga as barras.
struct LiveAudioMeter: View {
    @Bindable var model: AppModel
    var large = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            AudioMeterView(meter: model.signal == .cameraGone ? nil : current, large: large)
        }
    }

    private var current: AudioMonitor.Meter? {
        guard let meter = model.audioMeter(), meter.updatedAt > 0 else { return nil }
        let age = Double(DispatchTime.now().uptimeNanoseconds - meter.updatedAt) / 1e9
        return age > 0.5 ? nil : meter
    }
}

/// O medidor do Blackmagic Camera: uma barra por canal sobre o trilho com as zonas apagadas
/// (verde até -20 dBFS, amarelo até -9, vermelho até 0), a barra acesa na cor da zona e a
/// marca de pico à frente. O grande, no popover de áudio, traz a escala em dBFS.
struct AudioMeterView: View {
    let meter: AudioMonitor.Meter?
    var large = false

    private static let zones: [(from: Float, to: Float, color: Color)] = [
        (-60, AudioScale.yellowFrom, .green), (AudioScale.yellowFrom, AudioScale.redFrom, .yellow),
        (AudioScale.redFrom, 0, Theme.rec),
    ]
    /// Rótulos da escala. Sem -50: a 9 pt ele encosta no -40; a marca continua no trilho.
    private static let labels: [Float] = [-40, -30, -20, -15, -10, -5, 0]
    private static let ticks: [Float] = [-50, -40, -30, -20, -15, -10, -5, 0]

    var body: some View {
        Canvas { context, size in
            let channels = max(meter?.peaks.count ?? 0, 2)
            let labelWidth: CGFloat = large ? 14 : 0
            let scaleHeight: CGFloat = large ? 16 : 0
            let gap: CGFloat = large ? 4 : 2
            let width = size.width - labelWidth
            let height = (size.height - scaleHeight - gap * CGFloat(channels - 1)) / CGFloat(channels)
            func x(_ db: Float) -> CGFloat { labelWidth + width * CGFloat(AudioScale.position(db)) }

            for channel in 0..<channels {
                let y = CGFloat(channel) * (height + gap)
                if large {
                    context.draw(
                        Text(channel == 0 ? "L" : "R").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary),
                        at: CGPoint(x: labelWidth / 2 - 2, y: y + height / 2))
                }
                let level = meter.map { $0.peaks[channel] } ?? -120
                for zone in Self.zones {
                    let rect = CGRect(x: x(zone.from), y: y, width: x(zone.to) - x(zone.from), height: height)
                    context.fill(Path(rect), with: .color(zone.color.opacity(0.24)))
                    let lit = min(x(level), rect.maxX) - rect.minX
                    if lit > 0 {
                        context.fill(Path(CGRect(x: rect.minX, y: y, width: lit, height: height)), with: .color(zone.color))
                    }
                }
                if let hold = meter?.holds[channel], hold > -60 {
                    let color = Self.zones.first { hold < $0.to }?.color ?? Theme.rec
                    let mark = large ? 2.5 : 1.5
                    context.fill(
                        Path(CGRect(x: min(x(hold), size.width - mark), y: y, width: mark, height: height)),
                        with: .color(color))
                }
            }
            guard large else { return }
            let top = size.height - scaleHeight
            for db in Self.ticks {
                context.fill(Path(CGRect(x: x(db) - 0.5, y: top - gap + 1, width: 1, height: 3)), with: .color(.secondary))
            }
            for db in Self.labels {
                context.draw(
                    Text(db == 0 ? "0" : "\(Int(db))").font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: min(max(x(db), labelWidth + 8), size.width - 4), y: top + scaleHeight / 2 + 1))
            }
        }
        .frame(width: large ? nil : 96, height: large ? 46 : 14)
        .accessibilityHidden(true)
    }
}

/// Valor da barra que abre o seu controle num popover.
struct ValueButton<Label: View, Content: View>: View {
    @Bindable var model: AppModel
    let panel: AppModel.Panel
    /// Item ligado mesmo com o popover fechado (grade ativa).
    var isOn = false
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content

    var body: some View {
        Button { model.togglePanel(panel) } label: { label }
            .buttonStyle(HUDItemStyle(isOn: isOn || model.panel == panel))
            .popover(
                isPresented: Binding(
                    get: { model.panel == panel },
                    set: { if !$0, model.panel == panel { model.panel = nil } }),
                arrowEdge: .top
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    content
                    if let note = model.failureNote {
                        SwiftUI.Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.rec)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .frame(width: 340)
            }
    }
}

/// Botão de gravar: círculo vermelho, quadrado branco dentro enquanto grava.
struct RecordButton: View {
    @Bindable var model: AppModel

    var body: some View {
        let recording = model.state.recording
        Button(action: model.toggleRecord) {
            ZStack {
                // Grupo próprio: sem ele, a vibrancy do vidro clareia o vermelho para salmão.
                Circle().fill(model.failed.contains("/transports/0/record") ? Theme.rec.opacity(0.5) : Theme.rec)
                    .frame(width: 30, height: 30)
                    .compositingGroup()
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: 36, height: 36)
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 11, height: 11)
                }
                if model.pending.contains("/transports/0/record") {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(HUDItemStyle())
        .help(
            recording
                ? String(localized: "Parar gravação (\(Shortcut.record.glyph))")
                : String(localized: "Gravar (\(Shortcut.record.glyph))"))
        .accessibilityLabel(recording ? String(localized: "Parar gravação") : String(localized: "Gravar"))
    }
}

// MARK: - Sobre o vídeo

/// Grade sobre o quadro, no tipo escolhido.
struct GridOverlay: View {
    let style: AppModel.GridStyle
    /// Miniatura do popover: traço e marcas maiores para ler em 36 pt.
    var thumbnail = false

    var body: some View {
        Canvas { context, size in
            var path = Path()
            func vertical(_ f: CGFloat) {
                path.move(to: CGPoint(x: size.width * f, y: 0))
                path.addLine(to: CGPoint(x: size.width * f, y: size.height))
            }
            func horizontal(_ f: CGFloat) {
                path.move(to: CGPoint(x: 0, y: size.height * f))
                path.addLine(to: CGPoint(x: size.width, y: size.height * f))
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let arm = min(size.width, size.height) * (thumbnail ? 0.3 : 0.04)
            func cross() {
                path.move(to: CGPoint(x: center.x - arm, y: center.y))
                path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - arm))
                path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            }
            switch style {
            case .off: break
            case .thirds:
                [CGFloat(1) / 3, CGFloat(2) / 3].forEach { vertical($0); horizontal($0) }
            case .thirdsCenter:
                [CGFloat(1) / 3, CGFloat(2) / 3].forEach { vertical($0); horizontal($0) }
                cross()
            case .phi:
                // 1 : 0,618 : 1 — linhas em 0,382 e 0,618.
                [CGFloat(0.382), 0.618].forEach { vertical($0); horizontal($0) }
            case .cross:
                cross()
            case .dot:
                let r: CGFloat = thumbnail ? 2.5 : 3
                path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            case .eyeLine:
                // Talking head: olhos no terço de cima, rosto no eixo do meio.
                horizontal(CGFloat(1) / 3)
                vertical(0.5)
            }
            context.stroke(path, with: .color(.black.opacity(0.3)), lineWidth: 2)
            context.stroke(path, with: .color(.white.opacity(thumbnail ? 0.9 : 0.55)), lineWidth: thumbnail ? 1 : 0.75)
        }
        .allowsHitTesting(false)
    }
}

/// Área segura de uma rede: escurece o que a interface dela cobre e, com o vídeo deitado, o que
/// fica fora do recorte vertical do meio. O contorno marca onde o texto e o rosto ficam visíveis.
struct SafeZoneOverlay: View {
    let zone: SafeZone
    /// Miniatura do popover: contorno mais forte para ler em 36 pt.
    var thumbnail = false

    var body: some View {
        Canvas { context, size in
            let frame = SafeZone.verticalFrame(in: size)
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(frame)
            context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            var covered = Path()
            zone.covered(in: frame).forEach { covered.addRect($0) }
            context.fill(covered, with: .color(.black.opacity(0.35)))
            let visible = Path(frame).subtracting(covered)
            context.stroke(visible, with: .color(.black.opacity(0.3)), lineWidth: 2)
            context.stroke(visible, with: .color(.white.opacity(thumbnail ? 0.9 : 0.55)), lineWidth: thumbnail ? 1 : 0.75)
        }
        .allowsHitTesting(false)
    }
}

/// Mira de foco no ponto clicado: quatro cantos que somem depois de um segundo.
struct FocusReticle: View {
    let mark: CGPoint
    let at: Date

    @State private var visible = true

    var body: some View {
        let arm: CGFloat = 12
        Canvas { context, size in
            var path = Path()
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            for (corner, dx, dy) in [
                (CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0),
            ] {
                path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            }
            context.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: 3)
            context.stroke(path, with: .color(.yellow), lineWidth: 1.5)
        }
        .frame(width: 56, height: 56)
        .position(mark)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .task(id: at) {
            visible = true
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeOut(duration: 0.4)) { visible = false }
        }
    }
}

// MARK: - Estados sem vídeo

/// Cartão central quando não há vídeo para proteger.
struct MessageCard: View {
    let title: String
    let detail: String?
    var spinning = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if spinning { ProgressView().controlSize(.small) }
                Text(title).font(.title3.weight(.semibold))
            }
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .hudGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(32)
    }
}

struct SearchingCard: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.cameras.count > 1 ? String(localized: "Escolha a câmera") : String(localized: "Procurando o iPhone"))
                    .font(.title3.weight(.semibold))
            }
            if model.cameras.count > 1 {
                ForEach(model.cameras) { camera in
                    Button(camera.host) { model.connect(camera) }.buttonStyle(.bordered)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SwiftUI.Label("Blackmagic Camera aberto na tela de câmera", systemImage: "camera")
                    SwiftUI.Label("Remote Camera Control ligado em modo Remote Camera", systemImage: "dot.radiowaves.left.and.right")
                    SwiftUI.Label("Servidor HTTP ligado em Network Access", systemImage: "network")
                    SwiftUI.Label("Mac e iPhone na mesma rede Wi‑Fi", systemImage: "wifi")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .hudGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(32)
    }
}
