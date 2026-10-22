import CoreMediaIO
import Foundation
import SystemExtensions
import VideoToolbox
import os

/// Protótipo da webcam virtual: com a extensão de câmera dentro do app (só no build de
/// desenvolvimento, `Webcam/build-dev.sh`), pede ao macOS para ativá-la e entrega cada quadro
/// decodificado ao stream de entrada dela. O Meet, o Zoom e os outros leem a câmera "bmonitor".
final class VirtualCamera: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    static let shared = VirtualCamera()
    /// O mesmo da extensão (`Webcam/Extension/Camera.swift`).
    private static let deviceUID = "6B6D6F6E-6974-6F72-0000-000000000001"
    private static let size = (width: 1920, height: 1080)
    private let log = Logger(subsystem: "com.dantearaujo.bmonitor", category: "webcam")
    private let queue = DispatchQueue(label: "bmonitor.webcam", qos: .userInteractive)

    // Tudo abaixo só na `queue`.
    private var sinkQueue: CMSimpleQueue?
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var lastAttempt = Date.distantPast
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var sent = 0
    private var dropped = 0

    /// Só há o que ativar quando o build trouxe a extensão.
    var isAvailable: Bool {
        let folder = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty == false) ?? false
    }

    func activate() {
        guard isAvailable, let id = Bundle.main.bundleIdentifier else { return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: id + ".camera", queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("pedido de ativação enviado")
    }

    func send(_ image: CVPixelBuffer) {
        guard isAvailable else { return }
        queue.async { self.push(image) }
    }

    // MARK: - Quadros

    private func push(_ image: CVPixelBuffer) {
        if sinkQueue == nil { connect() }
        guard let sinkQueue else { return }
        // Fila cheia: a extensão ainda não pegou o anterior. Descarta em vez de acumular atraso.
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else {
            dropped += 1
            return
        }
        guard let output = scaled(image), let sample = sample(output) else { return }
        CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(sample).toOpaque())
        sent += 1
        if sent % 300 == 1 { log.info("quadros enviados: \(self.sent), descartados: \(self.dropped)") }
    }

    /// Converte para BGRA 1920 × 1080 na GPU, com barras se a proporção for outra.
    private func scaled(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
            if let transfer {
                VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.size.width,
                kCVPixelBufferHeightKey as String: Self.size.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        guard let transfer, let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output, VTPixelTransferSessionTransferImage(transfer, from: image, to: output) == noErr else { return nil }
        return output
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

    /// Acha a câmera "bmonitor" e abre o stream de entrada dela. Tenta no máximo uma vez por segundo:
    /// antes de o usuário aprovar a extensão, ela não existe.
    private func connect() {
        guard Date().timeIntervalSince(lastAttempt) > 1 else { return }
        lastAttempt = Date()
        guard let device = devices().first(where: { uid(of: $0) == Self.deviceUID }) else { return }
        let streams = streams(of: device)
        // A extensão cria primeiro o stream de saída e depois o de entrada.
        guard streams.count >= 2 else { return }
        let sink = streams[1]
        var queueRef: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueRef)
        guard status == noErr, let queueRef else {
            log.error("CMIOStreamCopyBufferQueue: \(status)")
            return
        }
        sinkQueue = queueRef.takeUnretainedValue()
        let start = CMIODeviceStartStream(device, sink)
        self.device = device
        stream = sink
        log.info("câmera virtual conectada, início do stream: \(start)")
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

    private func devices() -> [CMIODeviceID] {
        objects(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
    }

    private func streams(of device: CMIODeviceID) -> [CMIOStreamID] {
        objects(of: device, kCMIODevicePropertyStreams)
    }

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
        log.info("extensão precisa de aprovação em Ajustes do Sistema")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        log.info("extensão ativada: \(result.rawValue)")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log.error("ativação falhou: \(error.localizedDescription)")
    }
}
