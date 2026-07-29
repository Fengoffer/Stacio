import AppKit

enum StacioSymbolImage {
    static func image(
        named symbolName: String,
        accessibilityDescription: String?,
        size: NSSize = NSSize(width: 18, height: 18)
    ) -> NSImage? {
        if symbolName == "bluetooth" {
            return bluetoothImage(size: size, accessibilityDescription: accessibilityDescription)
        }
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        ) else {
            return nil
        }
        image.size = size
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func bluetoothImage(
        size: NSSize,
        accessibilityDescription: String?
    ) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let scale = min(
                max(1, rect.width - 4) / 10,
                max(1, rect.height - 4) / 20
            )
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(
                    x: rect.midX + (x - 12) * scale,
                    y: rect.midY + (y - 12) * scale
                )
            }

            let path = NSBezierPath()
            path.move(to: point(7, 7))
            path.line(to: point(17, 17))
            path.line(to: point(12, 22))
            path.line(to: point(12, 2))
            path.line(to: point(17, 7))
            path.line(to: point(7, 17))
            path.lineWidth = max(1.25, 2 * scale)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
