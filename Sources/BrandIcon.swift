import AppKit

/// Monochrome menu bar / Control Strip mark, drawn as a template image so it
/// adapts to the menu bar appearance.
///
/// The mark is a hammer inside a rounded square.
enum BrandIcon {
    static func template(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let unit = size / 18

            let frame = NSBezierPath(
                roundedRect: NSRect(x: 2.6 * unit, y: 2.6 * unit, width: 12.8 * unit, height: 12.8 * unit),
                xRadius: 3.2 * unit,
                yRadius: 3.2 * unit
            )
            frame.lineWidth = 1.35 * unit
            frame.lineJoinStyle = .round
            NSColor.black.setStroke()
            frame.stroke()

            guard let hammer = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9.5 * unit, weight: .semibold)) else {
                return true
            }
            let tinted = NSImage(size: hammer.size, flipped: false) { bounds in
                hammer.draw(in: bounds)
                NSColor.black.setFill()
                bounds.fill(using: .sourceAtop)
                return true
            }
            let target = NSRect(
                x: (9 - hammer.size.width / unit / 2) * unit,
                y: (8.6 - hammer.size.height / unit / 2) * unit,
                width: hammer.size.width,
                height: hammer.size.height
            )
            tinted.draw(in: target)
            return true
        }
        image.isTemplate = true
        return image
    }
}
