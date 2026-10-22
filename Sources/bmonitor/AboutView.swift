import AppKit
import SwiftUI

/// Janela "Sobre o bmonitor": ícone, nome, autor e versão de um lado, os links do projeto do
/// outro e, embaixo, o convite para um café. Fica no lugar do painel padrão do macOS.
struct AboutView: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center, spacing: 0) {
                identity
                    .frame(maxWidth: .infinity)
                Divider().padding(.vertical, 8)
                links
                    .frame(width: 210, alignment: .leading)
                    .padding(.leading, 28)
            }
            support
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        // Fundo sólido: com o vidro da janela (`containerBackground`), o macOS deixava os botões
        // de fechar invisíveis.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Esquerda

    private var identity: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .padding(.bottom, 4)
            Text("bmonitor")
                .font(.system(size: 30, weight: .bold))
            Link(destination: URL(string: "https://instagram.com/dantearaujo")!) {
                Text("por Dante Araujo").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .pointingHandCursor()
            HStack(spacing: 6) {
                Text(Self.versionLine)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(action: copyVersion) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Copiar a versão"))
                .accessibilityLabel(String(localized: "Copiar a versão"))
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Direita

    private var links: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Projeto")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
            row("globe", String(localized: "Site"), "bmonitor.app", "https://bmonitor.app")
            row("chevron.left.forwardslash.chevron.right", String(localized: "Código aberto"), String(localized: "GitHub, licença MIT"), "https://github.com/dantearaujo/bmonitor")
            row("sparkles", String(localized: "Novidades"), String(localized: "Todas as versões"), "https://github.com/dantearaujo/bmonitor/releases")
            row("exclamationmark.bubble", String(localized: "Relatar um problema"), String(localized: "Issues no GitHub"), "https://github.com/dantearaujo/bmonitor/issues")
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Embaixo

    private var support: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gratuito e de código aberto")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Se o bmonitor te poupa umas idas até o tripé, um café ajuda a manter o app de pé.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Link(destination: URL(string: "https://www.buymeacoffee.com/dantearaujo")!) {
                    Label("Me pague um café", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .fixedSize()
            }
            Text("Projeto independente, sem afiliação com a Blackmagic Design. Blackmagic Camera é marca da Blackmagic Design.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Versão

    /// "Versão 0.9.6 (43)"; o binário solto (swift run) não tem Info.plist.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return String(localized: "Versão de desenvolvimento") }
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Versão \(version) (\(build))")
    }

    private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("bmonitor \(Self.versionLine)", forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }
}
