import AppKit
import CoreMediaIO
import Foundation
import Observation
import SystemExtensions
import VideoToolbox
import os

/// O que a interface mostra da webcam: o guia da primeira vez e a cápsula de saúde.
@MainActor @Observable
final class WebcamStatus {
    static let shared = WebcamStatus()

    enum Approval: Equatable { case unknown, waiting, approved, failed(String) }
    var approval: Approval = .unknown
    /// Algum app (Meet, Zoom, FaceTime) está lendo a câmera agora.
    var inUse = false
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
    private var scaler: VTPixelTransferSession?
    private var rotator: VTPixelRotationSession?
    private var outputPool: CVPixelBufferPool?
    private var rotatedPool: CVPixelBufferPool?
    private var rotatedSize = (width: 0, height: 0)
    private var watchingDevices = false

    // Na main.
    private var lastHeard = Date.distantPast
    private var inUseTimer: Timer?

    /// Só há webcam quando o build trouxe a extensão.
    let isAvailable: Bool = {
        let folder = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty == false) ?? false
    }()

    private var extensionID: String? { Bundle.main.bundleIdentifier.map { $0 + ".camera" } }

    // MARK: - Ligar e desligar

    /// Ligada, pede a ativação (que também troca a extensão antiga depois de uma atualização) e
    /// passa a entregar quadros; desligada, solta a câmera, que volta a "Câmera em espera".
    @MainActor
    func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        queue.async {
            self.enabled = on
            if on { self.watchDevices() } else { self.disconnect() }
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
        guard let upright = rotated(image), let output = scaled(upright), let sample = sample(output) else { return }
        CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(sample).toOpaque())
    }

    /// Gira como na janela (`quarterTurns` no sentido horário).
    private func rotated(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        guard quarterTurns != 0 else { return image }
        let (w, h) = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
        let size = quarterTurns % 2 == 1 ? (width: h, height: w) : (width: w, height: h)
        if rotator == nil { VTPixelRotationSessionCreate(kCFAllocatorDefault, &rotator) }
        if rotatedPool == nil || rotatedSize != size {
            rotatedPool = pool(width: size.width, height: size.height, format: CVPixelBufferGetPixelFormatType(image))
            rotatedSize = size
        }
        guard let rotator, let rotatedPool else { return nil }
        let angle: CFString =
            switch quarterTurns {
            case 1: kVTRotation_CW90
            case 2: kVTRotation_180
            default: kVTRotation_CCW90
            }
        VTSessionSetProperty(rotator, key: kVTPixelRotationPropertyKey_Rotation, value: angle)
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, rotatedPool, &output)
        guard let output, VTPixelRotationSessionRotateImage(rotator, image, output) == noErr else { return nil }
        return output
    }

    /// BGRA 1920 × 1080 na GPU, com barras pretas se a proporção for outra (o vídeo em pé).
    private func scaled(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        if scaler == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &scaler)
            if let scaler { VTSessionSetProperty(scaler, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox) }
            outputPool = pool(width: Self.size.width, height: Self.size.height, format: kCVPixelFormatType_32BGRA)
        }
        guard let scaler, let outputPool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &output)
        guard let output, VTPixelTransferSessionTransferImage(scaler, from: image, to: output) == noErr else { return nil }
        return output
    }

    private func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
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

    /// A lista de câmeras que o processo vê não se atualiza sozinha: aprovada com o app aberto, a
    /// câmera "bmonitor" não aparecia até reabrir o app (achado em 22/10, na 0.10.0). Escutar a
    /// lista faz o CoreMediaIO mantê-la em dia; a cada mudança, a conexão é refeita.
    private func watchDevices() {
        guard !watchingDevices else { return }
        watchingDevices = true
        var address = address(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue) { [weak self] _, _ in
            guard let self else { return }
            self.log.info("lista de câmeras mudou")
            if self.sinkQueue != nil, !self.devices().contains(self.device) { self.sinkQueue = nil }
            self.lastAttempt = .distantPast
        }
    }

    /// Acha a câmera "bmonitor" e abre o stream de entrada dela. Tenta no máximo uma vez por
    /// segundo: antes de o usuário aprovar a extensão, ela não existe, e depois aparece sozinha.
    private func connect() {
        guard Date().timeIntervalSince(lastAttempt) > 1 else { return }
        lastAttempt = Date()
        guard let device = devices().first(where: { uid(of: $0) == Self.deviceUID }) else { return }
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
        // Aprovada agora: a câmera acabou de aparecer; tenta conectar já no próximo quadro.
        queue.async { self.lastAttempt = .distantPast }
        MainActor.assumeIsolated { WebcamStatus.shared.approval = Self.simulatesWaiting ? .waiting : .approved }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log.error("ativação falhou: \(error.localizedDescription, privacy: .public)")
        MainActor.assumeIsolated { WebcamStatus.shared.approval = .failed(error.localizedDescription) }
    }
}
