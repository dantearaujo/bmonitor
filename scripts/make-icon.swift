// Gera o ícone do app (AppIcon.icns) a partir das duas matrizes de 1024 px em scripts/icon/:
// AppIcon.png (a câmera de três lentes dentro dos cantos do visor, com o REC aceso) para 128 pt
// em diante, e AppIcon-small.png (só a placa e as lentes, sem os cantos, que viram ruído) para
// 16 e 32 pt. As matrizes já vêm no grid do macOS: corpo de 824 px em 1024, com sombra.
// Uso: swift scripts/make-icon.swift <pasta-de-saída>   (cria AppIcon.iconset e AppIcon.icns)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("icon")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: source.appendingPathComponent(name)) else {
        fatalError("falta \(source.appendingPathComponent(name).path)")
    }
    return image
}
let large = load("AppIcon.png")
let small = load("AppIcon-small.png")

func draw(_ image: NSImage, _ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(base <= 32 ? small : large, base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print("ícone em \(out.appendingPathComponent("AppIcon.icns").path)")
