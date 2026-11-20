import AppKit
import SwiftUI

/// Como gravar com o microfone do Mac, no desenho do guia da webcam: à esquerda o que é, à
/// direita os passos, embaixo a imagem original. Abre pelo menu Ajuda e pelo painel de áudio.
struct MicrophoneGuide: View {
    @Environment(\.dismiss) private var dismiss
    var model: AppModel

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
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var identity: some View {
        VStack(spacing: 6) {
            Image(systemName: "mic.and.signal.meter.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 112)
                .padding(.bottom, 4)
            Text("Microfone do Mac")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text("A imagem do iPhone e o som do Mac num arquivo só, já sincronizados")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, String(localized: "Escolha o microfone"),
                 String(localized: "Painel de áudio › Microfone do monitor: o microfone do Mac ou qualquer um ligado a ele. O medidor tem que mexer quando você fala."))
            step(2, String(localized: "Deixe o áudio do iPhone ligado"),
                 String(localized: "Em Áudio no iPhone, qualquer origem menos Sem áudio. O som do iPhone é a referência da sincronia e não toca no arquivo final."))
            step(3, String(localized: "Escolha a gravação no Mac"),
                 String(localized: "Substituir áudio do iPhone: só o som do Mac. Manter duas trilhas: o do Mac tocando e o do iPhone guardado para a edição. Arquivo separado não junta nada."))
            step(4, String(localized: "Grave como sempre"),
                 String(localized: "Pelo bmonitor ou pelo iPhone. Ao parar, a pasta das cópias recebe o take com o som do Mac e o som do Mac sozinho, que serve para o original."))
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.white.opacity(0.1))
                Text("\(number)").font(.system(size: 12, weight: .bold).monospacedDigit())
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "4k.tv").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Na qualidade original").font(.system(size: 14, weight: .semibold))
                    Text("A cópia tem a qualidade do stream. Para a imagem original, traga o clipe do iPhone para o Mac (AirDrop, cabo ou Arquivos) e use Câmera › Juntar original do iPhone ao som do Mac. O bmonitor acha o som do take pelo nome do clipe e junta sem recodificar a imagem.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hands.clap").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Para conferir a sincronia").font(.system(size: 14, weight: .semibold))
                    Text("Bata uma palma diante da câmera: o quadro em que as mãos se tocam deve cair junto com o som. O Atraso do microfone é só o ponto de partida; a sincronia fina é automática.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Mostrar cópias no Finder") { model.showCopies() }
                    .buttonStyle(.bordered)
                Button("Juntar original do iPhone ao som do Mac…") { model.mergeOriginals() }
                    .buttonStyle(.bordered)
                    .disabled(model.mergingOriginals)
                Button(action: { dismiss() }) {
                    Text("Concluído")
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
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
