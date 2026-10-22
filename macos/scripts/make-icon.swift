// Gera o ícone da app (PNG 1024×1024): squircle em gradiente com o glifo SF Symbols.
// Uso: swift scripts/make-icon.swift <saida.png>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // Margem do grid de ícones do macOS (824 px de corpo em 1024).
    let body = rect.insetBy(dx: 100, dy: 100)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.70, green: 0.33, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.38, green: 0.36, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.45, blue: 0.98, alpha: 1),
    ])!.draw(in: path, angle: -60)

    // Brilho suave no topo.
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "point.3.filled.connected.trianglepath.dotted",
                            accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 - 8,
                               width: s.width, height: s.height))
    }

    // Ponto verde de estado, como na barra de menus.
    let dot = NSRect(x: body.maxX - 250, y: body.minY + 90, width: 150, height: 150)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -18, dy: -18)).fill()
    NSColor.systemGreen.setFill()
    NSBezierPath(ovalIn: dot).fill()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("não consegui gerar o PNG")
}
try png.write(to: URL(fileURLWithPath: output))
