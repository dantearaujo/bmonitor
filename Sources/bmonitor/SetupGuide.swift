import CoreImage.CIFilterBuiltins
import SwiftUI

/// Tela da busca: um iPhone com o ícone do Blackmagic Camera pulsando e uma seta em cima. Quem
/// abre o bmonitor pela primeira vez acha que ele controla a Câmera do iPhone; o ícone real
/// diz qual app abrir. Embaixo, o que o Mac consegue diagnosticar e os ajustes do app.
struct SetupGuide: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height * 1.15
            // Do mais completo ao mais enxuto: a janela vai de 480 x 270 até a tela inteira, e o
            // primeiro arranjo que couber ganha. O ícone fica sempre; os detalhes saem antes.
            ViewThatFits {
                if wide {
                    ForEach(GuideLayout.wide, id: \.self) { layout in
                        HStack(spacing: 36 * layout.phone) {
                            GuidePhone(scale: layout.phone)
                            GuideText(model: model, centered: false, level: layout.text)
                        }
                    }
                } else {
                    ForEach(GuideLayout.tall, id: \.self) { layout in
                        VStack(spacing: 20) {
                            GuidePhone(scale: layout.phone)
                            GuideText(model: model, centered: true, level: layout.text)
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct GuideLayout: Hashable {
    let phone: CGFloat
    let text: GuideText.Level

    static let wide = [
        GuideLayout(phone: 1, text: .full), GuideLayout(phone: 0.8, text: .full),
        GuideLayout(phone: 0.65, text: .steps), GuideLayout(phone: 0.55, text: .minimal),
    ]
    static let tall = [
        GuideLayout(phone: 0.85, text: .full), GuideLayout(phone: 0.7, text: .full),
        GuideLayout(phone: 0.55, text: .full), GuideLayout(phone: 0.55, text: .steps),
        GuideLayout(phone: 0.45, text: .minimal),
    ]
}

private struct GuideText: View {
    /// Quanto do texto cabe: tudo, os passos sem o detalhe, ou só título e diagnóstico.
    enum Level: Hashable { case full, steps, minimal }

    @Bindable var model: AppModel
    let centered: Bool
    let level: Level
    @State private var showsCode = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 16) {
            VStack(alignment: centered ? .center : .leading, spacing: 6) {
                Text("Abra o Blackmagic Camera\nno iPhone")
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(centered ? .center : .leading)
                Text("O bmonitor controla esse app, não a Câmera do iPhone.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(centered ? .center : .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            status
            if level != .minimal {
                let details = level == .full
                VStack(alignment: .leading, spacing: details ? 10 : 6) {
                    GuideStep(
                        number: 1, title: String(localized: "Ligue o controle remoto"),
                        detail: details ? String(localized: "Em Remote Camera Control, modo Remote Camera.") : nil)
                    GuideStep(
                        number: 2, title: String(localized: "Ligue o servidor HTTP"),
                        detail: details ? String(localized: "Em Network Access, servidor HTTP ligado.") : nil)
                    GuideStep(
                        number: 3, title: String(localized: "Mesma Wi‑Fi"),
                        detail: details ? String(localized: "Mac e iPhone na mesma rede.") : nil)
                }
                .frame(width: 290, alignment: .leading)
            }
            Button {
                showsCode.toggle()
            } label: {
                Label("Ainda não tem? Baixar na App Store", systemImage: "qrcode")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.link)
            .popover(isPresented: $showsCode, arrowEdge: .bottom) { StoreCode() }
        }
    }

    /// O que o Mac sabe agora. Permissão e rede vêm antes da busca: sem elas, procurar é inútil.
    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            if model.localNetworkDenied {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text("Rede Local bloqueada no Mac")
                Button("Abrir Ajustes") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
                .buttonStyle(.link)
            } else if !model.onNetwork {
                Image(systemName: "wifi.slash").foregroundStyle(Theme.warn)
                Text("Mac sem rede. Use a Wi‑Fi do iPhone.")
            } else {
                ProgressView().controlSize(.small)
                Text("Procurando o iPhone na rede…")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hudGlass(Capsule())
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "\(number).circle").font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// QR da página do Blackmagic Camera na App Store: o app é de iPhone, então o caminho é a
/// câmera do iPhone, não a App Store do Mac.
private struct StoreCode: View {
    static let url = URL(string: "https://apps.apple.com/app/id6449580241")!

    var body: some View {
        VStack(spacing: 12) {
            if let image = Self.code {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150)
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Aponte a câmera do iPhone para o código.\nO Blackmagic Camera é grátis.")
                .font(.callout).multilineTextAlignment(.center)
            Link("Abrir na App Store", destination: Self.url).font(.callout)
        }
        .padding(18)
    }

    private static let code: NSImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }()
}

/// Um iPhone na tela inicial: os outros apps são quadrados apagados e só o Blackmagic Camera
/// tem cor, maior que os vizinhos, pulsando sob uma seta.
private struct GuidePhone: View {
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private let width: CGFloat = 170
    private let height: CGFloat = 330
    private let slot: CGFloat = 28
    private let gap: CGFloat = 10
    private let top: CGFloat = 48
    private let row: CGFloat = 44
    /// Linha 2, coluna 3: a seta cabe na casa de cima, que fica vazia.
    private let target = (row: 1, col: 2)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Color(white: 0.07))
            RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(Color(white: 0.34), lineWidth: 3)
            Capsule().fill(.black).frame(width: 50, height: 14).offset(x: (width - 50) / 2, y: 14)
            ForEach(0..<5) { r in
                ForEach(0..<4) { c in
                    if !(c == target.col && r <= target.row) {
                        RoundedRectangle(cornerRadius: slot * 0.225, style: .continuous)
                            .fill(.white.opacity(0.07))
                            .frame(width: slot, height: slot)
                            .offset(x: x(c), y: y(r))
                    }
                }
            }
            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: slot)
                .offset(x: x(target.col), y: y(target.row - 1) + (pulsing ? 2 : -3))
            BlackmagicIcon(size: slot * 1.6)
                .shadow(color: Color.accentColor.opacity(pulsing ? 0.9 : 0.35), radius: pulsing ? 14 : 6)
                .scaleEffect(pulsing ? 1.08 : 1)
                .offset(x: x(target.col) - slot * 0.3, y: y(target.row) - slot * 0.1)
            Capsule().fill(.white.opacity(0.25)).frame(width: 56, height: 4).offset(x: (width - 56) / 2, y: height - 14)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .scaleEffect(scale)
        .frame(width: width * scale, height: height * scale)
        .accessibilityElement()
        .accessibilityLabel("Ícone do Blackmagic Camera na tela inicial do iPhone")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
        }
    }

    private func x(_ column: Int) -> CGFloat { 14 + CGFloat(column) * (slot + gap) }
    private func y(_ line: Int) -> CGFloat { top + CGFloat(line) * row }
}

/// O ícone real do app, para ser reconhecido de longe. Sem o arquivo (binário solto), um
/// substituto azul com a câmera.
struct BlackmagicIcon: View {
    let size: CGFloat
    private static let image = Bundle.main.image(forResource: "blackmagic-camera")

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                ZStack {
                    Color(red: 0.16, green: 0.36, blue: 0.7)
                    Image(systemName: "camera.fill").font(.system(size: size * 0.45)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
