import Foundation

/// A problem in plain language, with what to try next.
public struct Explanation: Sendable, Equatable {
    public var message: String
    public var suggestion: String?

    public init(message: String, suggestion: String? = nil) {
        self.message = message
        self.suggestion = suggestion
    }
}

/// Turns raw FFmpeg output and system errors into messages people can act on.
public enum FriendlyErrors {
    struct Rule {
        let patterns: [String]
        let message: String
        let suggestion: String?
    }

    /// Checked in order; the first rule with a matching pattern (case-insensitive) wins.
    static let rules: [Rule] = [
        Rule(patterns: ["No space left on device", "ENOSPC", "disk is full"],
             message: "The disk is full.",
             suggestion: "Free up some space, or save to another drive."),
        Rule(patterns: ["Operation not permitted"],
             message: "macOS blocked Morph from using this location.",
             suggestion: "Allow Morph in System Settings › Privacy & Security › Files and Folders, or save somewhere else."),
        Rule(patterns: ["Permission denied", "don't have permission", "doesn’t have permission"],
             message: "Morph isn't allowed to read or write here.",
             suggestion: "Choose another folder, or check the permissions in Finder › Get Info."),
        Rule(patterns: ["Read-only file system"],
             message: "This drive is read-only.",
             suggestion: "Save the converted files to another folder."),
        Rule(patterns: ["moov atom not found"],
             message: "This video is incomplete. The recording or download probably didn't finish.",
             suggestion: "Try a complete copy of the file."),
        Rule(patterns: ["No such file or directory"],
             message: "The file was moved, renamed or deleted.",
             suggestion: "Add it to Morph again."),
        Rule(patterns: ["password-protected", "is encrypted"],
             message: "This PDF is password-protected.",
             suggestion: "Open it in Preview, choose File › Export, turn off Encrypt, then convert the exported copy."),
        Rule(patterns: ["Could not find tag for codec", "not currently supported in container",
                        "codec not currently supported"],
             message: "The chosen format can't hold this file's audio or video.",
             suggestion: "Pick MP4 or MKV, or choose another audio codec in Pro mode."),
        Rule(patterns: ["Decoder (codec", "no decoder found", "Unknown decoder", "Could not find codec parameters",
                        "Unsupported codec", "unsupported codec", "Unknown codec"],
             message: "Morph can't read the {codec}audio or video inside this file.",
             suggestion: "It may use a rare or proprietary codec. Try exporting it again from the app that made it."),
        Rule(patterns: ["Decode error rate", "missing picture in access unit", "Invalid NAL unit size",
                        "error code: -1145393733"],
             message: "Parts of this video are damaged, so it can't be read.",
             suggestion: "If it plays in another app, use Report a Problem so Morph can learn to read it."),
        Rule(patterns: ["width not divisible by 2", "height not divisible by 2", "not divisible by 2"],
             message: "This video has odd dimensions the encoder can't use.",
             suggestion: "Pick a resolution in Pro mode."),
        Rule(patterns: ["videotoolbox", "VTCompressionSession", "kVTVideoEncoder", "compression session",
                        "hardware encoder"],
             message: "Your Mac's hardware video encoder couldn't handle this video.",
             suggestion: "Try a lower resolution, or pick a software encoder (x264 or x265) in Pro mode."),
        Rule(patterns: ["Cannot allocate memory", "Out of memory", "ENOMEM"],
             message: "Your Mac ran out of memory for this file.",
             suggestion: "Close other apps, or lower Parallel conversions in Settings › Performance."),
        Rule(patterns: ["Error opening output file", "Error opening output files", "Could not open file",
                        "Unable to choose an output format", "Couldn't save"],
             message: "Morph couldn't create the converted file.",
             suggestion: "Check that the folder still exists and that you can save files in it."),
        Rule(patterns: ["Output file does not contain any stream", "does not contain any stream", "matches no streams"],
             message: "There's nothing to convert: no usable audio or video was found.",
             suggestion: nil),
        Rule(patterns: ["Unrecognized option", "Option not found", "Error parsing options", "Invalid option"],
             message: "One of the custom FFmpeg arguments isn't valid.",
             suggestion: "Check Custom arguments in Pro mode."),
        Rule(patterns: ["Error while opening encoder", "Error initializing output stream",
                        "Could not open encoder before EOF", "Error setting option", "incorrect parameters"],
             message: "The encoder rejected these settings.",
             suggestion: "Try another format, or undo custom Pro options like resolution, bitrate or frame rate."),
        Rule(patterns: ["Too many packets buffered"],
             message: "This file's audio and video are badly out of sync.",
             suggestion: "Try converting without audio (Pro mode › Audio)."),
        Rule(patterns: ["Invalid data found when processing input", "Invalid NAL unit", "error while decoding",
                        "corrupt", "Invalid frame dimensions", "EBML header parsing failed", "Header missing",
                        "End of file", "damaged"],
             message: "The file is damaged, or it isn't really the format its name says.",
             suggestion: "If it opens in another app, use Report a Problem so Morph can learn to read it."),
    ]

    /// Explains an FFmpeg/ffprobe failure from its stderr log.
    public static func explain(ffmpegLog log: String, exitStatus: Int32? = nil) -> Explanation {
        if let rule = rules.first(where: { rule in rule.patterns.contains { log.localizedCaseInsensitiveContains($0) } }) {
            return Explanation(message: fill(rule.message, log: log), suggestion: rule.suggestion)
        }
        if let line = lastMeaningfulLine(log) {
            return Explanation(message: "FFmpeg stopped with an error: \(line)",
                               suggestion: "Use Report a Problem to send the details.")
        }
        let status = exitStatus.map { " (exit status \($0))" } ?? ""
        return Explanation(message: "FFmpeg stopped unexpectedly\(status).",
                           suggestion: "Use Report a Problem to send the details.")
    }

    /// Explains any error Morph can throw.
    public static func explain(_ error: any Error) -> Explanation {
        if let error = error as? FFmpegError {
            return Explanation(message: error.message, suggestion: error.suggestion)
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileWriteOutOfSpace: return explain(text: "No space left on device")
            case .fileWriteNoPermission, .fileReadNoPermission: return explain(text: "Permission denied")
            case .fileNoSuchFile, .fileReadNoSuchFile: return explain(text: "No such file or directory")
            case .fileWriteVolumeReadOnly: return explain(text: "Read-only file system")
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch POSIXErrorCode(rawValue: Int32(nsError.code)) {
            case .ENOSPC: return explain(text: "No space left on device")
            case .EACCES: return explain(text: "Permission denied")
            case .EPERM: return explain(text: "Operation not permitted")
            case .ENOENT: return explain(text: "No such file or directory")
            case .EROFS: return explain(text: "Read-only file system")
            case .ENOMEM: return explain(text: "Cannot allocate memory")
            default: break
            }
        }
        let text = error.localizedDescription
        // Messages that already came from a rule (e.g. a probe failure) keep that rule's advice.
        let rule = rules.first { rule in
            let fixed = rule.message.components(separatedBy: "{codec}")[0]
            return text == rule.message || (!fixed.isEmpty && rule.message.contains("{codec}") && text.hasPrefix(fixed))
        } ?? rules.first { rule in rule.patterns.contains { text.localizedCaseInsensitiveContains($0) } }
        if isOwnMessage(error) {
            // Morph's own messages are already plain language; only add advice.
            return Explanation(message: text, suggestion: rule?.suggestion)
        }
        if let rule { return Explanation(message: fill(rule.message, log: text), suggestion: rule.suggestion) }
        return Explanation(message: text, suggestion: nil)
    }

    static func explain(text: String) -> Explanation {
        let rule = rules.first { $0.patterns.contains { text.localizedCaseInsensitiveContains($0) } }!
        return Explanation(message: rule.message, suggestion: rule.suggestion)
    }

    static func isOwnMessage(_ error: any Error) -> Bool {
        error is ImageEngineError || error is MediaPlanError || error is ProbeError || error is WriteError
    }

    /// Fills "{codec}" with the codec name FFmpeg reported, if any.
    static func fill(_ message: String, log: String) -> String {
        guard message.contains("{codec}") else { return message }
        let patterns = [#"Decoder \(codec ([A-Za-z0-9_\-]+)\)"#, #"no decoder found for:? ([A-Za-z0-9_\-]+)"#,
                        #"Unknown decoder '([A-Za-z0-9_\-]+)'"#, #"[Uu]nsupported codec[^A-Za-z0-9]+([A-Za-z0-9_\-]+)"#]
        for pattern in patterns {
            if let match = log.range(of: pattern, options: .regularExpression) {
                let text = String(log[match])
                if let name = text.split(whereSeparator: { " ()':".contains($0) }).last, name.count < 24 {
                    return message.replacingOccurrences(of: "{codec}", with: "\(name) ")
                }
            }
        }
        return message.replacingOccurrences(of: "{codec}", with: "")
    }

    /// The last log line that says something (without "[tag @ 0x…]" prefixes).
    static func lastMeaningfulLine(_ log: String) -> String? {
        let boring = ["Conversion failed!", "Exiting normally", "Terminating thread", "received signal"]
        for raw in log.split(separator: "\n").reversed() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: #"^\[[^\]]*\]\s*"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            if line.isEmpty || boring.contains(where: { line.contains($0) }) { continue }
            return String(line.prefix(200))
        }
        return nil
    }
}
