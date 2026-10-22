// Gera o fundo da janela do .dmg (660×420 pt) em 1x e 2x.
// Uso: swift scripts/make-dmg-background.swift <pasta-de-saida>
// As posições dos ícones (170,215) e (490,215) têm de bater com as do build.sh.
import AppKit

let outDir = CommandLine.arguments.dropFirst().first ?? "."
let width: CGFloat = 660
let height: CGFloat = 420

let purple = NSColor(srgbRed: 0.38, green: 0.36, blue: 0.98, alpha: 1)
let violet = NSColor(srgbRed: 0.70, green: 0.33, blue: 0.95, alpha: 1)

/// Coordenadas do Finder (origem no topo) → AppKit (origem em baixo).
func y(_ top: CGFloat) -> CGFloat { height - top }

func centered(_ text: String, top: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: (width - size.width) / 2, y: y(top) - size.height), withAttributes: attrs)
}

func draw() {
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [
        NSColor(srgbRed: 0.975, green: 0.970, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.925, green: 0.915, blue: 0.985, alpha: 1),
    ])!.draw(in: rect, angle: -90)

    // Brilhos difusos da marca nos cantos.
    for (center, color) in [(NSPoint(x: 40, y: y(30)), violet), (NSPoint(x: width - 30, y: y(400)), purple)] {
        NSGradient(colors: [color.withAlphaComponent(0.16), color.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: 260, options: [])
    }

    // Cabeçalho: selo com o glifo + título.
    let badge = NSRect(x: width / 2 - 118, y: y(64), width: 34, height: 34)
    let badgePath = NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9)
    NSGradient(colors: [violet, purple])!.draw(in: badgePath, angle: -60)
    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "point.3.filled.connected.trianglepath.dotted",
                           accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = glyph.size
        glyph.draw(in: NSRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
    }
    let title: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.13, green: 0.12, blue: 0.22, alpha: 1),
    ]
    ("MCP Indicator" as NSString).draw(at: NSPoint(x: badge.maxX + 12, y: badge.minY + 2), withAttributes: title)

    centered("Arraste para a pasta Aplicações para instalar", top: 80,
             font: .systemFont(ofSize: 13, weight: .regular),
             color: NSColor(srgbRed: 0.35, green: 0.34, blue: 0.45, alpha: 1))

    // "Pousos" suaves por baixo dos dois ícones.
    for x in [170.0, 490.0] {
        let slot = NSRect(x: x - 84, y: y(300), width: 168, height: 168)
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: slot, xRadius: 28, yRadius: 28).fill()
        NSColor(srgbRed: 0.38, green: 0.36, blue: 0.98, alpha: 0.12).setStroke()
        let border = NSBezierPath(roundedRect: slot.insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
        border.lineWidth = 1
        border.stroke()
    }

    // Seta tracejada com a cor da marca.
    let arrowY = y(206)
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 272, y: arrowY))
    shaft.curve(to: NSPoint(x: 384, y: arrowY),
                controlPoint1: NSPoint(x: 305, y: arrowY + 22),
                controlPoint2: NSPoint(x: 351, y: arrowY + 22))
    shaft.lineWidth = 4
    shaft.lineCapStyle = .round
    shaft.setLineDash([2, 9], count: 2, phase: 0)
    purple.withAlphaComponent(0.85).setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 376, y: arrowY + 11))
    head.line(to: NSPoint(x: 389, y: arrowY - 1))
    head.line(to: NSPoint(x: 373, y: arrowY - 7))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    centered("Na primeira abertura: clique direito na app → Abrir", top: 352,
             font: .systemFont(ofSize: 11, weight: .medium),
             color: NSColor(srgbRed: 0.45, green: 0.44, blue: 0.55, alpha: 1))
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: URL(fileURLWithPath: "\(outDir)/background.png"))
try render(scale: 2).write(to: URL(fileURLWithPath: "\(outDir)/background@2x.png"))
