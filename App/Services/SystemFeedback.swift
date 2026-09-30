import AppKit
import MorphKit
import UserNotifications

/// Notifications and Dock-tile progress.
enum SystemFeedback {
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyFinished(_ summary: BatchSummary) {
        let content = UNMutableNotificationContent()
        if summary.failed > 0 {
            content.title = "Conversion finished with problems"
            content.body = "\(summary.converted) converted, \(summary.failed) failed."
        } else {
            content.title = summary.converted == 1 ? "File converted" : "\(summary.converted) files converted"
            if summary.savedBytes > 0 {
                content.body = "Saved \(Formatters.bytes(summary.savedBytes)) (\(Formatters.change(from: summary.originalBytes, to: summary.outputBytes)))."
            } else {
                content.body = "Output: \(Formatters.bytes(summary.outputBytes))."
            }
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Dock progress

    private static let progressView = DockProgressView()

    static func showDockProgress(_ fraction: Double?) {
        let tile = NSApp.dockTile
        if let fraction {
            if tile.contentView !== progressView {
                progressView.frame = NSRect(origin: .zero, size: tile.size)
                tile.contentView = progressView
            }
            progressView.fraction = fraction
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    static func setDockBadge(_ text: String?) {
        NSApp.dockTile.badgeLabel = text
    }
}

/// App icon with a slim progress bar at the bottom.
final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let barHeight = bounds.height * 0.1
        let inset = bounds.width * 0.12
        let track = NSRect(x: inset, y: bounds.height * 0.08, width: bounds.width - inset * 2, height: barHeight)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        trackPath.fill()
        var fill = track.insetBy(dx: 2, dy: 2)
        fill.size.width = max(fill.height, fill.width * min(1, max(0, fraction)))
        let fillPath = NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2)
        NSColor.controlAccentColor.setFill()
        fillPath.fill()
    }
}
