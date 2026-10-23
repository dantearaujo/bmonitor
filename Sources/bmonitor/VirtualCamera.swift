import AppKit
import CoreImage
import CoreMediaIO
import Foundation
import Metal
import Observation
import SystemExtensions
import os

/// O que a interface mostra da webcam: o guia da primeira vez e a cápsula de saúde.
@MainActor @Observable
final class WebcamStatus {
    static let shared = WebcamStatus()

    enum Approval: Equatable { case unknown, waiting, approved, failed(String) }
    var approval: Approval = .unknown
    /// Algum app (Meet, Zoom, FaceTime) está lendo a câmera agora.
    var inUse = false
    /// A câmera foi ativada, mas este processo não a enxerga: só reabrindo o app.
    var needsRelaunch = false
}

/// A webcam virtual. A extensão de câmera vem dentro do app nas builds com Developer ID
/// (`Webcam/`); ligada, o app pede ao macOS para ativá-la e entrega cada quadro decodificado ao
/// stream de entrada dela, girado como na janela e em 1920 × 1080 com barras. Os apps de chamada
/// leem a câmera "bmonitor". Sem quadros, a extensão mostra "Câmera em espera".
final class VirtualCamera: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    static let shared = VirtualCamera()
    /// O mesmo da extensão (`Webcam/Extension/Camera.swift`).
    private static let deviceUID = "6B6D6F6E-6974-6F72-0000-000000000001"
    private static let size = (width: 1920, height: 1080)
    private let log = Logger(subsystem: "com.dantearaujo.bmonitor", category: "webcam")
    private let queue = DispatchQueue(label: "bmonitor.webcam", qos: .userInteractive)
    /// Desenvolvimento: `--simulate-webcam-waiting` mostra o guia esperando a aprovação mesmo com a
    /// extensão já aprovada.
    private static let simulatesWaiting = CommandLine.arguments.contains("--simulate-webcam-waiting")

    // Tudo abaixo só na `queue`.
    private var enabled = false
    private var quarterTurns = 0
    private var sinkQueue: CMSimpleQueue?
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var lastAttempt = Date.distantPast
    private var outputPool: CVPixelBufferPool?
    /// Sem gestão de cor: converte YCbCr em RGB pela matriz do quadro, como o VideoToolbox fazia
    /// (medido em 22/10: diferença de no máximo 1 em 255, em Rec.709 e em HLG).
    private lazy var renderer: CIContext? = MTLCreateSystemDefaultDevice().map {
        CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }
    private var watchingDevices = false
    /// O macOS confirmou a extensão (aprovada, ou trocada depois de uma atualização) e já passou a
    /// folga para ela publicar a câmera. Antes disso o app não consulta a lista de câmeras.
    private var activated: Date?
    private var reportedMissing = false
    /// Desenvolvimento: `--webcam-test-pattern` manda quadros cinza à webcam, sem iPhone.
    private static let testPattern = CommandLine.arguments.contains("--webcam-test-pattern")
    private var patternTimer: DispatchSourceTimer?

    // Na main.
    private var lastHeard = Date.distantPast
    private var inUseTimer: Timer?

    /// Só há webcam quando o build trouxe a extensão.
    let isAvailable: Bool = {
        let folder = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty == false) ?? false
    }()

    private var extensionID: String? { Bundle.main.bundleIdentifier.map { $0 + ".camera" } }
    /// O mesmo nome que a extensão escuta (`Webcam/Extension/Camera.swift`).
    private lazy var frameNotification: CFString? = extensionID.map { ($0 + ".frame") as CFString }

    // MARK: - Ligar e desligar

    /// Ligada, pede a ativação (que também troca a extensão antiga depois de uma atualização) e
    /// passa a entregar quadros; desligada, solta a câmera, que volta a "Câmera em espera".
    @MainActor
    func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        queue.async {
            self.enabled = on
            if on { self.startTestPattern() } else { self.disconnect() }
        }
        if on {
            activate()
            listenForUse()
        } else {
            WebcamStatus.shared.inUse = false
        }
    }

    func setQuarterTurns(_ turns: Int) {
        queue.async { self.quarterTurns = ((turns % 4) + 4) % 4 }
    }

    /// Desenvolvimento e suporte: `--remove-webcam` pede ao macOS para desinstalar a extensão,
    /// para testar a primeira aprovação de novo.
    @MainActor
    func removeIfRequested() {
        guard CommandLine.arguments.contains("--remove-webcam"), let extensionID else { return }
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("pedido de remoção enviado")
    }

    @MainActor
    private func activate() {
        guard let extensionID else { return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Abre os Ajustes na linha "Extensões de Câmera". O macOS não abre o ⓘ dela por endereço, mas
    /// rola até a categoria. Com os Ajustes fechados, a primeira chamada só abre o painel, a
    /// segunda chega à seção Extensões e a terceira, com a lista carregada, traz a linha à vista
    /// (medido no macOS 26 com uma lista longa de itens de início).
    @MainActor
    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.cmio")
        else { return }
        NSWorkspace.shared.open(url)
        for delay in [1.8, 3.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSWorkspace.shared.open(url) }
        }
    }

    /// Fecha e reabre o bmonitor: o processo novo enxerga a câmera. Fechar pelo caminho normal
    /// devolve a plataforma do iPhone; o shell espera o processo sair antes de abrir de novo.
    @MainActor
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Quem está vendo

    /// A extensão avisa a cada segundo, por notificação do sistema, enquanto algum app lê a câmera.
    @MainActor
    private func listenForUse() {
        guard inUseTimer == nil, let extensionID else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let camera = Unmanaged<VirtualCamera>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { camera.heardInUse() }
            },
            (extensionID + ".inuse") as CFString, nil, .deliverImmediately)
        inUseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let using = Date().timeIntervalSince(self.lastHeard) < 2.5
                if WebcamStatus.shared.inUse != using { WebcamStatus.shared.inUse = using }
            }
        }
    }

    @MainActor
    private func heardInUse() {
        lastHeard = Date()
        if !WebcamStatus.shared.inUse { WebcamStatus.shared.inUse = true }
    }

    // MARK: - Quadros

    func send(_ image: CVPixelBuffer) {
        guard isAvailable else { return }
        queue.async { self.push(image) }
    }

    private func push(_ image: CVPixelBuffer) {
        guard enabled else { return }
        if sinkQueue == nil { connect() }
        guard let sinkQueue else { return }
        // Fila cheia: a extensão ainda não pegou o anterior. Descarta em vez de acumular atraso.
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else { return }
        guard let output = render(image), let sample = sample(output) else { return }
        CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(sample).toOpaque())
        // Acorda a extensão para buscar o quadro já, em vez de esperar o relógio dela.
        if let frameNotification {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(frameNotification), nil, nil, true)
        }
    }

    /// Gira como na janela (`quarterTurns` no sentido horário) e põe em BGRA 1920 × 1080, com
    /// barras pretas se a proporção for outra (o vídeo em pé), numa passada só de GPU. Girar e
    /// reduzir com o VideoToolbox custava 4,3 ms por quadro 4K deitado e 11 ms em pé; assim, 1,2 ms.
    private func render(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        if outputPool == nil { outputPool = pool(width: Self.size.width, height: Self.size.height, format: kCVPixelFormatType_32BGRA) }
        guard let renderer, let outputPool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &output)
        guard let output else { return nil }
        let orientation: CGImagePropertyOrientation =
            switch quarterTurns {
            case 1: .right
            case 2: .down
            case 3: .left
            default: .up
            }
        let frame = CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height)
        var picture = CIImage(cvPixelBuffer: image).oriented(orientation)
        let scale = min(frame.width / picture.extent.width, frame.height / picture.extent.height)
        picture = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        picture = picture.transformed(by: CGAffineTransform(
            translationX: (frame.width - picture.extent.width) / 2 - picture.extent.minX,
            y: (frame.height - picture.extent.height) / 2 - picture.extent.minY))
        let composed = picture.composited(over: CIImage(color: .black).cropped(to: frame))
        guard let task = try? renderer.startTask(toRender: composed, to: CIRenderDestination(pixelBuffer: output)),
            (try? task.waitUntilCompleted()) != nil
        else { return nil }
        return output
    }

    private func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private func sample(_ image: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    // MARK: - Achar a câmera

    /// O CoreMediaIO tira um retrato da lista de câmeras na primeira consulta do processo e não
    /// enxerga câmera que aparece depois, nem com escuta e laço de eventos (medido em 22/10: na
    /// 0.10.0, aprovada a extensão com o app aberto, a chamada ficava em pausa até reabrir o app).
    /// Por isso nenhuma consulta acontece antes de o macOS confirmar a extensão, mais uma folga.
    private func extensionConfirmed() {
        queue.asyncAfter(deadline: .now() + 1.5) {
            self.activated = Date()
            self.lastAttempt = .distantPast
            self.watchDevices()
        }
    }

    /// Só para saber quando a câmera some (o app fecha a conexão); uma câmera nova não avisa.
    private func watchDevices() {
        guard !watchingDevices else { return }
        watchingDevices = true
        var address = address(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue) { [weak self] _, _ in
            guard let self else { return }
            if self.sinkQueue != nil, !self.devices().contains(self.device) {
                self.log.info("câmera virtual sumiu")
                self.sinkQueue = nil
            }
        }
    }

    /// Acha a câmera "bmonitor" e abre o stream de entrada dela, no máximo uma vez por segundo.
    /// Sem ela 4 s depois da confirmação, este processo não vai enxergá-la: o guia pede para reabrir.
    private func connect() {
        guard let activated, Date().timeIntervalSince(lastAttempt) > 1 else { return }
        lastAttempt = Date()
        guard let device = devices().first(where: { uid(of: $0) == Self.deviceUID }) else {
            if !reportedMissing, Date().timeIntervalSince(activated) > 4 {
                reportedMissing = true
                log.error("câmera virtual ativa, mas fora da lista deste processo")
                DispatchQueue.main.async { WebcamStatus.shared.needsRelaunch = true }
            }
            return
        }
        // A extensão cria primeiro o stream de saída e depois o de entrada.
        let streams = streams(of: device)
        guard streams.count >= 2 else { return }
        var queueRef: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(streams[1], { _, _, _ in }, nil, &queueRef)
        guard status == noErr, let queueRef else {
            log.error("CMIOStreamCopyBufferQueue: \(status)")
            return
        }
        sinkQueue = queueRef.takeUnretainedValue()
        CMIODeviceStartStream(device, streams[1])
        self.device = device
        stream = streams[1]
        log.info("câmera virtual conectada")
    }

    /// Quadros cinza a 10 fps enquanto a webcam está ligada, para testar sem o iPhone.
    private func startTestPattern() {
        guard Self.testPattern, patternTimer == nil else { return }
        var gray: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &gray)
        guard let gray else { return }
        CVPixelBufferLockBaseAddress(gray, [])
        memset(CVPixelBufferGetBaseAddress(gray), 0x60, CVPixelBufferGetBytesPerRow(gray) * 1080)
        CVPixelBufferUnlockBaseAddress(gray, [])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.push(gray) }
        timer.resume()
        patternTimer = timer
    }

    private func disconnect() {
        guard sinkQueue != nil else { return }
        CMIODeviceStopStream(device, stream)
        sinkQueue = nil
    }

    private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func objects(of object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private func devices() -> [CMIODeviceID] { objects(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) }

    private func streams(of device: CMIODeviceID) -> [CMIOStreamID] { objects(of: device, kCMIODevicePropertyStreams) }

    private func uid(of device: CMIODeviceID) -> String? {
        var address = address(kCMIODevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: - Ativação

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { WebcamStatus.shared.approval = .waiting }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        log.info("extensão confirmada")
        extensionConfirmed()
        MainActor.assumeIsolated { WebcamStatus.shared.approval = Self.simulatesWaiting ? .waiting : .approved }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log.error("ativação falhou: \(error.localizedDescription, privacy: .public)")
        MainActor.assumeIsolated { WebcamStatus.shared.approval = .failed(error.localizedDescription) }
    }
}
