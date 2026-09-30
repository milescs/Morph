import AppKit
import MorphKit

/// Builds diagnostics for a problem and opens a pre-filled GitHub issue. Nothing is sent by Morph:
/// people see everything on GitHub before submitting. File names and paths are never included.
enum ProblemReport {
    static let repository = URL(string: "https://github.com/milescs/Morph")!

    struct Context {
        var item: MediaItem?
        var settings: ConversionSettings?
        var message: String
        var suggestion: String?
        var log: String?
    }

    // MARK: Actions

    static func open(_ context: Context) {
        let title = "Conversion failed: \(context.message.prefix(80))"
        NSWorkspace.shared.open(issueURL(template: "bug_report.yml", title: title, diagnostics: diagnostics(context)))
    }

    /// Help › Report a Problem (no particular file).
    static func openGeneral() {
        NSWorkspace.shared.open(issueURL(template: "bug_report.yml", title: nil, diagnostics: systemSummary()))
    }

    static func openFeatureRequest() {
        NSWorkspace.shared.open(issueURL(template: "feature_request.yml", title: nil, diagnostics: nil))
    }

    static func copy(_ context: Context) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(context), forType: .string)
    }

    static func issueURL(template: String, title: String?, diagnostics: String?) -> URL {
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        var items = [("template", template)]
        if let title { items.append(("title", title)) }
        // GitHub fills issue-form fields from query parameters named after their ids.
        if let diagnostics { items.append(("diagnostics", String(diagnostics.prefix(5_000)))) }
        // Encode "+", "&" and "=" too, so values like "+102%" survive.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        components.percentEncodedQueryItems = items.map { name, value in
            URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url ?? repository
    }

    // MARK: Diagnostics

    static func diagnostics(_ context: Context) -> String {
        var lines = [systemSummary(), ""]
        if let item = context.item { lines.append("Input: " + describe(item)) }
        if let settings = context.settings, let item = context.item {
            lines.append("Output: " + describe(settings, for: item))
        }
        lines.append("Error: " + redact(context.message, item: context.item))
        if let suggestion = context.suggestion { lines.append("Suggestion shown: " + suggestion) }
        if let log = context.log, !log.isEmpty {
            let tail = log.split(separator: "\n", omittingEmptySubsequences: true).suffix(30).joined(separator: "\n")
            lines += ["", "FFmpeg log (last lines, paths removed):", redact(String(tail.suffix(2_500)), item: context.item)]
        }
        return lines.joined(separator: "\n")
    }

    static func systemSummary() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let caps = SystemCapabilities.current
        var line = "Morph \(version) (\(build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        line += " · \(modelIdentifier()) · \(caps.chipName.isEmpty ? "Apple silicon" : caps.chipName)"
        let model = AppModel.shared
        if let ffmpeg = model.capabilities {
            line += "\nFFmpeg \(ffmpeg.version) (\(model.tools?.isBundled == true ? "bundled" : "development"))"
        }
        return line
    }

    static func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func describe(_ item: MediaItem) -> String {
        var parts = [item.kind.singularName.lowercased(), item.format.displayName]
        switch item.info {
        case .image(let image)?:
            parts.append("\(image.width)×\(image.height)")
            if image.isAnimated { parts.append("\(image.frameCount) frames") }
            if image.hasAlpha { parts.append("alpha") }
            if image.bitsPerComponent > 8 { parts.append("\(image.bitsPerComponent)-bit") }
            if image.isHDR { parts.append("HDR") }
        case .media(let media)?:
            parts.append("container \(media.formatName)")
            if let video = media.video {
                var text = "\(video.codec) \(video.width)×\(video.height)"
                if video.rotation != 0 { text += " rotated \(video.rotation)°" }
                text += String(format: " %.3g fps", video.frameRate)
                if let pixelFormat = video.pixelFormat { text += " \(pixelFormat)" }
                if let transfer = video.colorTransfer { text += " \(transfer)" }
                if let profile = video.profile { text += " (\(profile))" }
                parts.append(text)
            }
            if let audio = media.audio {
                parts.append("\(audio.codec) \(audio.channels) ch \(audio.sampleRate / 1000) kHz")
            }
            if media.audioStreamCount > 1 { parts.append("\(media.audioStreamCount) audio tracks") }
            parts.append(String(format: "%.1f s", media.duration))
        case .pdf(let pdf)?:
            parts.append("\(pdf.pageCount) pages")
        case nil:
            parts.append("not readable")
        }
        parts.append(sizeBucket(item.fileSize))
        return parts.joined(separator: " · ")
    }

    static func describe(_ settings: ConversionSettings, for item: MediaItem) -> String {
        var parts = ["\(settings.target.displayName) (\(settings.target.rawValue))"]
        switch settings.sliderDomain(for: item) {
        case .image:
            let o = settings.image
            parts.append("quality \(Int((o.quality * 100).rounded()))")
            if let limit = o.sizeLimit { parts.append("limit \(Formatters.bytes(limit))") }
            if o.resize != .none { parts.append("resize \(o.resize)") }
            if o.lossless { parts.append("lossless") }
            if o.colorProfile != .keep { parts.append("color \(o.colorProfile.rawValue)") }
            parts.append("metadata \(o.metadata.rawValue)")
        case .video:
            let o = settings.video
            parts.append("quality \(Int((o.quality * 100).rounded()))")
            if let limit = o.sizeLimit { parts.append("limit \(Formatters.bytes(limit))") }
            if let encoder = o.encoder { parts.append("encoder \(encoder.rawValue)") }
            if let container = o.container { parts.append("container \(container.rawValue)") }
            if o.rateControl != .automatic { parts.append("rate \(o.rateControl.rawValue)") }
            if o.resolution != .original { parts.append("resolution \(o.resolution.displayName)") }
            if o.frameRate != .original { parts.append("fps \(o.frameRate.displayName)") }
            if o.hdr != .automatic { parts.append("HDR \(o.hdr.rawValue)") }
            if o.trim != nil { parts.append("trimmed") }
            if !o.audio.enabled { parts.append("no audio") }
            if !o.customArguments.isEmpty { parts.append("custom arguments: \(o.customArguments)") }
        case .audio:
            let o = settings.audio
            parts.append("quality \(Int((o.quality * 100).rounded()))")
            if let limit = o.sizeLimit { parts.append("limit \(Formatters.bytes(limit))") }
            if let kbps = o.bitrateKbps { parts.append("\(kbps) kbps") }
            if o.normalizeLoudness { parts.append("loudness normalization") }
            if !o.customArguments.isEmpty { parts.append("custom arguments: \(o.customArguments)") }
        }
        return parts.joined(separator: " · ")
    }

    static func sizeBucket(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1_000_000: "under 1 MB"
        case ..<10_000_000: "1–10 MB"
        case ..<100_000_000: "10–100 MB"
        case ..<1_000_000_000: "100 MB–1 GB"
        default: "over 1 GB"
        }
    }

    /// Removes paths, the file name and the user name.
    static func redact(_ text: String, item: MediaItem?) -> String {
        var result = text
        if let item {
            result = result.replacingOccurrences(of: item.url.path, with: "<input>")
            result = result.replacingOccurrences(of: item.url.lastPathComponent, with: "<file>")
            result = result.replacingOccurrences(of: item.baseName, with: "<name>")
        }
        result = result.replacingOccurrences(of: #"(/Users|/Volumes|/private|/var/folders|/tmp|~)/[^\s'"]+"#,
                                             with: "<path>", options: .regularExpression)
        if NSUserName().count >= 3 { result = result.replacingOccurrences(of: NSUserName(), with: "<user>") }
        return result
    }
}
