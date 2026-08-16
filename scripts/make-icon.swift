#!/usr/bin/env swift
// NoPeek app icon generator — draws the icon programmatically (no asset deps) and
// emits a full .iconset; `make icon` then runs iconutil to produce the .icns.
//
// Design: macOS squircle, blue→violet night gradient; an abstract "privacy radar" —
// mint concentric rings (the floating-bubble motif), a sweep wedge, a solid center
// dot (you), and a red blip riding the outer ring at 2 o'clock (the intruder).
// Deliberately no literal eyeball — v1's eye design read as uncanny.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

func circle(_ center: NSPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
}

func drawIcon(size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = 0.055 * s
        let iconRect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let center = NSPoint(x: s / 2, y: s / 2)
        let mint = rgb(0x3DDC97)

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

        squircle.addClip()

        // Outer ring — the bubble's state ring.
        let outerR = 0.30 * s
        mint.setStroke()
        let outer = circle(center, outerR)
        outer.lineWidth = 0.045 * s
        outer.stroke()

        // Inner ring, whisper-thin.
        let innerR = 0.165 * s
        mint.withAlphaComponent(0.55).setStroke()
        let inner = circle(center, innerR)
        inner.lineWidth = 0.018 * s
        inner.stroke()

        // Radar sweep wedge: 75° pie fading clockwise from 2 o'clock.
        let sweep = NSBezierPath()
        sweep.move(to: center)
        sweep.appendArc(withCenter: center, radius: outerR,
                        startAngle: 45, endAngle: -30, clockwise: true)
        sweep.close()
        NSGradient(colors: [mint.withAlphaComponent(0.45), mint.withAlphaComponent(0.0)],
                   atLocations: [0, 1], colorSpace: .deviceRGB)?
            .draw(in: sweep, relativeCenterPosition: NSPoint(x: 0.5, y: 0.5))

        // Center dot — you, anchored.
        mint.setFill()
        circle(center, 0.055 * s).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        circle(center, 0.022 * s).fill()

        // Intruder blip riding the outer ring at 2 o'clock.
        let blipR = 0.056 * s
        let angle = CGFloat.pi / 4
        let blipCenter = NSPoint(x: center.x + cos(angle) * outerR,
                                 y: center.y + sin(angle) * outerR)
        let blip = circle(blipCenter, blipR)
        rgb(0xFF453A).setFill()
        blip.fill()
        NSColor.white.setStroke()
        blip.lineWidth = 0.018 * s
        blip.stroke()
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

