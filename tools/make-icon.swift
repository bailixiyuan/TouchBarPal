#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift <output.icns>
//
import AppKit

func drawIcon(size px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(px)
    let full = NSRect(x: 0, y: 0, width: s, height: s)

    NSColor.clear.setFill()
    full.fill()

    let inset = s * 0.085
    let rect = full.insetBy(dx: inset, dy: inset)
    let radius = s * 0.20
    let rounded = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    NSColor.black.setFill()
    rounded.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Deep indigo base.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.07, green: 0.06, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 0.17, green: 0.11, blue: 0.34, alpha: 1)
    ])!
    gradient.draw(in: rounded, angle: -68)

    // Soft violet glow behind the clipboard.
    let glowRect = NSRect(
        x: rect.minX - rect.width * 0.10,
        y: rect.minY + rect.height * 0.28,
        width: rect.width * 0.95,
        height: rect.height * 0.82
    )
    NSGraphicsContext.saveGraphicsState()
    rounded.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.58, green: 0.38, blue: 1.0, alpha: 0.38),
        NSColor(srgbRed: 0.58, green: 0.38, blue: 1.0, alpha: 0)
    ])?.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()

    // Rounded square frame.
    let frameSize = rect.width * 0.56
    let frameRect = NSRect(
        x: rect.midX - frameSize / 2,
        y: rect.midY - frameSize / 2 + rect.height * 0.015,
        width: frameSize,
        height: frameSize
    )
    let frame = NSBezierPath(
        roundedRect: frameRect,
        xRadius: frameSize * 0.28,
        yRadius: frameSize * 0.28
    )
    frame.lineWidth = s * 0.032
    frame.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    frame.stroke()

    // Hammer glyph.
    let configuration = NSImage.SymbolConfiguration(pointSize: s * 0.26, weight: .semibold)

    func drawSymbol(_ name: String, in frame: NSRect) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }

        let tinted = NSImage(size: base.size, flipped: false) { bounds in
            base.draw(in: bounds)
            NSColor.white.setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }

        let scale = min(frame.width / max(tinted.size.width, 1),
                        frame.height / max(tinted.size.height, 1))
        let destination = NSRect(
            x: frame.midX - tinted.size.width * scale / 2,
            y: frame.midY - tinted.size.height * scale / 2,
            width: tinted.size.width * scale,
            height: tinted.size.height * scale
        )
        tinted.draw(in: destination)
    }

    drawSymbol("hammer.fill", in: frameRect.insetBy(dx: frameSize * 0.17, dy: frameSize * 0.17))

    // Inner highlight border.
    let border = NSBezierPath(
        roundedRect: rect.insetBy(dx: s * 0.004, dy: s * 0.004),
        xRadius: radius,
        yRadius: radius
    )
    NSColor.white.withAlphaComponent(0.14).setStroke()
    border.lineWidth = s * 0.005
    border.stroke()

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Iconset

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("TouchBarPal-\(UUID().uuidString).iconset")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    guard let data = drawIcon(size: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(variant.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()

try? FileManager.default.removeItem(at: iconsetURL)

if iconutil.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("Wrote \(outputURL.path)")
