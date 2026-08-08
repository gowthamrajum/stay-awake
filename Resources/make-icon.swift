// Generates Resources/AppIcon.icns from code, so the icon is source rather than
// an opaque binary someone has to open Photoshop to change.
//
//   swift Resources/make-icon.swift && iconutil -c icns build/AppIcon.iconset \
//       -o Resources/AppIcon.icns
//
// The artwork: a warm bulb still burning against a deep indigo night — the Mac
// that stays lit while everything else goes dark. The glyph is SF Symbols'
// `lightbulb.fill`, the same shape the menu bar shows, so the two read as one
// app at every size.

import AppKit

// MARK: - Palette

private struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    var color: NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
}

private let nightTop = RGB(r: 78, g: 92, b: 168)     // indigo, lit from above
private let nightBottom = RGB(r: 22, g: 26, b: 54)   // near-black navy
private let glowWarm = RGB(r: 255, g: 214, b: 107)   // lamp glow
private let bulbCore = RGB(r: 255, g: 249, b: 226)   // hot filament white

// MARK: - Shape

/// Apple-style squircle. A superellipse (n≈5) rather than a rounded rect —
/// the corners flow into the edges instead of meeting them at a visible seam,
/// which is the whole reason macOS icons look softer than a CSS border-radius.
private func squircle(in rect: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720

    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        // Superellipse in parametric form; the copysign keeps all four quadrants.
        let x = cx + a * CGFloat(copysign(pow(abs(Double(ct)), 2.0 / Double(n)), Double(ct)))
        let y = cy + b * CGFloat(copysign(pow(abs(Double(st)), 2.0 / Double(n)), Double(st)))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

// MARK: - Drawing

private func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icons do not fill their canvas — the art sits inset, leaving room
    // for the shadow and matching the optical size of every stock icon.
    let inset = size * 0.0975
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = squircle(in: plate)

    // Drop shadow, skipped at the small sizes where it just muddies the edge.
    if size >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.03,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.black.setFill()
        shape.fill()
        ctx.restoreGState()
    }

    // Night gradient.
    ctx.saveGState()
    shape.addClip()
    let sky = NSGradient(colors: [nightTop.color, nightBottom.color])
    sky?.draw(in: plate, angle: -90)

    // The bulb's own light spilling onto the background: a soft warm pool
    // centred a little above middle, which is what sells it as *glowing*
    // rather than as a yellow sticker pasted on a blue square.
    let glowCenter = CGPoint(x: plate.midX, y: plate.midY + plate.height * 0.06)
    let glow = NSGradient(colors: [
        glowWarm.color.withAlphaComponent(0.55),
        glowWarm.color.withAlphaComponent(0.16),
        glowWarm.color.withAlphaComponent(0.0),
    ])
    glow?.draw(fromCenter: glowCenter, radius: 0,
               toCenter: glowCenter, radius: plate.width * 0.46,
               options: [])

    // A faint top highlight, the sheen every Big Sur icon has.
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0.0),
    ])
    sheen?.draw(in: CGRect(x: plate.minX, y: plate.midY,
                           width: plate.width, height: plate.height / 2), angle: -90)
    ctx.restoreGState()

    // The bulb itself.
    let glyphSize = plate.width * 0.56
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {

        let drawn = symbol.size
        let scale = min(glyphSize / drawn.width, glyphSize / drawn.height)
        let w = drawn.width * scale, h = drawn.height * scale
        let box = CGRect(x: plate.midX - w / 2,
                         y: plate.midY - h / 2 + plate.height * 0.02,
                         width: w, height: h)

        // Tint the glyph inside its own transparent image. Compositing
        // `.sourceAtop` straight onto the icon would key off the *background's*
        // alpha, which is opaque everywhere — that paints a filled rectangle
        // instead of a bulb. In a scratch image the glyph is the only opaque
        // thing, so the gradient lands exactly on it.
        let glyph = NSImage(size: NSSize(width: w, height: h))
        glyph.lockFocus()
        let local = CGRect(x: 0, y: 0, width: w, height: h)
        symbol.draw(in: local)
        if let gctx = NSGraphicsContext.current?.cgContext {
            gctx.setBlendMode(.sourceAtop)
            // Warm at the base, near-white at the filament.
            let filament = NSGradient(colors: [glowWarm.color, bulbCore.color])
            filament?.draw(in: local, angle: 90)
        }
        glyph.unlockFocus()

        // Halo tight around the glyph, so the bulb reads as the light source.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: size * 0.05,
                      color: glowWarm.color.withAlphaComponent(0.9).cgColor)
        glyph.draw(in: box)
        ctx.restoreGState()

        glyph.draw(in: box)
    }

    image.unlockFocus()
    return image
}

// MARK: - Export

private func png(_ image: NSImage, _ pixels: Int) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    return bitmap.representation(using: .png, properties: [:])
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// The exact set `iconutil` expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    // Rendered at its final pixel size, never downscaled from one master —
    // a 16pt bulb needs its own strokes to survive, not a shrunken 1024.
    let image = drawIcon(size: CGFloat(variant.pixels))
    guard let data = png(image, variant.pixels) else {
        FileHandle.standardError.write("failed: \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent("\(variant.name).png"))
    print("  \(variant.name).png")
}

print("iconset written to \(outDir.path)")
