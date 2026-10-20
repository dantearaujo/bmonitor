import AVFoundation
import AppKit
import MonitorCore
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

    enum Panel: String { case iso, shutter, whiteBalance, tint, focus, lens, audio, grid }

    enum GridStyle: String, CaseIterable, Identifiable {
        case off, thirds, thirdsCenter, phi, cross, dot

        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: String(localized: "Sem grade")
            case .thirds: String(localized: "Terços")
            case .thirdsCenter: String(localized: "Terços e centro")
            case .phi: String(localized: "Proporção áurea")
            case .cross: String(localized: "Cruz central")
            case .dot: String(localized: "Ponto central")
            }
        }
    }

    var phase: Phase = .searching
    var cameras: [Discovery.Camera] = []
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
    var quarterTurns: Int { didSet { UserDefaults.standard.set(quarterTurns, forKey: "quarterTurns") } }
    /// Som da câmera no Mac. Começa mudo na primeira abertura (microfonia com a câmera na
    /// mesma sala); depois vale o último estado.
    var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: "muted")
            session?.audio.isMuted = muted
        }
    }

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private let discovery = Discovery()
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
        quarterTurns = UserDefaults.standard.integer(forKey: "quarterTurns")
        muted = UserDefaults.standard.object(forKey: "muted") as? Bool ?? true
        discovery.onChange = { [weak self] cameras in
            DispatchQueue.main.async { self?.camerasChanged(cameras) }
        }
        // Desenvolvimento: `--skip-bonjour` testa o plano B do último iPhone.
        if !CommandLine.arguments.contains("--skip-bonjour") { discovery.start() }
        tryLastCamera()
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
    func set(_ path: String, _ body: [String: Any]?, confirms: String? = nil, awaitsEvent: Bool = true) {
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
            if let failure { self.markFailed(key, Self.describe(failure)) }
            if let next = self.queued.removeValue(forKey: path) {
                self.set(path, next.isEmpty ? nil : next, confirms: confirms, awaitsEvent: awaitsEvent)
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

    /// F: foco automático único no centro.
    func focusNow() {
        set("/lens/focus/doAutoFocus", nil, awaitsEvent: false)
    }

    /// Lente ativa pelo id: as frontais também reportam "0.5x", então o fator não basta.
    var activeLens: Lens? { state.lenses.first { $0.id == state.activeLensID } }

    func rotate() {
        quarterTurns = (quarterTurns + 1) % 4
        WindowShaper.fit(aspect: displayAspect, animate: true)
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
            // A câmera voltou (app reaberto no iPhone) com o stream parado: pede de novo.
            Task { [weak self] in
                do {
                    try await session.start()
                    self?.streamError = nil
                } catch {
                    self?.streamError = "\(error)"
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
        state.apply(property: property, value: value)
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
            WindowShaper.fit(aspect: displayAspect, animate: false)
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
        if state.streamStatus == "Streaming", let since = health?.secondsSinceFrame, since > 4 {
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
/// mantém a proporção. Preserva o lado maior e a borda de cima, e cabe na tela.
enum WindowShaper {
    @MainActor
    static func fit(aspect: CGSize, animate: Bool) {
        guard aspect.width > 0, aspect.height > 0,
            let window = NSApp.windows.first(where: { $0.canBecomeMain }),
            let screen = window.screen ?? NSScreen.main
        else { return }
        window.contentAspectRatio = aspect
        let content = window.contentRect(forFrameRect: window.frame).size
        let long = max(content.width, content.height)
        var size =
            aspect.width >= aspect.height
            ? CGSize(width: long, height: long * aspect.height / aspect.width)
            : CGSize(width: long * aspect.width / aspect.height, height: long)
        let room = window.contentRect(forFrameRect: screen.visibleFrame).size
        let shrink = min(1, room.width / size.width, room.height / size.height)
        size = CGSize(width: size.width * shrink, height: size.height * shrink)
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate)
    }

    /// Botões da janela somem junto com os controles, como no QuickTime.
    @MainActor
    static func setTitlebarVisible(_ visible: Bool) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
            let titlebar = window.standardWindowButton(.closeButton)?.superview
        else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            titlebar.animator().alphaValue = visible ? 1 : 0
        }
    }
}
