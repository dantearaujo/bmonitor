import CoreVideo
import Darwin
import Foundation

/// Ciclo de vida do livestream: aponta a câmera para o Mac, recebe, decodifica e entrega
/// cada quadro. Ao sair, para o stream e devolve a plataforma que a câmera tinha.
public final class StreamSession {
    public struct Health {
        /// Segundos desde o último quadro decodificado; nil se nenhum chegou ainda.
        public var secondsSinceFrame: Double?
        public var lostPackets: Int32
        public var fps: Double
    }

    /// Chamado na thread de recepção, sem fila: quem exibe deve enfileirar direto na camada.
    public var onFrame: ((CVPixelBuffer) -> Void)?
    /// Medidor e escuta do som que vem no mesmo stream.
    public let audio = AudioMonitor()
    /// Cópia do stream no Mac. Recebe tudo depois da tela e do som; só grava quando pedem.
    public let recorder = TakeRecorder()

    private let api: CameraAPI
    private let listener: SRTListener
    private let demuxer = TSDemuxer()
    private let decoder = HEVCDecoder()
    private let audioDecoder = AudioDecoder()
    private var receiver: Thread?
    private var originalPlatform: [String: Any]?

    private let lock = NSLock()
    private var lastFrameAt: UInt64 = 0
    private var framesInWindow = 0
    private var windowStart: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var fps: Double = 0
    private var lostBaseline: Int32 = 0

    public init(api: CameraAPI, port: UInt16 = 9000, latencyMs: Int32 = 40) {
        self.api = api
        self.listener = SRTListener(port: port, latencyMs: latencyMs)
        decoder.onFrame = { [weak self] image in
            self?.countFrame()
            self?.onFrame?(image)
        }
        decoder.onSample = { [recorder] in recorder.appendVideo($0, keyframe: $1) }
        demuxer.onVideo = { [weak self] in self?.decoder.decode($0) }
        demuxer.onAudio = { [weak self] in
            self?.audioDecoder.decode($0)
            self?.recorder.appendAudio($0)
        }
        audioDecoder.onBuffer = { [audio] in audio.play($0) }
        listener.onPayload = { [weak self] in self?.demuxer.feed($0) }
    }

    /// Começa a escutar e pede o stream à câmera.
    public func start() async throws {
        if receiver == nil {
            try listener.listen()
            let thread = Thread { [listener] in listener.run() }
            thread.qualityOfService = .userInteractive
            thread.start()
            receiver = thread
        }
        guard let macIP = Self.localAddress(toward: api.host) else { throw URLError(.cannotFindHost) }
        if originalPlatform == nil {
            // A original fica em disco: se o app cair ou abrir duas vezes, a próxima
            // instância encontra a Mac Monitor ativa e ainda sabe para onde voltar.
            let current = try await api.activePlatform()
            if current["platform"] as? String != Self.platform {
                originalPlatform = current
                UserDefaults.standard.set(try? JSONSerialization.data(withJSONObject: current), forKey: Self.originalKey)
            } else if let data = UserDefaults.standard.data(forKey: Self.originalKey),
                let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                originalPlatform = saved
            }
        }
        try await ensurePlatform(url: "srt://\(macIP):\(listener.port)", macIP: macIP)
        try await api.setActivePlatform(["platform": Self.platform, "server": "Mac", "quality": "Monitor"])
        try await restart()
    }

    /// Grava a plataforma Mac Monitor só quando falta ou quando o endereço mudou. Reenviar
    /// a mesma plataforma faz o Blackmagic Camera mostrar "Platforms Import Failed".
    private func ensurePlatform(url: String, macIP: String) async throws {
        let existing = try? await api.get("/livestreams/platforms/\(Self.platform)")
        let servers = existing?["servers"] as? [[String: Any]] ?? []
        if servers.contains(where: { $0["url"] as? String == url }) {
            print("plataforma Mac Monitor já aponta para \(url); nada enviado")
            return
        }
        print("plataforma Mac Monitor enviada para \(url)")
        if existing != nil { try? await api.delete("/livestreams/customPlatforms/\(Self.platform)") }
        try await api.putCustomPlatform(file: "MacMonitor.xml", xml: monitorPlatformXML(macIP: macIP, port: listener.port))
    }

    /// Para e começa de novo: é o que tira a câmera de `Interrupted`.
    public func restart() async throws {
        try? await api.stopStream()
        try await Task.sleep(for: .milliseconds(800))
        try await api.startStream()
    }

    /// Para o stream e devolve a plataforma original.
    public func stop() async {
        audio.stop()
        try? await api.stopStream()
        if let originalPlatform { try? await api.setActivePlatform(originalPlatform) }
    }

    /// Versão bloqueante de `stop()` para o encerramento do app.
    public func stopBlocking(timeout: TimeInterval = 4) {
        recorder.endBlocking()
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    public func health() -> Health {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let since = lastFrameAt == 0 ? nil : Double(now - lastFrameAt) / 1e9
        let lost = listener.stats()?.lostPackets ?? 0
        defer { lostBaseline = lost }
        return Health(secondsSinceFrame: since, lostPackets: max(lost - lostBaseline, 0), fps: fps)
    }

    private func countFrame() {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        lastFrameAt = now
        framesInWindow += 1
        let elapsed = Double(now - windowStart) / 1e9
        if elapsed >= 1 {
            fps = Double(framesInWindow) / elapsed
            framesInWindow = 0
            windowStart = now
        }
    }

    static let platform = "Mac Monitor SRT"
    static let originalKey = "originalLivestreamPlatform"

    /// IP local da interface que chega até a câmera (o iPhone precisa dele na URL do SRT).
    static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(4444).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }
}
