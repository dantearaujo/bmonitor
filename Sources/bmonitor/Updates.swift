import AppKit
import MonitorCore
import Sparkle
import SwiftUI

/// Atualização automática com a cara do app. O Sparkle procura, baixa, confere a assinatura
/// e instala; aqui só mora a janela, no mesmo desenho do "Sobre": o que mudou na versão nova
/// e um botão para atualizar, sem o usuário precisar procurar nada.
@MainActor
final class Updates: NSObject {
    let model = UpdateModel()
    private var updater: SPUUpdater?
    private var window: NSWindow?
    /// Gravando, a janela espera: atualizar fecha o app.
    var isBusy: () -> Bool = { false }

    /// O binário solto (swift run) não tem Info.plist nem feed: sem atualizador.
    var isAvailable: Bool { updater != nil }

    override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            // Baixar e instalar em silêncio não mostra nada; a versão nova é oferecida na janela.
            updater.automaticallyDownloadsUpdates = false
            self.updater = updater
        } catch {
            print("atualização: o Sparkle não abriu: \(error.localizedDescription)")
        }
    }

    /// Ao abrir o app: procura em segundo plano e só aparece se houver versão nova. A busca
    /// diária do Sparkle continua valendo para quem deixa o app aberto.
    func checkOnLaunch() {
        Task {
            try? await Task.sleep(for: .seconds(8))
            updater?.checkForUpdatesInBackground()
        }
    }

    func checkNow() { updater?.checkForUpdates() }

    // MARK: - Janela

    fileprivate func present() {
        if window == nil {
            let hosting = NSHostingView(rootView: UpdateView(model: model))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = String(localized: "Atualização do bmonitor")
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func close() {
        window?.orderOut(nil)
    }
}

extension Updates: NSWindowDelegate {
    /// Fechar a janela é "depois": cancela o que estiver em curso sem pular a versão.
    func windowWillClose(_ notification: Notification) {
        model.resolve(.dismiss)
    }
}

extension Updates: SPUUpdaterDelegate {
    /// Desenvolvimento: `--update-feed <url>` lê outro appcast, para testar a janela com uma
    /// versão local sem publicar nada.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--update-feed"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

extension Updates: @preconcurrency SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // A busca automática já vem ligada no Info.plist; se o Sparkle perguntar, a resposta é sim.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.start(.checking, cancel: cancellation)
        present()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.offer(appcastItem, downloaded: state.stage != .notDownloaded, reply: reply)
        guard state.userInitiated || !isBusy() else {
            // Gravando: mostra quando a gravação parar.
            Task {
                while isBusy() { try? await Task.sleep(for: .seconds(5)) }
                if model.isPending { present() }
            }
            return
        }
        present()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        model.setNotes(data: downloadData.data, mimeType: downloadData.mimeType)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        model.finish(.upToDate, acknowledgement: acknowledgement)
        present()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        model.finish(.failed(error.localizedDescription), acknowledgement: acknowledgement)
        // Erro numa busca automática não interrompe ninguém; só quem pediu vê.
        if window?.isVisible == true { present() } else { model.resolve(.dismiss) }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        model.start(.downloading(received: 0, expected: 0), cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        model.stage = .downloading(received: 0, expected: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if case .downloading(let received, let expected) = model.stage {
            model.stage = .downloading(received: received + length, expected: expected)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        model.stage = .extracting(0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.stage = .extracting(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.ready(reply: reply)
        present()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        model.stage = .installing
        // O pedido de saída que o instalador manda não fechava o app (medido: a troca ficava
        // parada em "Instalando…"). Quem escolheu "Instalar e reabrir" quer sair: o app fecha
        // sozinho, pelo caminho normal que devolve a câmera, e o instalador segue.
        guard !applicationTerminated else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.terminate(nil)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        close()
    }

    func showUpdateInFocus() {
        present()
    }

    func dismissUpdateInstallation() {
        model.reset()
        close()
    }
}

// MARK: - Estado

@MainActor @Observable
final class UpdateModel {
    enum Stage: Equatable {
        case idle
        case checking
        case found
        case downloading(received: UInt64, expected: UInt64)
        case extracting(Double)
        case ready
        case installing
        case upToDate
        case failed(String)
    }

    var stage: Stage = .idle
    private(set) var version = ""
    private(set) var notes: Script?
    /// A versão nova já foi baixada antes (o usuário disse "depois" com ela pronta).
    private(set) var downloaded = false

    @ObservationIgnored private var choice: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancel: (() -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?

    var isPending: Bool { choice != nil }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    func start(_ stage: Stage, cancel: @escaping () -> Void) {
        self.stage = stage
        self.cancel = cancel
    }

    func offer(_ item: SUAppcastItem, downloaded: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = item.displayVersionString
        self.downloaded = downloaded
        notes = item.itemDescription.map { Self.notes(from: $0, html: item.itemDescriptionFormat == "html") }
        stage = .found
        cancel = nil
        choice = reply
    }

    func ready(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        stage = .ready
        cancel = nil
        choice = reply
    }

    func finish(_ stage: Stage, acknowledgement: @escaping () -> Void) {
        self.stage = stage
        cancel = nil
        self.acknowledgement = acknowledgement
    }

    func setNotes(data: Data, mimeType: String?) {
        let text = String(decoding: data, as: UTF8.self)
        notes = Self.notes(from: text, html: mimeType?.contains("html") ?? text.contains("<"))
    }

    /// Responde ao Sparkle uma vez só: a escolha, o cancelamento ou o "ok".
    func resolve(_ answer: SPUUserUpdateChoice) {
        if let choice {
            self.choice = nil
            choice(answer)
        } else if let cancel {
            self.cancel = nil
            cancel()
        } else if let acknowledgement {
            self.acknowledgement = nil
            acknowledgement()
        }
    }

    func reset() {
        stage = .idle
        choice = nil
        cancel = nil
        acknowledgement = nil
    }

    /// As notas vêm em Markdown (as do repo) e viram blocos como os do roteiro; HTML vira texto.
    private static func notes(from text: String, html: Bool) -> Script {
        guard html, let data = text.data(using: .utf8),
            let attributed = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return Script(markdown: text) }
        return Script(markdown: attributed.string)
    }
}

// MARK: - Janela

/// No desenho do "Sobre": o app e a versão nova à esquerda, o que mudou à direita e, embaixo,
/// o que fazer agora.
struct UpdateView: View {
    let model: UpdateModel

    var body: some View {
        Group {
            switch model.stage {
            case .checking, .upToDate, .failed, .idle:
                compact
            default:
                offer
            }
        }
        .preferredColorScheme(.dark)
        // Fundo escuro sólido: o vidro atrás da janela ficava cinza quando ela perdia o foco.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    // MARK: Versão nova

    private var offer: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 6) {
                    icon(112)
                    Text("bmonitor \(model.version)")
                        .font(.system(size: 22, weight: .bold))
                    Text("Nova versão")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Você tem a \(model.currentVersion).")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .frame(width: 210)
                .padding(.top, 8)
                Divider().padding(.horizontal, 24)
                notes
            }
            .frame(height: 250)
            action
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 640)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("O que mudou")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            if let notes = model.notes, !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes.blocks) { block in NoteBlock(block: block) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .scrollIndicators(.automatic)
            } else {
                Text("As novidades desta versão estão na página de versões.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Link("Ver as versões no GitHub", destination: URL(string: "https://github.com/dantearaujo/bmonitor/releases")!)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var action: some View {
        card {
            switch model.stage {
            case .found:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.downloaded ? "Pronta para instalar" : "Atualiza em segundos")
                            .font(.system(size: 15, weight: .semibold))
                        Text("O bmonitor fecha, devolve a câmera ao normal e reabre na versão nova.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Pular esta versão") { model.resolve(.skip) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    Button("Depois") { model.resolve(.dismiss) }
                        .keyboardShortcut(.cancelAction)
                    primary(String(localized: "Atualizar agora")) { model.resolve(.install) }
                }
            case .downloading(let received, let expected):
                progress(
                    expected > 0 ? Double(received) / Double(expected) : nil,
                    expected > 0
                        ? String(localized: "Baixando… \(Self.megabytes(received)) de \(Self.megabytes(expected))")
                        : String(localized: "Baixando…"),
                    cancellable: true)
            case .extracting(let fraction):
                progress(fraction, String(localized: "Preparando a instalação…"), cancellable: false)
            case .ready:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pronta para instalar").font(.system(size: 15, weight: .semibold))
                        Text("O bmonitor fecha, devolve a câmera ao normal e reabre na versão nova.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Depois") { model.resolve(.dismiss) }
                        .keyboardShortcut(.cancelAction)
                    primary(String(localized: "Instalar e reabrir")) { model.resolve(.install) }
                }
            default:
                progress(nil, String(localized: "Instalando…"), cancellable: false)
            }
        }
    }

    private func progress(_ fraction: Double?, _ label: String, cancellable: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.system(size: 13, weight: .semibold).monospacedDigit())
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if cancellable {
                Button("Cancelar") { model.resolve(.dismiss) }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Procurando, em dia, erro

    private var compact: some View {
        VStack(spacing: 14) {
            icon(80)
            switch model.stage {
            case .upToDate:
                Text("O bmonitor está em dia").font(.system(size: 17, weight: .semibold))
                Text("Você tem a versão mais recente, \(model.currentVersion).")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button("OK") { model.resolve(.dismiss) }.keyboardShortcut(.defaultAction).padding(.top, 4)
            case .failed(let message):
                Label("Não deu para procurar atualizações", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("OK") { model.resolve(.dismiss) }.keyboardShortcut(.defaultAction).padding(.top, 4)
            default:
                Text("Procurando atualizações…").font(.system(size: 15, weight: .semibold))
                ProgressView().progressViewStyle(.linear).frame(width: 220)
                Button("Cancelar") { model.resolve(.dismiss) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 380)
    }

    // MARK: Peças

    private func icon(_ size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// O botão principal, igual ao do café no "Sobre".
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .fixedSize()
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

/// Um bloco das notas da versão: título em negrito, item de lista com marcador.
private struct NoteBlock: View {
    let block: Script.Block

    var body: some View {
        switch block.kind {
        case .heading:
            Text(block.text).font(.system(size: 13, weight: .bold)).padding(.top, 4)
        case .bullet, .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(block.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
        default:
            Text(block.text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
