import Foundation

public enum Formatters {
    /// "3.1 MB", "640 KB" (decimal units, like Finder).
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "1:23", "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "-79%" / "+12%" relative change between two sizes.
    public static func change(from original: Int64, to new: Int64) -> String {
        guard original > 0 else { return "" }
        let factor = Double(new) / Double(original)
        if factor >= 10 { return "×\(Int(factor.rounded()))" }
        let ratio = factor - 1
        let percent = Int((ratio * 100).rounded())
        if percent == 0 { return "±0%" }
        return percent < 0 ? "−\(-percent)%" : "+\(percent)%"
    }

    /// "12 kbps" / "4.2 Mbps".
    public static func bitrate(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        return "\(bitsPerSecond / 1000) kbps"
    }

    /// "0:12.5" style timestamp used for trims.
    public static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }
}
