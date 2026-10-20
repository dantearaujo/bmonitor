// Gera o fundo da janela do .dmg (660 × 400 pt, em 1x e 2x): instrução de arrastar para
// Aplicativos, uma seta entre os dois ícones e o passo de primeira abertura do beta.
// Neutros do macOS em modo claro; sem cor, como o resto do app (DESIGN.md).
// Uso: swift scripts/make-dmg-background.swift <pasta-de-saída>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// Medidas em pontos, origem no topo (como o Finder posiciona os ícones).
let size = CGSize(width: 660, height: 400)
let iconY: CGFloat = 196  // centro dos ícones; o settings do dmgbuild usa o mesmo valor
let appX: CGFloat = 180, applicationsX: CGFloat = 480

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Desenha em pontos com origem no topo.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    // Fundo: cinza claro do sistema.
    ctx.setFillColor(NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1).cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))

    // Seta entre os ícones: traço fino e ponta aberta, em grafite secundário.
    let arrowY = iconY - 8
    let from = appX + 92, to = applicationsX - 92
    ctx.setStrokeColor(NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1).cgColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: from, y: arrowY))
    ctx.addLine(to: CGPoint(x: to, y: arrowY))
    ctx.move(to: CGPoint(x: to - 14, y: arrowY - 12))
    ctx.addLine(to: CGPoint(x: to, y: arrowY))
    ctx.addLine(to: CGPoint(x: to - 14, y: arrowY + 12))
    ctx.strokePath()

    // Textos: o contexto de texto do AppKit espera origem embaixo; desenhe com flip local.
    func text(_ string: String, _ font: NSFont, _ color: NSColor, centerY: CGFloat) {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let bounds = attributed.size()
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        attributed.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: size.height - centerY - bounds.height / 2))
        ctx.restoreGState()
    }
    let primary = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
    let secondary = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)
    text("Arraste o bmonitor para Aplicativos", .systemFont(ofSize: 17, weight: .semibold), primary, centerY: 48)
    text("Drag bmonitor to Applications", .systemFont(ofSize: 13, weight: .regular), secondary, centerY: 72)

    // Rodapé: o passo em que o beta trava, sem notarização.
    ctx.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06).cgColor)
    ctx.fill(CGRect(x: 0, y: size.height - 74, width: size.width, height: 74))
    text("Na primeira abertura: Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim",
         .systemFont(ofSize: 11, weight: .medium), secondary, centerY: size.height - 46)
    text("First launch: System Settings › Privacy & Security › Open Anyway",
         .systemFont(ofSize: 11, weight: .regular), secondary, centerY: size.height - 28)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    try render(scale: scale).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("fundo em \(out.path)")
