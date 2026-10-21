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
            CommandMenu("Câmera") {
                Button(model.state.recording ? String(localized: "Parar gravação") : String(localized: "Gravar")) { model.toggleRecord() }
                    .keyboardShortcut(.record)
                    .disabled(model.phase != .connected)
                Button("Focar agora") { model.focusNow() }.keyboardShortcut(.focusNow)
                Divider()
                Button("ISO…") { model.togglePanel(.iso) }.keyboardShortcut(.iso)
                Button("Shutter…") { model.togglePanel(.shutter) }.keyboardShortcut(.shutter)
                Button("Balanço de branco…") { model.togglePanel(.whiteBalance) }.keyboardShortcut(.whiteBalance)
                Button("Tint…") { model.togglePanel(.tint) }.keyboardShortcut(.tint)
                Button("Lente…") { model.togglePanel(.lens) }.keyboardShortcut(.lens)
                Button("Origem de áudio…") { model.togglePanel(.audio) }.keyboardShortcut(.audio)
                Divider()
                Button(model.muted ? String(localized: "Ligar o som no Mac") : String(localized: "Silenciar o som no Mac")) { model.muted.toggle() }
                    .keyboardShortcut(.mute)
                Button(model.grid == .off ? String(localized: "Mostrar grade") : String(localized: "Esconder grade")) { model.toggleGrid() }
                    .keyboardShortcut(.grid)
                Picker("Tipo de grade", selection: $model.grid) {
                    ForEach(AppModel.GridStyle.allCases) { Text($0.title).tag($0) }
                }
                Button(model.safeZone == nil ? String(localized: "Mostrar área segura") : String(localized: "Esconder área segura")) {
                    model.toggleSafeZone()
                }
                .keyboardShortcut(.safeZone)
                Picker("Tipo de área segura", selection: $model.safeZone) {
                    Text("Sem área segura").tag(SafeZone?.none)
                    ForEach(SafeZone.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Button("Girar 90°") { model.rotate() }.keyboardShortcut(.rotate)
            }
            CommandGroup(after: .appInfo) {
                Button("Procurar atualizações…") { updater.checkForUpdates(nil) }
                    .disabled(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Atalhos do teclado") { model.toggleShortcuts() }.keyboardShortcut(.help)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    private var signalSources: [DispatchSourceSignal] = []

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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.shutdown() }
    }
}
