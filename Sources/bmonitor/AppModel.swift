import AVFoundation
import AppKit
import MonitorCore
import Network
import Observation
import SwiftUI

/// Liga descoberta, eventos, API e stream à interface. Tudo aqui roda na main thread.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case searching
        case connecting(String)
        case connected
    }

    enum Signal { case waiting, ok, lossy, lost, cameraGone }

    enum Panel: String { case iso, shutter, frameRate, whiteBalance, tint, focus, format, lens, audio, grid }

    enum GridStyle: String, CaseIterable, Identifiable {
        case off, thirds, thirdsCenter, phi, cross, dot, eyeLine

        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: String(localized: "Sem grade")
            case .thirds: String(localized: "Terços")
            case .thirdsCenter: String(localized: "Terços e centro")
            case .phi: String(localized: "Proporção áurea")
            case .cross: String(localized: "Cruz central")
            case .dot: String(localized: "Ponto central")
            case .eyeLine: String(localized: "Linha dos olhos")
            }
        }
    }

    var phase: Phase = .searching
    var cameras: [Discovery.Camera] = []
    /// Diagnóstico da tela de primeira abertura: o que o Mac consegue confirmar do lado dele.
    /// "Câmera A · iPhone 17 Pro Max": o nome da câmera nos ajustes do Blackmagic Camera e o
    /// modelo, que é o que a API publica.
    var cameraTitle: String? {
        let model = state.productName
        guard let name = state.deviceName, !name.isEmpty else { return model }
        let camera = String(localized: "Câmera \(name)")
        return model.map { "\(camera) · \($0)" } ?? camera
    }

    /// Entrada que recusou uma escrita de ganho.
    var gainRefusedInput: String?
    var localNetworkDenied = false
    var onNetwork = true
    /// Nunca conectou a um iPhone: a busca mostra o guia inteiro desde o primeiro instante.
    var neverConnected: Bool { Self.simulatesFirstRun || UserDefaults.standard.string(forKey: Self.lastHostKey) == nil }
    let state = CameraState()
    var eventsConnected = false
    var health: StreamSession.Health?
    var controlsVisible = true
    var panel: Panel?
    var showsShortcuts = false
    /// Propriedades com pedido enviado e ainda não confirmado pela câmera.
    var pending: Set<String> = []
    /// Por que o stream não abriu, quando não abriu.
    var streamError: String?
    /// Propriedades cujo último pedido a câmera recusou ou não confirmou.
    var failed: Set<String> = []
    /// O que falhou e o que fazer, mostrado no popover aberto.
    var failureNote: String?
    var autoFocusEnabled = true
    var autoFocusMode = "Continuous"
    /// Ponto do último clique de foco, em coordenadas da janela, para a mira.
    var focusMark: (point: CGPoint, at: Date)?
    var grid: GridStyle {
        didSet {
            UserDefaults.standard.set(grid.rawValue, forKey: "grid")
            if grid != .off { UserDefaults.standard.set(grid.rawValue, forKey: "lastGrid") }
        }
    }
    /// Área segura de uma rede sobre o quadro vertical; nil esconde.
    var safeZone: SafeZone? {
        didSet {
            UserDefaults.standard.set(safeZone?.rawValue, forKey: "safeZone")
            if let safeZone { UserDefaults.standard.set(safeZone.rawValue, forKey: "lastSafeZone") }
        }
    }
    var quarterTurns: Int { didSet { UserDefaults.standard.set(quarterTurns, forKey: "quarterTurns") } }
    /// Cópia de cada take no Mac, a partir do stream. Desligada por padrão.
    var savesCopy: Bool {
        didSet {
            UserDefaults.standard.set(savesCopy, forKey: "savesCopy")
            if savesCopy, state.recording { beginCopy() }
            if !savesCopy { session?.recorder.end() }
        }
    }
    var copyFolder: URL { didSet { UserDefaults.standard.set(copyFolder.path, forKey: "copyFolder") } }
    /// O último arquivo de cópia que falhou e por quê; some quando um take salva.
    var copyFailure: String?
    /// Som da câmera no Mac. Começa mudo na primeira abertura (microfonia com a câmera na
    /// mesma sala); depois vale o último estado.
    var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: "muted")
            session?.audio.isMuted = muted
        }
    }

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    /// O roteiro da janela ao lado; ouve a fala no áudio da câmera.
    let script = ScriptModel()
    /// A janela própria do roteiro, quando ele está destacado da janela da câmera.
    @ObservationIgnored private var scriptWindow: ScriptWindow?
    @ObservationIgnored private let discovery = Discovery()
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var api: CameraAPI?
    @ObservationIgnored private var events: CameraEvents?
    @ObservationIgnored private var session: StreamSession?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var timeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var queued: [String: [String: Any]] = [:]
    @ObservationIgnored private var restarting = false
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var activatedAt = Date.distantPast
    @ObservationIgnored private var healthTicks = 0

    init() {
        Self.migrateDefaults()
        grid =
            UserDefaults.standard.string(forKey: "grid").flatMap(GridStyle.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: "showGrid") ? .thirds : .off)
        safeZone = UserDefaults.standard.string(forKey: "safeZone").flatMap(SafeZone.init(rawValue:))
        quarterTurns = UserDefaults.standard.integer(forKey: "quarterTurns")
        muted = UserDefaults.standard.object(forKey: "muted") as? Bool ?? true
        savesCopy = UserDefaults.standard.bool(forKey: "savesCopy")
        copyFolder =
            UserDefaults.standard.string(forKey: "copyFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("bmonitor")
        discovery.onChange = { [weak self] cameras in
            DispatchQueue.main.async { self?.camerasChanged(cameras) }
        }
        discovery.onDenied = { [weak self] denied in
            DispatchQueue.main.async { self?.localNetworkDenied = denied }
        }
        network.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async { self?.onNetwork = online && !CommandLine.arguments.contains("--simulate-offline") }
        }
        network.start(queue: .main)
        localNetworkDenied = CommandLine.arguments.contains("--simulate-denied")
        // Desenvolvimento: `--skip-bonjour` testa o plano B do último iPhone.
        if !CommandLine.arguments.contains("--skip-bonjour"), !Self.simulatesFirstRun { discovery.start() }
        if !Self.simulatesFirstRun { tryLastCamera() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activatedAt = Date() }
        }
        pokeControls()
        // Desenvolvimento: abre a tela de atalhos sem câmera, para capturas de revisão.
        if CommandLine.arguments.contains("--show-shortcuts") { showsShortcuts = true }
    }

    var signal: Signal {
        guard eventsConnected, !Self.simulatesCameraGone else { return .cameraGone }
        guard let since = health?.secondsSinceFrame else { return .waiting }
        if since > 1.5 || Self.simulatesLost { return .lost }
        if (health?.lostPackets ?? 0) > 0 || Self.simulatesLoss { return .lossy }
        return .ok
    }

    /// Medidor do som que chega no stream; nil antes de conectar.
    func audioMeter() -> AudioMonitor.Meter? { session?.audio.meter() }

    /// O som do stream parou de chegar enquanto o vídeo chega: algo errado no áudio.
    var audioMissing: Bool {
        guard signal == .ok || signal == .lossy, let meter = audioMeter() else { return false }
        return meter.updatedAt == 0 || Double(DispatchTime.now().uptimeNanoseconds - meter.updatedAt) / 1e9 > 1
    }

    /// Desenvolvimento: `--simulate-camera-gone` mostra a tela sem câmera com a câmera ligada,
    /// para capturas de revisão.
    private static let simulatesCameraGone = CommandLine.arguments.contains("--simulate-camera-gone")
    /// Desenvolvimento: `--simulate-loss` mostra o sinal com perdas.
    private static let simulatesLoss = CommandLine.arguments.contains("--simulate-loss")
    /// Desenvolvimento: `--simulate-lost` mostra o vídeo parado; `--simulate-recording` mostra o
    /// estado gravando sem gravar no iPhone.
    private static let simulatesLost = CommandLine.arguments.contains("--simulate-lost")
    private static let simulatesRecording = CommandLine.arguments.contains("--simulate-recording")
    /// Desenvolvimento: `--simulate-first-run` mostra o guia da busca sem procurar o iPhone;
    /// com `--simulate-denied` ou `--simulate-offline`, os diagnósticos de Rede Local e de rede.
    private static let simulatesFirstRun = CommandLine.arguments.contains("--simulate-first-run")
    /// Desenvolvimento: `--simulate-remaining <segundos>` substitui o tempo restante do iPhone.
    private static let simulatedRemaining: Int? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate-remaining"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }()

    /// O quadro na tela é o último que chegou, não o de agora.
    var videoFrozen: Bool { signal == .lost || signal == .cameraGone }

    /// Proporção do vídeo na tela, já girado.
    var displayAspect: CGSize {
        let size = state.videoSize
        return quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    func connect(_ camera: Discovery.Camera) {
        phase = .connecting(camera.host)
        gainRefusedInput = nil
        let api = CameraAPI(host: camera.host)
        let events = CameraEvents(host: camera.host, properties: CameraState.properties)
        events.onChange = { [weak self] property, value in
            DispatchQueue.main.async { self?.apply(property, value) }
        }
        events.onConnection = { [weak self] connected in
            DispatchQueue.main.async { self?.eventsConnectionChanged(connected) }
        }
        let session = StreamSession(api: api)
        let layer = displayLayer
        session.onFrame = { VideoEnqueue.enqueue($0, into: layer) }
        session.audio.isMuted = muted
        session.recorder.onFinish = { [weak self] url, error in self?.copyFinished(url, error) }
        session.onAudioBuffer = { [speech = script.speech] in speech.append($0) }
        self.api = api
        self.events = events
        self.session = session
        events.start()
        Task { [weak self] in
            do {
                try await session.start()
                self?.streamError = nil
            } catch {
                self?.streamError = "\(error)"
            }
        }
        refreshAutoFocus()
    }

    // MARK: - Controles da câmera

    func toggleRecord() {
        guard eventsConnected, !pending.contains("/transports/0/record") else { return }
        set("/transports/0/record", ["recording": !state.recording])
    }

    /// PUT numa propriedade. Com `awaitsEvent`, a palheta fica pendente até o evento da
    /// câmera confirmar; recusa ou 3 s sem confirmação viram falha visível. Gatilhos e
    /// sliders passam `awaitsEvent: false`, porque o valor pode não mudar.
    /// Pedidos seguidos na mesma propriedade (sliders) mandam só o mais recente.
    func set(
        _ path: String, _ body: [String: Any]?, confirms: String? = nil, awaitsEvent: Bool = true,
        refused: (() -> Void)? = nil
    ) {
        guard let api else { return }
        let key = confirms ?? path
        if awaitsEvent { markPending(key) }
        if inFlight.contains(path) {
            queued[path] = body ?? [:]
            return
        }
        inFlight.insert(path)
        Task { [weak self] in
            var failure: Error?
            do { try await api.put(path, body) } catch { failure = error }
            guard let self else { return }
            self.inFlight.remove(path)
            if let failure {
                if let refused, (failure as? CameraAPI.HTTPError)?.status == 400 { refused() } else {
                    self.markFailed(key, Self.describe(failure))
                }
            }
            if let next = self.queued.removeValue(forKey: path) {
                self.set(path, next.isEmpty ? nil : next, confirms: confirms, awaitsEvent: awaitsEvent, refused: refused)
            }
        }
    }

    func setISO(_ iso: Int) {
        guard iso != state.iso else { return }
        if state.autoExposure != "Off" { set("/video/autoExposure", ["mode": "Off"]) }
        set("/video/iso", ["iso": iso])
    }

    func setShutter(_ shutter: Shutter) {
        guard let api, shutter != state.shutter else { return }
        if state.autoExposure != "Off" { set("/video/autoExposure", ["mode": "Off"]) }
        guard state.shutterMeasurement != shutter.measurement else {
            set("/video/shutter", shutter.requestBody)
            return
        }
        // A unidade precisa mudar antes do valor: em sequência, não em paralelo.
        markPending("/video/shutter")
        Task { [weak self] in
            do {
                try await api.put("/video/shutter/measurement", ["measurement": shutter.measurement])
                try await api.put("/video/shutter", shutter.requestBody)
            } catch {
                self?.markFailed("/video/shutter", Self.describe(error))
            }
        }
    }

    func setWhiteBalance(_ kelvin: Int) {
        guard kelvin != state.whiteBalance else { return }
        set("/video/whiteBalance", ["whiteBalance": kelvin])
    }

    func setTint(_ tint: Int) {
        guard tint != state.tint else { return }
        set("/video/whiteBalanceTint", ["whiteBalanceTint": tint])
    }

    /// Preset de luz: WB e tint juntos, como no app da Blackmagic.
    func applyPreset(kelvin: Int, tint: Int) {
        setWhiteBalance(kelvin)
        setTint(tint)
    }

    func setLens(_ id: String) {
        guard id != state.activeLensID else { return }
        set("/lens/cameras/active", ["id": id])
    }

    /// O modo de foco não chega por evento: o seletor mostra o que um GET confirmar.
    func setAutoFocus(enabled: Bool, mode: String) {
        set(
            "/lens/focus/autoFocus", enabled ? ["enabled": true, "mode": mode] : ["enabled": false],
            awaitsEvent: false)
        refreshAutoFocus(after: 0.6)
    }

    func setFocus(_ value: Double) {
        if autoFocusEnabled {
            autoFocusEnabled = false
            setAutoFocus(enabled: false, mode: autoFocusMode)
        }
        // `normalised`: o `normalized` da doc dá 500 no iPhone.
        set("/lens/focus", ["normalised": value], awaitsEvent: false)
    }

    /// Primeiro clique numa janela inativa só a traz para frente: refocar a câmera no meio
    /// de uma tomada por causa disso seria um erro caro.
    var acceptsVideoClick: Bool { NSApp.isActive && Date().timeIntervalSince(activatedAt) > 0.4 }

    /// Foca no ponto clicado. `point` vem normalizado no quadro exibido e volta para o
    /// quadro da câmera desfazendo o giro.
    func focus(atDisplay point: CGPoint, windowPoint: CGPoint) {
        let (u, v) = (Double(point.x), Double(point.y))
        let camera: (Double, Double) =
            switch ((quarterTurns % 4) + 4) % 4 {
            case 1: (v, 1 - u)
            case 2: (1 - u, 1 - v)
            case 3: (1 - v, u)
            default: (u, v)
            }
        focusMark = (windowPoint, Date())
        set("/lens/focus/doAutoFocus", ["position": ["x": camera.0, "y": camera.1]], awaitsEvent: false)
    }

    func setAudioInput(_ input: String) {
        guard input != state.audioInputs[0] else { return }
        set("/audio/channel/0/input", ["input": input])
        set("/audio/channel/1/input", ["input": input])
    }

    /// Ganho da entrada, de 0 a 1. A câmera exige `gain` e `normalised` juntos (só um dá 500)
    /// e vale o `normalised`. Testado em 21/10/2026: o microfone sem fio aceita; o do iPhone
    /// recusa com 400. Uma recusa trava o controle naquela entrada, além da faixa publicada.
    func setAudioGain(_ value: Double) {
        let gain = min(max(value, 0), 1)
        let input = state.audioInputs[0]
        set("/audio/channel/0/level", ["gain": gain, "normalised": gain], awaitsEvent: false) { [weak self] in
            self?.gainRefusedInput = input
        }
    }

    func stepAudioGain(by delta: Double) {
        guard gainAdjustable, let gain = state.audioGain else { return }
        setAudioGain(((gain + delta) * 20).rounded() / 20)
    }

    /// O controle de ganho vale para a entrada atual: a faixa que ela publica não é um ponto
    /// só (o microfone do iPhone publica 1 a 1) e nenhuma escrita foi recusada nela.
    var gainAdjustable: Bool {
        guard state.audioGain != nil, let range = state.audioGainRange else { return false }
        return range.upperBound > range.lowerBound && gainRefusedInput != state.audioInputs[0]
    }

    /// Troca resolução, fps ou codec. A câmera exige o objeto inteiro do formato. Gravando, não
    /// troca: no meio de um take é quase sempre clique errado, e o custo é o take.
    func setFormat(resolution: String? = nil, frameRate: String? = nil, codec: String? = nil) {
        guard !state.recording, let current = state.recordFormat,
            let option = state.supportedFormats.first(where: { $0.resolution == (resolution ?? current.resolution) })
        else { return }
        let rate = frameRate ?? (option.frameRates.contains(current.frameRate) ? current.frameRate : option.frameRates.first)
        let wanted = codec ?? current.codec
        let chosen =
            option.codecs.contains(wanted)
            ? wanted : option.codecs.first { RecordFormat.family($0) == RecordFormat.family(wanted) } ?? option.codecs.first
        guard let rate, let chosen else { return }
        set("/system/format", current.body(option: option, frameRate: rate, codec: chosen))
    }

    func setDynamicRange(_ range: String) {
        guard !state.recording, range != state.dynamicRange else { return }
        set("/system/dynamicRange", ["dynamicRange": range])
    }

    func togglePanel(_ panel: Panel) {
        showsShortcuts = false
        self.panel = self.panel == panel ? nil : panel
        failureNote = nil
        if panel == .focus { refreshAutoFocus() }
        pokeControls()
    }

    /// Algum dos pedidos de um controle falhou (o valor e os gatilhos dele).
    func hasFailed(_ keys: String...) -> Bool { keys.contains(where: failed.contains) }

    // MARK: - Janela e controles locais

    func toggleShortcuts() {
        panel = nil
        withAnimation(.easeOut(duration: 0.2)) { showsShortcuts.toggle() }
    }

    /// G: liga e desliga a grade, voltando ao último tipo usado.
    func toggleGrid() {
        grid = grid != .off ? .off : UserDefaults.standard.string(forKey: "lastGrid").flatMap(GridStyle.init(rawValue:)) ?? .thirds
    }

    /// Z: liga e desliga a área segura, voltando à última rede usada.
    func toggleSafeZone() {
        safeZone = safeZone != nil ? nil : UserDefaults.standard.string(forKey: "lastSafeZone").flatMap(SafeZone.init(rawValue:)) ?? .meta
    }

    /// F: foco automático único no centro.
    func focusNow() {
        set("/lens/focus/doAutoFocus", nil, awaitsEvent: false)
    }

    /// Lente ativa pelo id: as frontais também reportam "0.5x", então o fator não basta.
    var activeLens: Lens? { state.lenses.first { $0.id == state.activeLensID } }

    func rotate() {
        quarterTurns = (quarterTurns + 1) % 4
        shapeWindow(animate: true)
    }

    var isLandscape: Bool { displayAspect.width >= displayAspect.height }

    /// Onde o roteiro fica agora: cada orientação do vídeo guarda a sua escolha.
    var scriptSide: ScriptModel.Side { isLandscape ? script.landscapeSide : script.portraitSide }

    /// O lugar do roteiro dentro da janela da câmera; nil fechado ou destacado.
    var attachedScriptSide: ScriptModel.Side? { script.isOpen && !script.detached ? scriptSide : nil }

    func shapeWindow(animate: Bool) {
        WindowShaper.fit(aspect: displayAspect, side: attachedScriptSide, animate: animate)
    }

    /// Abre ou fecha o roteiro: junto, a janela cresce ou encolhe para o lado dele; destacado,
    /// a janela própria aparece ou some.
    func toggleScript() {
        let old = attachedScriptSide
        script.isOpen.toggle()
        if !script.isOpen { script.editing = false }
        if script.detached {
            showScriptWindowIfNeeded()
        } else {
            WindowShaper.place(video: displayAspect, from: old, to: attachedScriptSide, animate: true)
        }
    }

    /// Ações que mexem no roteiro (colar, abrir, editar) mostram o painel antes.
    func openScript() {
        if !script.isOpen { toggleScript() }
    }

    func moveScript(to side: ScriptModel.Side) {
        guard side != scriptSide, ScriptModel.Side.choices(landscape: isLandscape).contains(side) else { return }
        let old = attachedScriptSide
        if isLandscape { script.landscapeSide = side } else { script.portraitSide = side }
        if attachedScriptSide != nil { WindowShaper.place(video: displayAspect, from: old, to: attachedScriptSide, animate: true) }
    }

    /// Destaca o roteiro numa janela própria, no lugar e no tamanho em que ele estava: parece
    /// que ele saiu da janela da câmera, que encolhe em volta do vídeo.
    func detachScript() {
        guard !script.detached else { return }
        let old = attachedScriptSide
        let frame = old.flatMap { WindowShaper.panelFrame(video: displayAspect, side: $0) }
        script.detached = true
        script.isOpen = true
        WindowShaper.place(video: displayAspect, from: old, to: nil, animate: true)
        scriptWindowController().show(frame: frame)
    }

    /// Junta o roteiro de volta à janela da câmera, no lugar escolhido para esta orientação.
    func attachScript() {
        guard script.detached else { return }
        script.detached = false
        scriptWindow?.hide()
        script.isOpen = true
        WindowShaper.place(video: displayAspect, from: nil, to: attachedScriptSide, animate: true)
    }

    /// Ao abrir o app destacado, ou ao mostrar e esconder com ⌘2.
    func showScriptWindowIfNeeded() {
        if script.detached, script.isOpen {
            scriptWindowController().show(frame: nil)
        } else {
            scriptWindow?.hide()
        }
    }

    private func scriptWindowController() -> ScriptWindow {
        if let scriptWindow { return scriptWindow }
        let window = ScriptWindow(app: self)
        // Fechar a janela pelo botão vermelho esconde o roteiro; ele continua destacado.
        window.onClose = { [weak self] in
            self?.script.isOpen = false
            self?.script.editing = false
        }
        scriptWindow = window
        return window
    }

    func pokeControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.panel == nil else { return }
            self.controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: - Cópia no Mac

    func chooseCopyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = copyFolder
        panel.prompt = String(localized: "Escolher")
        panel.message = String(localized: "Onde salvar a cópia de cada take")
        if panel.runModal() == .OK, let url = panel.url { copyFolder = url }
    }

    func showCopies() {
        try? FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(copyFolder)
    }

    /// Um arquivo por take, com o nome do clipe no iPhone: "A001_10210835_C009 bmonitor.mov".
    /// O evento que liga o REC já traz o nome do take novo (conferido em 21/10/2026). Sem
    /// nome, vale data e timecode, com ponto no lugar de ":", que o Finder não aceita.
    private func beginCopy() {
        guard let session else { return }
        let name: String
        if let clip = state.clipName, !clip.isEmpty {
            name = "\(clip) bmonitor"
        } else {
            let date = Date().formatted(.verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                timeZone: .current, calendar: .current))
            name = "bmonitor \(date) TC \(state.timecode().replacingOccurrences(of: ":", with: "."))"
        }
        // Nunca por cima de uma cópia que já existe: o gravador falharia e o take ficaria sem cópia.
        var url = copyFolder.appendingPathComponent("\(name).mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = copyFolder.appendingPathComponent("\(name) (\(n)).mov")
            n += 1
        }
        session.recorder.begin(url: url, quarterTurns: quarterTurns)
    }

    private func copyFinished(_ url: URL, _ error: Error?) {
        if let error {
            copyFailure = String(localized: "A cópia \(url.lastPathComponent) não foi salva: \(error.localizedDescription)")
        } else {
            copyFailure = nil
        }
    }

    /// Para o stream e devolve a plataforma original. Bloqueia; chamado no encerramento.
    func shutdown() {
        events?.stop()
        session?.stopBlocking()
    }

    // MARK: - Privado

    private func markPending(_ key: String) {
        pending.insert(key)
        failed.remove(key)
        timeouts[key]?.cancel()
        timeouts[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.markFailed(
                key,
                String(
                    localized: "A câmera não confirmou em 3 s. Confira se o Blackmagic Camera está aberto na tela de câmera."))
        }
    }

    /// A palheta fica vermelha por um instante e o popover aberto diz o que houve.
    private func markFailed(_ key: String, _ note: String) {
        timeouts.removeValue(forKey: key)?.cancel()
        pending.remove(key)
        failed.insert(key)
        failureNote = note
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.failed.remove(key)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let http = error as? CameraAPI.HTTPError {
            return http.status == 400 || http.status == 500
                ? String(localized: "A câmera recusou o valor (HTTP \(http.status)). Escolha outro.")
                : String(localized: "A câmera respondeu HTTP \(http.status). Tente de novo.")
        }
        return String(localized: "Sem resposta da câmera. Confira se o Blackmagic Camera está aberto e na mesma rede Wi‑Fi.")
    }

    private func refreshAutoFocus(after delay: Double = 0) {
        guard let api else { return }
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let value = try? await api.get("/lens/focus/autoFocus") else { return }
            self?.autoFocusEnabled = value["enabled"] as? Bool ?? true
            self?.autoFocusMode = value["mode"] as? String ?? "Continuous"
        }
    }

    private func camerasChanged(_ cameras: [Discovery.Camera]) {
        self.cameras = cameras
        if phase == .searching, cameras.count == 1 { connect(cameras[0]) }
    }

    private static let lastHostKey = "lastCameraHost"

    /// Domínios de preferências dos nomes anteriores do app (binário solto e primeiro .app).
    private static let previousDomains = ["BlackmagicMonitor", "com.dantearaujo.BlackmagicMonitor"]

    /// Na primeira abertura com um identificador novo, traz grade, rotação, mudo, último iPhone
    /// e, principalmente, a plataforma original do iPhone, que precisa voltar ao sair.
    private static func migrateDefaults() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let standard = UserDefaults.standard
        for domain in previousDomains where domain != id {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for key in ["grid", "lastGrid", "showGrid", "quarterTurns", "muted", lastHostKey, "originalLivestreamPlatform"]
            where standard.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { standard.set(value, forKey: key) }
            }
        }
    }

    /// Plano B do Bonjour: se em 4 s ninguém apareceu, tenta o último iPhone que conectou, e
    /// repete enquanto o app procura. Só conecta se a REST dele responder.
    private func tryLastCamera() {
        guard let host = UserDefaults.standard.string(forKey: Self.lastHostKey) else { return }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.phase == .searching else { return }
                guard self.cameras.isEmpty else { continue }
                if (try? await CameraAPI(host: host).get("/transports/0/record")) != nil, self.phase == .searching {
                    print("Bonjour sem resposta; conectando ao último iPhone, \(host)")
                    self.connect(Discovery.Camera(service: "último iPhone", host: host))
                    return
                }
            }
        }
    }

    private func eventsConnectionChanged(_ connected: Bool) {
        let returned = connected && !eventsConnected && phase == .connected
        eventsConnected = connected
        if returned, let session {
            // A câmera voltou (Blackmagic Camera de volta do segundo plano ou reaberto). O próprio
            // iPhone reabre o vídeo; pedir o stream na hora, com o app dele ainda subindo, o
            // derrubava (21/10/2026). Só pede se em 3 s o vídeo não voltou.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.eventsConnected, (self.session?.health().secondsSinceFrame ?? .infinity) > 3 else { return }
                do {
                    try await session.start()
                    self.streamError = nil
                } catch {
                    self.streamError = "\(error)"
                }
            }
        }
        if connected, case .connecting(let host) = phase {
            phase = .connected
            UserDefaults.standard.set(host, forKey: Self.lastHostKey)
            pokeControls()
            // Desenvolvimento: `--open-panel lens` abre um popover sozinho, para capturas de revisão.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open-panel"), i + 1 < args.count, let panel = Panel(rawValue: args[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.togglePanel(panel) }
            }
        }
    }

    private func apply(_ property: String, _ value: [String: Any]) {
        let previousSize = state.videoSize
        let wasRecording = state.recording
        state.apply(property: property, value: value)
        if savesCopy, state.recording != wasRecording, !Self.simulatesRecording {
            if state.recording { beginCopy() } else { session?.recorder.end() }
        }
        if let simulated = Self.simulatedRemaining { state.remainingRecordTime = simulated }
        if Self.simulatesRecording { state.recording = true }
        pending.remove(property)
        timeouts.removeValue(forKey: property)?.cancel()
        switch property {
        case "/lens/cameras/active":
            pending.remove("/lens/cameras")
        case "/livestreams/0" where state.streamStatus == "Interrupted":
            restartStream()
        case "/system/videoFormat" where state.videoSize != previousSize:
            shapeWindow(animate: false)
        default:
            break
        }
    }

    private func checkHealth() {
        health = session?.health()
        healthTicks += 1
        // A cada minuto, contagem do som no log: é como se confere "sem cortes por 10 min".
        if healthTicks % 120 == 0, let stats = session?.audio.statistics(), !muted {
            print("áudio: \(stats.buffers) buffers, \(stats.underruns) cortes, \(stats.drops) descartes")
        }
        // Sem eventos, o app do iPhone está fora (segundo plano ou fechado): pedidos ali ficam
        // presos e chegam todos juntos quando ele volta, e foi isso que o derrubou em 21/10.
        if eventsConnected, state.streamStatus == "Streaming", let since = health?.secondsSinceFrame, since > 4 {
            restartStream()
        }
    }

    private func restartStream() {
        guard let session, !restarting else { return }
        restarting = true
        Task { [weak self] in
            try? await session.restart()
            try? await Task.sleep(for: .seconds(3))
            self?.restarting = false
        }
    }
}

/// Dá à janela a proporção do vídeo: girar deixa o app inteiro em pé, e redimensionar
/// mantém a proporção. Com o roteiro aberto, a janela soma o roteiro: ao lado, metade do lado
/// maior do vídeo; acima ou abaixo, 40% da largura dele. A proporção continua fixa e o vídeo
/// não muda de tamanho nem de lugar ao abrir, fechar ou trocar o roteiro de lado.
enum WindowShaper {
    static let sideFraction: CGFloat = 0.5
    static let stackFraction: CGFloat = 0.4

    /// A janela do monitor: o SwiftUI dá a ela um identificador com o tipo da view. "A primeira
    /// janela" podia ser o "Sobre" ou a de atualização, que perdiam os botões e o tamanho.
    @MainActor static var monitorWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("MonitorView") == true }
    }

    /// Tamanho do roteiro na direção em que ele soma, nas unidades do vídeo.
    static func panelExtent(video: CGSize, side: ScriptModel.Side) -> CGFloat {
        side.isVertical ? video.width * stackFraction : max(video.width, video.height) * sideFraction
    }

    /// Proporção do conteúdo da janela: o vídeo e, se aberto, o roteiro.
    static func contentAspect(video: CGSize, side: ScriptModel.Side?) -> CGSize {
        guard let side else { return video }
        let extent = panelExtent(video: video, side: side)
        return side.isVertical
            ? CGSize(width: video.width, height: video.height + extent)
            : CGSize(width: video.width + extent, height: video.height)
    }

    /// Onde o vídeo começa dentro do conteúdo, com a origem embaixo à esquerda, como no AppKit.
    private static func videoOffset(video: CGSize, side: ScriptModel.Side?, scale: CGFloat) -> CGPoint {
        guard let side else { return .zero }
        let extent = panelExtent(video: video, side: side) * scale
        switch side {
        case .left: return CGPoint(x: extent, y: 0)
        case .bottom: return CGPoint(x: 0, y: extent)
        case .right, .top: return .zero
        }
    }

    /// Como a janela estava na última vez: dela sai o tamanho do vídeo a preservar.
    @MainActor private static var last: (video: CGSize, side: ScriptModel.Side?)?

    /// Gira ou ajusta ao formato da câmera: o lado maior do vídeo fica, e também o centro
    /// horizontal e a borda de cima da janela.
    @MainActor
    static func fit(aspect: CGSize, side: ScriptModel.Side?, animate: Bool) {
        guard aspect.width > 0, aspect.height > 0,
            let window = monitorWindow,
            !window.styleMask.contains(.fullScreen),
            let screen = window.screen ?? NSScreen.main
        else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        let long: CGFloat
        if let last {
            let before = contentAspect(video: last.video, side: last.side)
            long = max(last.video.width, last.video.height) * min(content.width / before.width, content.height / before.height)
        } else if side != nil {
            let now = contentAspect(video: aspect, side: side)
            long = max(aspect.width, aspect.height) * min(content.width / now.width, content.height / now.height)
        } else {
            long = max(content.width, content.height)
        }
        last = (aspect, side)
        let target = contentAspect(video: aspect, side: side)
        window.contentAspectRatio = target
        let scale = long / max(aspect.width, aspect.height)
        var size = CGSize(width: target.width * scale, height: target.height * scale)
        let room = window.contentRect(forFrameRect: screen.visibleFrame).size
        let shrink = min(1, room.width / size.width, room.height / size.height)
        size = CGSize(width: size.width * shrink, height: size.height * shrink)
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin.x = window.frame.midX - frame.width / 2
        frame.origin.y = window.frame.maxY - frame.height
        setFrame(frame, of: window, on: screen, animate: animate)
    }

    /// Onde o roteiro está na tela, dentro da janela da câmera: o lugar da janela própria quando
    /// ele é destacado.
    @MainActor
    static func panelFrame(video: CGSize, side: ScriptModel.Side) -> CGRect? {
        guard let window = monitorWindow else { return nil }
        let content = window.contentRect(forFrameRect: window.frame)
        let aspect = contentAspect(video: video, side: side)
        let extent = panelExtent(video: video, side: side) * min(content.width / aspect.width, content.height / aspect.height)
        let panel: CGRect
        switch side {
        case .right: panel = CGRect(x: content.maxX - extent, y: content.minY, width: extent, height: content.height)
        case .left: panel = CGRect(x: content.minX, y: content.minY, width: extent, height: content.height)
        case .top: panel = CGRect(x: content.minX, y: content.maxY - extent, width: content.width, height: extent)
        case .bottom: panel = CGRect(x: content.minX, y: content.minY, width: content.width, height: extent)
        }
        return window.frameRect(forContentRect: panel)
    }

    /// Abre, fecha ou muda o roteiro de lugar: o vídeo fica no mesmo ponto da tela e do mesmo
    /// tamanho, e a janela cresce ou encolhe em volta dele. Se a tela não comportar, tudo encolhe.
    @MainActor
    static func place(video: CGSize, from old: ScriptModel.Side?, to new: ScriptModel.Side?, animate: Bool) {
        guard video.width > 0, video.height > 0,
            let window = monitorWindow,
            !window.styleMask.contains(.fullScreen),
            let screen = window.screen ?? NSScreen.main
        else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let before = contentAspect(video: video, side: old)
        let scale = min(content.width / before.width, content.height / before.height)
        let after = contentAspect(video: video, side: new)
        let room = window.contentRect(forFrameRect: screen.visibleFrame).size
        let newScale = min(scale, room.width / after.width, room.height / after.height)
        let oldOffset = videoOffset(video: video, side: old, scale: scale)
        let newOffset = videoOffset(video: video, side: new, scale: newScale)
        let origin = CGPoint(x: content.minX + oldOffset.x - newOffset.x, y: content.minY + oldOffset.y - newOffset.y)
        last = (video, new)
        window.contentAspectRatio = after
        let frame = window.frameRect(
            forContentRect: CGRect(origin: origin, size: CGSize(width: after.width * newScale, height: after.height * newScale)))
        setFrame(frame, of: window, on: screen, animate: animate)
    }

    @MainActor
    private static func setFrame(_ frame: CGRect, of window: NSWindow, on screen: NSScreen, animate: Bool) {
        var frame = frame
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate)
    }

    /// Botões da janela somem junto com os controles, como no QuickTime.
    @MainActor
    static func setTitlebarVisible(_ visible: Bool) {
        guard let window = monitorWindow,
            let titlebar = window.standardWindowButton(.closeButton)?.superview
        else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            titlebar.animator().alphaValue = visible ? 1 : 0
        }
    }
}

extension SafeZone: Identifiable {
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .meta: String(localized: "Instagram e Facebook")
        case .tiktok: "TikTok"
        case .shorts: "YouTube Shorts"
        case .profileGrid: String(localized: "Grid do perfil (3:4)")
        case .square: String(localized: "Quadrado central (1:1)")
        }
    }
}
