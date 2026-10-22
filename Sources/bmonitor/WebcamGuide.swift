import AppKit
import SwiftUI

/// Guia da primeira vez da webcam, no desenho do Sobre: à esquerda o ícone e o que é; à direita
/// os dois passos; embaixo, o cartão com a ação do momento. Abre ao ligar "Usar como webcam"
/// enquanto a extensão não foi aprovada, e o passo 1 vira um visto sozinho quando ela é.
struct WebcamGuide: View {
    @Environment(\.dismiss) private var dismiss
    private var status: WebcamStatus { .shared }

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center, spacing: 0) {
                identity
                    .frame(width: 190)
                Divider().padding(.vertical, 8)
                steps
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28)
            }
            card
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var identity: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .padding(.bottom, 4)
            Text("Webcam")
                .font(.system(size: 24, weight: .bold))
            Text("O iPhone como câmera do Meet, do Zoom e do FaceTime")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(done: status.approval == .approved, number: 1,
                 title: status.approval == .approved ? String(localized: "Câmera permitida") : String(localized: "Permita a câmera do bmonitor"),
                 detail: status.approval == .approved
                    ? String(localized: "A extensão de câmera está ligada.")
                    : String(localized: "Nos Ajustes, ligue \"bmonitor\" em Extensões de Câmera."))
            step(done: false, number: 2,
                 title: String(localized: "Escolha a câmera \"bmonitor\""),
                 detail: String(localized: "Nas configurações de vídeo da chamada. O som continua no microfone que você já usa."))
        }
    }

    private func step(done: Bool, number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.accentColor : Color.white.opacity(0.1))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .bold).monospacedDigit())
                }
            }
            .frame(width: 22, height: 22)
            .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.25), value: done)
    }

    @ViewBuilder private var card: some View {
        HStack(alignment: .center, spacing: 16) {
            switch status.approval {
            case .approved:
                message(String(localized: "Pronta para usar"),
                        String(localized: "A câmera fica disponível sempre que o bmonitor estiver aberto e conectado ao iPhone."))
                Spacer(minLength: 0)
                action(String(localized: "Concluído")) { dismiss() }
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                message(String(localized: "Não deu para ativar a câmera"), error)
                Spacer(minLength: 0)
                action(String(localized: "Tentar de novo")) { VirtualCamera.shared.setEnabled(true) }
            case .unknown, .waiting:
                ProgressView().controlSize(.small)
                message(String(localized: "Esperando a sua aprovação"),
                        String(localized: "Geral › Itens de Início e Extensões › Extensões de Câmera: clique em ⓘ e ligue \"bmonitor\"."))
                Spacer(minLength: 0)
                action(String(localized: "Abrir Ajustes")) { VirtualCamera.shared.openSettings() }
            }
        }
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func action(_ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
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
}
