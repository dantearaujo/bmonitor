import AppKit
import SwiftUI

/// O roteiro destacado: o mesmo painel numa janela própria, que se move e muda de tamanho
/// livremente e lembra onde ficou. O botão da cápsula junta de volta à janela da câmera.
@MainActor
final class ScriptWindow: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let window: NSWindow
    private var closingByCode = false

    init(app: AppModel) {
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Roteiro")
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = CGSize(width: 320, height: 280)
        let hosting = NSHostingView(rootView: ScriptPanel(app: app))
        // Sem isso, o tamanho ideal do texto prende a janela.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.delegate = self
        // Lembra posição e tamanho entre aberturas do app.
        window.setFrameAutosaveName("bmonitor.script")
    }

    /// `frame`: onde o roteiro estava dentro da janela da câmera, ao destacar. Sem ele, a
    /// janela volta para onde ficou da última vez.
    func show(frame: CGRect?) {
        if let frame { window.setFrame(frame, display: true) }
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard window.isVisible else { return }
        closingByCode = true
        window.close()
        closingByCode = false
    }

    func windowWillClose(_ notification: Notification) {
        if !closingByCode, !AppDelegate.terminating { onClose?() }
    }
}
