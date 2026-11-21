import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Mantém só o quadro decodificado mais recente, independente da renderização do monitor.
final class PhotoFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (image: CVPixelBuffer, time: UInt64)?

    func receive(_ image: CVPixelBuffer) {
        lock.withLock { latest = (image, DispatchTime.now().uptimeNanoseconds) }
    }

    func current() -> CVPixelBuffer? {
        lock.withLock {
            guard let latest, DispatchTime.now().uptimeNanoseconds - latest.time < 1_000_000_000 else { return nil }
            return latest.image
        }
    }

    static func jpeg(_ frame: CVPixelBuffer, quarterTurns: Int) throws -> Data {
        let turns = ((quarterTurns % 4) + 4) % 4
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][turns]
        let image = CIImage(cvPixelBuffer: frame).oriented(orientation)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let jpeg = CIContext().jpegRepresentation(
                of: image, colorSpace: colorSpace, options: [quality: 0.95])
        else { throw CocoaError(.fileWriteUnknown) }
        return jpeg
    }
}

@MainActor
enum PhotoSavePanel {
    static func present(type: UTType, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.directoryURL = .picturesDirectory
        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "bmonitor-\(stamp).\(type.preferredFilenameExtension ?? "jpg")"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) { try write(url) }.value
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }
}
