import AppKit
import MonitorCore
import Sparkle
import SwiftUI

@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel
    /// Atualização automática pelo Sparkle: o feed e a chave pública vêm do Info.plist do .app.
    /// O binário solto (swift run) não tem Info.plist, então o atualizador não liga nele.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        WindowGroup("bmonitor") {
            MonitorView(model: model)
                .frame(minWidth: 480, minHeight: 270)
                // Título da janela no menu Janela e no Mission Control.
                .navigationTitle(model.cameraTitle ?? "bmonitor")
                .onAppear {
                    // Desenvolvimento: `--check-updates-now` procura atualização em segundo plano ao abrir,
                    // para testar o Sparkle de ponta a ponta sem clicar no menu.
                    if CommandLine.arguments.contains("--check-updates-now") {
                        updater.updater.checkForUpdatesInBackground()
                    }
                }
        }
        // Janela comum, ao lado do roteiro e de outras janelas; nada de Space próprio.
        .defaultSize(width: 960, height: 540)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Roteiro") {
                ScriptMenu(model: model)
            }
            CommandMenu("Câmera") {
                Button(model.state.recording ? String(localized: "Parar gravação") : String(localized: "Gravar")) { model.toggleRecord() }
                    .keyboardShortcut(.record, typing: model.script.editing)
                    .disabled(model.phase != .connected)
                Button("Focar agora") { model.focusNow() }.keyboardShortcut(.focusNow, typing: model.script.editing)
                Divider()
                Toggle("Salvar cópia de cada take no Mac", isOn: $model.savesCopy)
                Button("Escolher pasta das cópias…") { model.chooseCopyFolder() }
                Button("Mostrar cópias no Finder") { model.showCopies() }
                Divider()
                Button("ISO…") { model.togglePanel(.iso) }.keyboardShortcut(.iso, typing: model.script.editing)
                Button("Shutter…") { model.togglePanel(.shutter) }.keyboardShortcut(.shutter, typing: model.script.editing)
                Button("Balanço de branco…") { model.togglePanel(.whiteBalance) }.keyboardShortcut(.whiteBalance, typing: model.script.editing)
                Button("Tint…") { model.togglePanel(.tint) }.keyboardShortcut(.tint, typing: model.script.editing)
                Button("Formato de gravação…") { model.togglePanel(.format) }.keyboardShortcut(.format, typing: model.script.editing)
                Button("Lente…") { model.togglePanel(.lens) }.keyboardShortcut(.lens, typing: model.script.editing)
                Button("Origem de áudio…") { model.togglePanel(.audio) }.keyboardShortcut(.audio, typing: model.script.editing)
                Button("Subir o ganho do áudio") { model.stepAudioGain(by: 0.05) }
                    .keyboardShortcut(.gainUp, typing: model.script.editing).disabled(!model.gainAdjustable)
                Button("Baixar o ganho do áudio") { model.stepAudioGain(by: -0.05) }
                    .keyboardShortcut(.gainDown, typing: model.script.editing).disabled(!model.gainAdjustable)
                Divider()
                Button(model.muted ? String(localized: "Ligar o som no Mac") : String(localized: "Silenciar o som no Mac")) { model.muted.toggle() }
                    .keyboardShortcut(.mute, typing: model.script.editing)
                Button(model.grid == .off ? String(localized: "Mostrar grade") : String(localized: "Esconder grade")) { model.toggleGrid() }
                    .keyboardShortcut(.grid, typing: model.script.editing)
                Picker("Tipo de grade", selection: $model.grid) {
                    ForEach(AppModel.GridStyle.allCases) { Text($0.title).tag($0) }
                }
                Button(model.safeZone == nil ? String(localized: "Mostrar área segura") : String(localized: "Esconder área segura")) {
                    model.toggleSafeZone()
                }
                .keyboardShortcut(.safeZone, typing: model.script.editing)
                Picker("Tipo de área segura", selection: $model.safeZone) {
                    Text("Sem área segura").tag(SafeZone?.none)
                    ForEach(SafeZone.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Button("Girar 90°") { model.rotate() }.keyboardShortcut(.rotate, typing: model.script.editing)
            }
            CommandGroup(after: .appInfo) {
                Button("Procurar atualizações…") { updater.checkForUpdates(nil) }
                    .disabled(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Atalhos do teclado") { model.toggleShortcuts() }.keyboardShortcut(.help, typing: model.script.editing)
            }
        }

        // O roteiro fica numa janela própria ao lado do monitor, nunca sobre o vídeo.
        Window("Roteiro", id: "script") {
            ScriptView(model: model.script, cameraConnected: model.phase == .connected)
        }
        .defaultSize(width: 600, height: 820)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Itens do menu Roteiro; o `openWindow` só existe dentro de uma view.
private struct ScriptMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let script = model.script
        Button("Mostrar o roteiro") { openWindow(id: "script") }.keyboardShortcut(.script)
        Button(script.following ? String(localized: "Parar de seguir a fala") : String(localized: "Seguir a fala")) {
            openWindow(id: "script")
            script.toggleFollowing()
        }
        .keyboardShortcut(.follow, typing: script.editing)
        .disabled(script.script.isEmpty)
        Button("Editar o roteiro") {
            openWindow(id: "script")
            script.editing = true
        }
        .keyboardShortcut("e")
        .disabled(script.editing)
        Divider()
        Button("Colar roteiro") {
            openWindow(id: "script")
            script.paste()
        }
        Button("Abrir arquivo…") {
            openWindow(id: "script")
            script.open()
        }
        .keyboardShortcut("o")
        Divider()
        Button("Voltar ao início") { script.restart() }.disabled(script.script.isEmpty)
        Button("Texto maior") { script.adjustFont(by: 4) }.keyboardShortcut("+")
        Button("Texto menor") { script.adjustFont(by: -4) }.keyboardShortcut("-")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    private var signalSources: [DispatchSourceSignal] = []
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Rodando pelo terminal, Ctrl-C também devolve a câmera ao estado original.
        signalSources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            return source
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Fechar o monitor fecha o app, mesmo com o roteiro aberto: é a saída que devolve a
    /// plataforma original ao iPhone.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // O SwiftUI dá à janela do monitor um identificador com o tipo da view; popovers,
            // painéis e o roteiro ("script") não fecham o app.
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.contains("MonitorView") == true
            else { return }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.shutdown() }
    }
}
