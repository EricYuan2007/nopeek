#!/usr/bin/env swift
// NoPeek app icon generator — draws the icon programmatically (no asset deps) and
// emits a full .iconset; `make icon` then runs iconutil to produce the .icns.
//
// Design: macOS squircle, blue→violet night gradient; the product's floating-bubble
// ring (mint) around a stylized eye (the owner), with a small red "intruder" dot
// riding the ring at 2 o'clock — the whole detection story in one glyph.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

func drawIcon(size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = 0.055 * s
        let iconRect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let center = NSPoint(x: s / 2, y: s / 2)

        // Squircle-ish background (continuous-corner look via large radius).
        let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 0.24 * iconRect.width,
                                    yRadius: 0.24 * iconRect.width)
        NSGradient(colors: [rgb(0x3B82F6), rgb(0x6D3FE0)], atLocations: [0, 1],
                   colorSpace: .deviceRGB)?
            .draw(in: squircle, angle: -55)
        // Soft top sheen for depth.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), .clear], atLocations: [0, 1],
                   colorSpace: .deviceRGB)?
            .draw(in: NSBezierPath(roundedRect: NSRect(x: iconRect.minX, y: iconRect.midY,
                                                       width: iconRect.width, height: iconRect.height / 2),
                                   xRadius: 0.24 * iconRect.width, yRadius: 0.24 * iconRect.width),
                  angle: -90)

        // Bubble ring (state ring from the floating bubble).
        let ringRadius = 0.30 * s
        let mint = rgb(0x3DDC97)
        mint.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                               width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = 0.045 * s
        ring.stroke()

        // Eye: symmetric almond via two quadratic arcs.
        let eyeW = 0.46 * s
        let eyeH = 0.26 * s
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: center.x - eyeW / 2, y: center.y))
        eye.curve(to: NSPoint(x: center.x + eyeW / 2, y: center.y),
                  controlPoint: NSPoint(x: center.x, y: center.y + eyeH))
        eye.curve(to: NSPoint(x: center.x - eyeW / 2, y: center.y),
                  controlPoint: NSPoint(x: center.x, y: center.y - eyeH))
        eye.close()
        NSColor.white.withAlphaComponent(0.96).setFill()
        eye.fill()

        // Iris + pupil + highlight.
        let irisR = 0.088 * s
        mint.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - irisR, y: center.y - irisR,
                                    width: irisR * 2, height: irisR * 2)).fill()
        let pupilR = 0.045 * s
        rgb(0x101827).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - pupilR, y: center.y - pupilR,
                                    width: pupilR * 2, height: pupilR * 2)).fill()
        let hiR = 0.016 * s
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x + 0.03 * s - hiR, y: center.y + 0.035 * s - hiR,
                                    width: hiR * 2, height: hiR * 2)).fill()

        // Intruder dot riding the ring at ~2 o'clock.
        let dotR = 0.058 * s
        let angle = CGFloat.pi / 4
        let dotCenter = NSPoint(x: center.x + cos(angle) * ringRadius,
                                y: center.y + sin(angle) * ringRadius)
        let dotRect = NSRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR,
                             width: dotR * 2, height: dotR * 2)
        NSColor.white.setStroke()
        let dot = NSBezierPath(ovalIn: dotRect)
        dot.lineWidth = 0.018 * s
        rgb(0xFF453A).setFill()
        dot.fill()
        dot.stroke()
        return true
    }
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, size) in sizes {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("iconset written to \(outDir)")
