import AppKit

/// Morph's menu bar glyphs, drawn as crisp template images (macOS tints them for the menu bar).
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    /// Idle mark: an outlined rounded square morphing into a solid circle.
    static let idle: NSImage = {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let square = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 8.25, width: 8, height: 8), xRadius: 1.8, yRadius: 1.8)
            square.lineWidth = 1.5
            square.stroke()
            NSBezierPath(ovalIn: NSRect(x: 8.25, y: 1.25, width: 8.5, height: 8.5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Morph"
        return image
    }()

    /// Highlighted variant shown while files are dragged over the icon.
    static let dropTarget: NSImage = {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let tray = NSBezierPath()
            tray.move(to: NSPoint(x: 2, y: 10))
            tray.line(to: NSPoint(x: 2, y: 15.5))
            tray.line(to: NSPoint(x: 16, y: 15.5))
            tray.line(to: NSPoint(x: 16, y: 10))
            tray.lineWidth = 1.6
            tray.lineCapStyle = .round
            tray.lineJoinStyle = .round
            tray.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 9, y: 1.5))
            arrow.line(to: NSPoint(x: 9, y: 11))
            arrow.move(to: NSPoint(x: 5.5, y: 7.5))
            arrow.line(to: NSPoint(x: 9, y: 11))
            arrow.line(to: NSPoint(x: 12.5, y: 7.5))
            arrow.lineWidth = 1.6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Frames of the "working" animation: a square that turns and rounds into a filled circle and back.
    static let workingFrames: [NSImage] = {
        let steps = 16
        return (0..<steps).map { index in
            // 0 → 1 → 0 with ease-in-out.
            let phase = Double(index) / Double(steps)
            let t = CGFloat((1 - cos(phase * 2 * .pi)) / 2)
            return frame(t)
        }
    }()

    static func frame(_ t: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            let side = 11 + 2.5 * t
            let rect = NSRect(x: (18 - side) / 2, y: (18 - side) / 2, width: side, height: side)
            let radius = 2 + (side / 2 - 2) * t
            let transform = NSAffineTransform()
            transform.translateX(by: 9, yBy: 9)
            transform.rotate(byDegrees: 90 * t)
            transform.translateX(by: -9, yBy: -9)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.transform(using: transform as AffineTransform)
            NSColor.black.withAlphaComponent(t).setFill()
            path.fill()
            NSColor.black.setStroke()
            path.lineWidth = 1.6
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
