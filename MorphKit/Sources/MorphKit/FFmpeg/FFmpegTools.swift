import Foundation
import Synchronization

/// Paths to the ffmpeg/ffprobe executables Morph uses.
public struct FFmpegTools: Sendable, Hashable {
    public let ffmpeg: URL
    public let ffprobe: URL
    /// True when the binaries ship inside the app bundle (release configuration).
    public let isBundled: Bool

    public init(ffmpeg: URL, ffprobe: URL, isBundled: Bool) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.isBundled = isBundled
    }

    /// Finds ffmpeg in this order: app bundle, `MORPH_FFMPEG_PATH`, extra search directories,
    /// then (debug builds only) Homebrew.
    public static func locate(bundle: Bundle = .main, extraDirectories: [URL] = []) -> FFmpegTools? {
        let fm = FileManager.default
        func tools(in dir: URL, bundled: Bool) -> FFmpegTools? {
            let ffmpeg = dir.appending(path: "ffmpeg"), ffprobe = dir.appending(path: "ffprobe")
            guard fm.isExecutableFile(atPath: ffmpeg.path), fm.isExecutableFile(atPath: ffprobe.path) else {
                return nil
            }
            return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe, isBundled: bundled)
        }

        if let ffmpeg = bundle.url(forAuxiliaryExecutable: "ffmpeg"),
           let found = tools(in: ffmpeg.deletingLastPathComponent(), bundled: true) {
            return found
        }
        if let override = ProcessInfo.processInfo.environment["MORPH_FFMPEG_PATH"], !override.isEmpty {
            var url = URL(filePath: override)
            if url.lastPathComponent == "ffmpeg" { url.deleteLastPathComponent() }
            if let found = tools(in: url, bundled: false) { return found }
        }
        for dir in extraDirectories {
            if let found = tools(in: dir, bundled: false) { return found }
        }
        #if DEBUG
        for path in ["/opt/homebrew/bin", "/usr/local/bin"] {
            if let found = tools(in: URL(filePath: path), bundled: false) { return found }
        }
        #endif
        return nil
    }
}

/// What a particular ffmpeg binary supports. Used to hide outputs it can't produce.
public struct FFmpegCapabilities: Sendable, Hashable {
    public let version: String
    public let encoders: Set<String>
    public let filters: Set<String>

    public init(version: String, encoders: Set<String>, filters: Set<String>) {
        self.version = version
        self.encoders = encoders
        self.filters = filters
    }

    public func hasEncoder(_ name: String) -> Bool { encoders.contains(name) }
    public func hasFilter(_ name: String) -> Bool { filters.contains(name) }

    /// Major version, e.g. 9 for "9.0.1".
    public var majorVersion: Int {
        let digits = version.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static let cache = Mutex<[URL: FFmpegCapabilities]>([:])

    /// Queries (and caches) the capabilities of an ffmpeg binary.
    public static func load(for tools: FFmpegTools) async throws -> FFmpegCapabilities {
        if let cached = cache.withLock({ $0[tools.ffmpeg] }) { return cached }

        async let versionOut = ChildProcess.run(tools.ffmpeg, arguments: ["-hide_banner", "-version"])
        async let encodersOut = ChildProcess.run(tools.ffmpeg, arguments: ["-hide_banner", "-encoders"])
        async let filtersOut = ChildProcess.run(tools.ffmpeg, arguments: ["-hide_banner", "-filters"])
        let (v, e, f) = try await (versionOut, encodersOut, filtersOut)

        let firstLine = v.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
        // "ffmpeg version 9.0.1-https://… Copyright …" → "9.0.1"
        let version = firstLine.split(separator: " ").dropFirst(2).first.map {
            String($0.prefix { $0.isNumber || $0 == "." })
        } ?? "unknown"

        let caps = FFmpegCapabilities(
            version: version,
            encoders: parseList(e.stdoutText),
            filters: parseList(f.stdoutText)
        )
        cache.withLock { $0[tools.ffmpeg] = caps }
        return caps
    }

    /// Parses the name column from `-encoders` / `-filters` listings (" V....D libx264  …").
    static func parseList(_ text: String) -> Set<String> {
        var names = Set<String>()
        var pastHeader = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix(" ---") || line.hasPrefix(" ------") {
                pastHeader = true
                continue
            }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            // Encoder lines: flags + name. Filter lines: flags + name + type.
            let flags = fields[0]
            let isFlags = flags.allSatisfy { "VASFXBTDCN.|".contains($0) }
            if isFlags && (pastHeader || flags.count >= 2) {
                names.insert(String(fields[1]))
            }
        }
        return names
    }
}
