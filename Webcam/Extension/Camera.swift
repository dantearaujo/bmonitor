import CoreMediaIO
import CoreVideo
import Foundation
import ImageIO
import IOKit.audio
import os

// Webcam virtual do bmonitor. A extensão é uma câmera com dois streams: o "sink", que recebe os
// quadros do bmonitor, e o de saída, que o Meet, o Zoom e os outros leem. Sem quadros do app
// (bmonitor fechado, iPhone desconectado, webcam desligada), a saída mostra o ícone com o símbolo
// de pausa, para a chamada não congelar nem parecer travada. Enquanto algum app lê a saída,
// a extensão avisa o bmonitor a cada segundo, para a cápsula de status mostrar "Webcam".

let width: Int32 = 1920
let height: Int32 = 1080
let fps: Int32 = 30
/// Fixo: é por ele que o bmonitor acha a câmera para mandar os quadros.
let deviceUID = "6B6D6F6E-6974-6F72-0000-000000000001"
let log = Logger(subsystem: "com.dantearaujo.bmonitor.camera", category: "camera")

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource()
        do { try provider.addDevice(deviceSource.device) } catch { log.error("addDevice: \(error.localizedDescription)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "bmonitor" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var output: OutputStream!
    private var sink: SinkStream!
    private let queue = DispatchQueue(label: "bmonitor.camera", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var outputRunning = false
    private var sinkClient: CMIOExtensionClient?
    private var lastFrame: UInt64 = 0
    private var placeholder: CVPixelBuffer?
    private var format: CMVideoFormatDescription!
    private var received = 0
    private var lastUsePost: UInt64 = 0
    private let useNotification = (Bundle.main.bundleIdentifier ?? "com.dantearaujo.bmonitor.camera") + ".inuse"

    override init() {
        super.init()
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: width, height: height,
            extensions: nil, formatDescriptionOut: &description)
        format = description
        let id = UUID(uuidString: deviceUID)!
        device = CMIOExtensionDevice(localizedName: "bmonitor", deviceID: id, legacyDeviceID: deviceUID, source: self)
        let duration = CMTime(value: 1, timescale: fps)
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format, maxFrameDuration: duration, minFrameDuration: duration, validFrameDurations: nil)
        output = OutputStream(format: streamFormat, device: self)
        sink = SinkStream(format: streamFormat, device: self)
        do {
            try device.addStream(output.stream)
            try device.addStream(sink.stream)
        } catch {
            log.error("addStream: \(error.localizedDescription)")
        }
        placeholder = Self.standbyFrame()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "bmonitor" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Ciclo

    func startOutput() { queue.async { self.outputRunning = true; self.ensureTimer() } }
    func stopOutput() { queue.async { self.outputRunning = false; self.stopTimerIfIdle() } }
    func startSink(_ client: CMIOExtensionClient) { queue.async { self.sinkClient = client; self.ensureTimer() } }
    func stopSink() { queue.async { self.sinkClient = nil; self.stopTimerIfIdle() } }

    /// Um relógio só, no dobro do fps: puxa o que o app mandou e, sem nada recente, mantém a saída viva.
    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / Int64(fps * 2))), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimerIfIdle() {
        guard !outputRunning, sinkClient == nil else { return }
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let client = sinkClient {
            sink.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, _ in
                guard let self, let buffer else { return }
                let at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self.queue.async {
                    self.lastFrame = at
                    self.received += 1
                    if self.received % 300 == 1 { log.info("quadros recebidos: \(self.received)") }
                    if self.outputRunning { self.output.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: at) }
                }
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: at))
            }
        }
        if outputRunning, now - lastUsePost > 1_000_000_000 {
            lastUsePost = now
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(useNotification as CFString), nil, nil, true)
        }
        // Sem quadro do app há meio segundo: o quadro de espera, no ritmo do relógio.
        if outputRunning, now - lastFrame > 500_000_000, let placeholder, let sample = sample(placeholder, at: now) {
            output.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }

    private func sample(_ image: CVPixelBuffer, at nanoseconds: UInt64) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: fps),
            presentationTimeStamp: CMTime(value: CMTimeValue(nanoseconds), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result)
        return result
    }

    /// Preto, o ícone do bmonitor apagado no centro e o símbolo de pausa embaixo.
    private static func standbyFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(width), height: Int(height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return buffer }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        let icon: CGFloat = 132
        let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        if let url = Bundle.main.url(forResource: "StandbyIcon", withExtension: "png"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            context.saveGState()
            context.setAlpha(0.55)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: center.x - icon / 2, y: center.y - icon / 2 + 22, width: icon, height: icon))
            context.restoreGState()
        }
        // Pausa em vez de texto: os apps espelham a prévia de quem está na câmera, e texto aparecia
        // ao contrário para a própria pessoa. As duas barras são simétricas e dizem "parada" em
        // qualquer idioma.
        let bar = CGSize(width: 14, height: 44)
        let gap: CGFloat = 14
        let top = center.y - icon / 2 - 4
        context.setFillColor(CGColor(gray: 1, alpha: 0.45))
        for x in [center.x - gap / 2 - bar.width, center.x + gap / 2] {
            let rect = CGRect(x: x, y: top - bar.height, width: bar.width, height: bar.height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        }
        context.fillPath()
        return buffer
    }
}

/// O que os apps de vídeo leem.
final class OutputStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private unowned let device: CameraDeviceSource

    init(format: CMIOExtensionStreamFormat, device: CameraDeviceSource) {
        formats = [format]
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: "bmonitor", streamID: UUID(), direction: .source, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: fps) }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { device.startOutput() }
    func stopStream() throws { device.stopOutput() }
}

/// Por onde o bmonitor entrega os quadros.
final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private unowned let device: CameraDeviceSource
    private var client: CMIOExtensionClient?

    init(format: CMIOExtensionStreamFormat, device: CameraDeviceSource) {
        formats = [format]
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: "bmonitor.sink", streamID: UUID(), direction: .sink, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: fps) }
        // Fila curta: atraso é o que mais importa numa chamada.
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { return }
        device.startSink(client)
    }

    func stopStream() throws { device.stopSink() }
}
