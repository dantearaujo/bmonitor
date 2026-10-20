// Gera o ícone do app (AppIcon.icns) por código: corpo grafite no formato de ícone do macOS,
// os anéis de lente do seletor de lentes e o ponto de REC. Sem marca nem logotipo (PRODUCT.md).
// Uso: swift scripts/make-icon.swift <pasta-de-saída>   (cria AppIcon.iconset e AppIcon.icns)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Corpo: grade de ícone do macOS (824 pt dentro de 1024, cantos de 185), sombra curta.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    // Borda fina de vidro no corpo.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3 * s, dy: 3 * s), cornerWidth: 182 * s, cornerHeight: 182 * s, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(6 * s)
    ctx.strokePath()

    // Lente: anel externo, anel interno e miolo, como o ícone de lente do app.
    let center = CGPoint(x: 512 * s, y: 500 * s)
    func ring(_ radius: CGFloat, _ width: CGFloat, _ white: CGFloat) {
        ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.setStrokeColor(NSColor(calibratedWhite: white, alpha: 1).cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }
    ring(270 * s, 34 * s, 0.86)
    ring(185 * s, 14 * s, 0.42)
    ctx.addEllipse(in: CGRect(x: center.x - 112 * s, y: center.y - 112 * s, width: 224 * s, height: 224 * s))
    ctx.setFillColor(NSColor(calibratedWhite: 0.86, alpha: 1).cgColor)
    ctx.fillPath()

    // REC: ponto vermelho do sistema no canto superior direito.
    ctx.addEllipse(in: CGRect(x: 742 * s, y: 742 * s, width: 92 * s, height: 92 * s))
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print("ícone em \(out.appendingPathComponent("AppIcon.icns").path)")
