// Protótipo de medição: recebe o livestream SRT do Blackmagic Camera, decodifica por hardware
// e mostra o vídeo ao lado de um relógio em milissegundos. Filmando o relógio com o iPhone,
// a diferença entre o relógio e a imagem dele no vídeo é o atraso vidro a vidro.
//
// Uso: latency-probe --camera <ip-do-iphone> [--port 9000] [--latency 40] [--mac-ip <en0>]

import AVFoundation
import AppKit
import Darwin
import MonitorCore

// MARK: - Argumentos

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func ipv4(of interface: String) -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor {
        let addr = entry.pointee.ifa_addr
        if String(cString: entry.pointee.ifa_name) == interface, let addr, addr.pointee.sa_family == UInt8(AF_INET) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        cursor = entry.pointee.ifa_next
    }
    return nil
}

setvbuf(stdout, nil, _IOLBF, 0)

guard let cameraHost = argument("--camera") else {
    print("uso: latency-probe --camera <ip-do-iphone> [--port 9000] [--latency 40] [--mac-ip <en0>]")
    exit(1)
}
let port = UInt16(argument("--port") ?? "9000")!
let latency = Int32(argument("--latency") ?? "40")!
guard let macIP = argument("--mac-ip") ?? ipv4(of: "en0") else { fatalError("sem IP em en0; use --mac-ip") }

// MARK: - Janela: relógio à esquerda, vídeo à direita

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let screen = NSScreen.screens[0].frame
let windowSize = NSSize(width: 1920, height: 600)
let window = NSWindow(
    contentRect: NSRect(
        x: screen.minX, y: screen.maxY - 120 - windowSize.height,
        width: windowSize.width, height: windowSize.height),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "latency-probe"
window.backgroundColor = .black

let clock = NSTextField(labelWithString: "")
clock.font = .monospacedDigitSystemFont(ofSize: 110, weight: .bold)
clock.textColor = .white
clock.alignment = .center
clock.frame = NSRect(x: 0, y: (windowSize.height - 140) / 2, width: windowSize.width / 2, height: 140)

let videoLayer = AVSampleBufferDisplayLayer()
videoLayer.videoGravity = .resizeAspect
videoLayer.backgroundColor = NSColor.darkGray.cgColor
let videoView = NSView(frame: NSRect(x: windowSize.width / 2, y: 0, width: windowSize.width / 2, height: windowSize.height))
videoView.layer = videoLayer
videoView.wantsLayer = true

window.contentView?.addSubview(clock)
window.contentView?.addSubview(videoView)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

let clockFormatter = DateFormatter()
clockFormatter.dateFormat = "HH:mm:ss.SSS"
let ticker = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in clock.stringValue = clockFormatter.string(from: Date()) }
RunLoop.main.add(ticker, forMode: .common)

// MARK: - Pipeline: SRT → TS → VideoToolbox → camada

func display(_ image: CVPixelBuffer) {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
    guard let format else { return }
    var timing = CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    guard let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
        CFArrayGetCount(attachments) > 0
    {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    let renderer = videoLayer.sampleBufferRenderer
    if renderer.status == .failed { renderer.flush() }
    renderer.enqueue(sample)
}

final class Meter {
    private let lock = NSLock()
    private var frames = 0
    private var assembleNs: UInt64 = 0
    private var decodeNs: UInt64 = 0

    func add(assemble: UInt64, decode: UInt64) {
        lock.lock(); defer { lock.unlock() }
        frames += 1; assembleNs += assemble; decodeNs += decode
    }

    func drain() -> (frames: Int, assembleMs: Double, decodeMs: Double) {
        lock.lock(); defer { lock.unlock() }
        defer { frames = 0; assembleNs = 0; decodeNs = 0 }
        guard frames > 0 else { return (0, 0, 0) }
        return (frames, Double(assembleNs) / Double(frames) / 1e6, Double(decodeNs) / Double(frames) / 1e6)
    }
}

let listener = SRTListener(port: port, latencyMs: latency)
let demuxer = TSDemuxer()
let decoder = VideoDecoder()
let meter = Meter()

decoder.onFrame = display
demuxer.onVideo = { unit in
    let ready = DispatchTime.now().uptimeNanoseconds
    decoder.decode(unit)
    let done = DispatchTime.now().uptimeNanoseconds
    meter.add(assemble: ready - unit.firstPacketAt, decode: done - ready)
}
listener.onPayload = { demuxer.feed($0) }
listener.onConnect = { print("SRT conectado, latência negociada \($0) ms") }
listener.onDisconnect = { print("SRT desconectado") }

let receiver = Thread { listener.run() }
receiver.qualityOfService = .userInteractive
receiver.start()

let report = Timer(timeInterval: 2, repeats: true) { _ in
    let m = meter.drain()
    let s = listener.stats()
    print(String(
        format: "%.0f fps | montagem %.1f ms | decodificação %.1f ms | SRT buffer %d ms, RTT %.1f ms, perdidos %d",
        Double(m.frames) / 2, m.assembleMs, m.decodeMs, s?.tsbpdDelayMs ?? 0, s?.rttMs ?? 0, s?.lostPackets ?? 0))
}
RunLoop.main.add(report, forMode: .common)

// MARK: - Câmera: aponta o livestream para o Mac e devolve o estado original na saída

let camera = CameraAPI(host: cameraHost)
var originalPlatform: [String: Any]?

Task {
    do {
        originalPlatform = try await camera.activePlatform()
        try await camera.putCustomPlatform(file: "MacMonitor.xml", xml: monitorPlatformXML(macIP: macIP, port: port))
        try await camera.setActivePlatform(["platform": "Mac Monitor SRT", "server": "Mac", "quality": "Monitor"])
        try? await camera.stopStream()
        try await Task.sleep(for: .seconds(1))
        try await camera.startStream()
        print("stream pedido para srt://\(macIP):\(port)")
    } catch {
        print("câmera: \(error)")
    }
}

func restoreCameraAndExit() -> Never {
    let done = DispatchSemaphore(value: 0)
    Task {
        try? await camera.stopStream()
        if let originalPlatform { try? await camera.setActivePlatform(originalPlatform) }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 5)
    print("stream parado, plataforma original restaurada")
    exit(0)
}

let signalSources = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { restoreCameraAndExit() }
    source.resume()
    return source
}

final class Closer: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.global().async { restoreCameraAndExit() }
    }
}
let closer = Closer()
window.delegate = closer

app.run()
