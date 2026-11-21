import AppKit
import CoreImage
import ImageIO
import SwiftUI
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

struct PhotoCaptureView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Button("Salvar foto do Blackmagic…") { model.savePhotoFrame() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSavePhotoFrame)
                Text("Salva como JPEG o quadro recebido do iPhone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ContinuityPhotoButton()
                    .frame(height: 24)
                    .disabled(model.state.recording)
                Text("Escolha o iPhone no menu do macOS. Tire a foto e confirme no iPhone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: 390, alignment: .leading)
    }
}

private struct ContinuityPhotoButton: NSViewRepresentable {
    func makeNSView(context: Context) -> ContinuityButton {
        let button = ContinuityButton()
        button.title = String(localized: "Usar a Câmera de Continuidade…")
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(ContinuityButton.showDeviceMenu)
        return button
    }

    func updateNSView(_ button: ContinuityButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
    }
}

private final class ContinuityButton: NSButton, NSServicesMenuRequestor {
    override var acceptsFirstResponder: Bool { true }

    @objc func showDeviceMenu() {
        guard let window, window.makeFirstResponder(self) else { return }
        let menu = NSMenu()
        // O serviço aparece no menu de contexto se houver um aparelho disponível.
        let hint = NSMenuItem(title: String(localized: "Câmera de Continuidade"), action: nil, keyEquivalent: "")
        menu.addItem(hint)
        let event = NSApp.currentEvent
        let eventLocation = convert(NSPoint(x: bounds.minX, y: bounds.maxY), to: nil)
        guard let contextEvent = NSEvent.mouseEvent(
            with: .rightMouseDown, location: eventLocation, modifierFlags: [], timestamp: event?.timestamp ?? 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: event?.eventNumber ?? 0, clickCount: 1, pressure: 1)
        else { return }
        NSMenu.popUpContextMenu(menu, with: contextEvent, for: self)
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if isEnabled, let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.canReadItem(withDataConformingToTypes: NSImage.imageTypes) else { return false }
        let preferredTypes: [UTType] = [.jpeg, .heic, .png, .tiff]
        for type in preferredTypes {
            let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
            if let data = pasteboard.data(forType: pasteboardType), !data.isEmpty {
                save(data, as: type)
                return true
            }
        }
        guard let data = NSImage(pasteboard: pasteboard)?.tiffRepresentation else { return false }
        save(data, as: .tiff)
        return true
    }

    private func save(_ data: Data, as type: UTType) {
        DispatchQueue.main.async {
            PhotoSavePanel.present(type: type) { url in
                try data.write(to: url, options: .atomic)
            }
        }
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
