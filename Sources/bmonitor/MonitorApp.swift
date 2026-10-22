import AppKit
import MonitorCore
import Sparkle
import SwiftUI

@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel
    /// Atualização automática pelo Sparkle, com a janela do app: o feed e a chave pública vêm do
    /// Info.plist do .app. O binário solto (swift run) não tem Info.plist e fica sem atualizador.
    private let updates: Updates

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
        updates = Updates()
        updates.isBusy = { [weak model] in model?.state.recording ?? false }
    }

    var body: some Scene {
        WindowGroup("bmonitor") {
            MonitorView(model: model)
                .frame(minWidth: 480, minHeight: 270)
                // Título da janela no menu Janela e no Mission Control.
                .navigationTitle(model.cameraTitle ?? "bmonitor")
                // Versão nova aparece sozinha ao abrir o app, sem ninguém procurar.
                .onAppear { updates.checkOnLaunch() }
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
                Button("Quadros por segundo…") { model.togglePanel(.frameRate) }.keyboardShortcut(.frameRate, typing: model.script.editing)
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
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
                Button("Procurar atualizações…") { updates.checkNow() }
                    .disabled(!updates.isAvailable)
            }
            CommandGroup(replacing: .help) {
                Button("Atalhos do teclado") { model.toggleShortcuts() }.keyboardShortcut(.help, typing: model.script.editing)
            }
        }

        Window("Sobre o bmonitor", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// "Sobre o bmonitor" abre a janela própria no lugar do painel padrão; o `openWindow` só
/// existe dentro de uma view.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Sobre o bmonitor") { openWindow(id: "about") }
    }
}

/// Itens do menu Roteiro, com os atalhos. O roteiro mora na janela do monitor: o que mexe
/// nele abre o painel antes.
private struct ScriptMenu: View {
    let model: AppModel

    var body: some View {
        let script = model.script
        Button(script.isOpen ? String(localized: "Esconder o roteiro") : String(localized: "Mostrar o roteiro")) { model.toggleScript() }
            .keyboardShortcut(.script)
        Button(script.following ? String(localized: "Parar de seguir a fala") : String(localized: "Seguir a fala")) {
            model.openScript()
            script.toggleFollowing()
        }
        .keyboardShortcut(.follow, typing: script.editing)
        .disabled(script.script.isEmpty)
        Button("Editar o roteiro") {
            model.openScript()
            script.editing = true
        }
        .keyboardShortcut("e")
        .disabled(script.editing)
        Divider()
        Button("Colar roteiro") {
            model.openScript()
            script.paste()
        }
        Button("Abrir arquivo…") {
            model.openScript()
            script.open()
        }
        .keyboardShortcut("o")
        Divider()
        // Setas sem modificador só com o roteiro à vista e nenhum controle aberto: num popover,
        // elas são do slider.
        let reading = script.isOpen && !script.editing && !script.script.isEmpty && model.panel == nil
        Button("Próxima frase") { script.nextSentence() }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!reading)
        Button("Frase anterior") { script.previousSentence() }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!reading)
        Button("Voltar ao início") { script.restart() }.disabled(script.script.isEmpty)
        Divider()
        Button("Texto maior") { script.adjustFont(by: 2) }.keyboardShortcut("+")
        Button("Texto menor") { script.adjustFont(by: -2) }.keyboardShortcut("-")
        Divider()
        DetachItem(model: model)
        ScriptSidePicker(model: model)
    }
}

/// Ações do roteiro no menu "…" da barra do monitor.
struct ScriptActions: View {
    let model: AppModel

    var body: some View {
        let script = model.script
        Button("Editar o roteiro") { script.editing = true }
        Button("Colar roteiro") { script.paste() }
        Button("Abrir arquivo…") { script.open() }
        Divider()
        Button("Voltar ao início") { script.restart() }
        Divider()
        DetachItem(model: model)
        ScriptSidePicker(model: model)
    }
}

/// Destacar o roteiro numa janela própria, ou juntá-lo de volta à janela da câmera.
struct DetachItem: View {
    let model: AppModel

    var body: some View {
        if model.script.detached {
            Button("Juntar à janela da câmera") { model.attachScript() }
        } else {
            Button("Destacar em janela própria") { model.detachScript() }
        }
    }
}

/// De que lado do vídeo o roteiro abre; trocar anda a janela, e o vídeo fica onde estava.
struct ScriptSidePicker: View {
    let model: AppModel

    var body: some View {
        Picker("Lado do roteiro", selection: Binding(get: { model.scriptSide }, set: { model.moveScript(to: $0) })) {
            // Acima e abaixo só com o vídeo deitado; cada orientação guarda a sua escolha.
            ForEach(ScriptModel.Side.choices(landscape: model.isLandscape)) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
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

    /// Saindo, as janelas fecham sozinhas: o roteiro destacado não pode contar isso como
    /// "fechei o roteiro", senão ele não reabre no próximo uso.
    @MainActor static var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.terminating = true }
        return .terminateNow
    }

    /// Fechar o monitor fecha o app: é a saída que devolve a plataforma original ao iPhone.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // O SwiftUI dá à janela do monitor um identificador com o tipo da view; popovers e
            // painéis não fecham o app.
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.contains("MonitorView") == true
            else { return }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.shutdown() }
    }
}
