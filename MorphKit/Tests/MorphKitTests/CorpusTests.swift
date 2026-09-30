import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import MorphKit

/// Converts every file of the real-world media corpus (camera files, HDR, odd containers, scans …)
/// to its common targets and checks each output. Run with `make corpus`, which downloads the files
/// listed in Corpus/manifest.tsv and sets MORPH_CORPUS. Skipped otherwise.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MORPH_CORPUS"] != nil))
struct CorpusTests {
    struct Entry {
        let name: String
        let kind: String
        let covers: String
        var expectsFailure: Bool { covers.localizedCaseInsensitiveContains("expect-failure") }
    }

    struct Outcome {
        let file: String
        let target: String
        let ok: Bool
        let detail: String
    }

    static var directory: URL { URL(filePath: ProcessInfo.processInfo.environment["MORPH_CORPUS"] ?? "/nonexistent") }

    static func entries() throws -> [Entry] {
        let text = try String(contentsOf: directory.appending(path: "manifest.tsv"), encoding: .utf8)
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, !fields[0].isEmpty else { return nil }
            return Entry(name: fields[0], kind: fields[1], covers: fields[5])
        }
    }

    static func targets(for item: MediaItem) -> [OutputFormat] {
        switch item.kind {
        case .image:
            var list: [OutputFormat] = [.auto, .jpeg, .png, .webp, .heic]
            if ImageEngine.outputFormat(for: .original, source: item.format) != nil { list.append(.original) }
            if item.isAnimatedImage { list.append(.mp4H264) }
            return list
        case .video:
            var list: [OutputFormat] = [.mp4H264, .mp4HEVC, .original, .frameJPEG]
            // GIFs only make sense for short clips; the app warns before making one from a long video.
            if (item.info?.media?.duration ?? 0) <= 60 { list.append(.gifAnimated) }
            if item.info?.media?.audio != nil { list.append(.mp3) }
            if item.info?.media?.video == nil { list = [.mp3, .m4aAAC] }
            return list
        case .audio:
            return [.mp3, .m4aAAC, .flac, .original]
        case .pdf:
            return [.original, .png]
        }
    }

    @Test func convertsEveryCorpusFile() async throws {
        let tools = try #require(Fixtures.tools, "FFmpeg is required")
        let caps = try await FFmpegCapabilities.load(for: tools)
        let engine = FFmpegEngine(tools: tools, capabilities: caps)
        let output = FileManager.default.temporaryDirectory.appending(path: "MorphCorpus-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        var outcomes: [Outcome] = []
        func record(_ outcome: Outcome) {
            print("\(outcome.ok ? "✓" : "✗") \(outcome.file) → \(outcome.target): \(outcome.detail)")
            outcomes.append(outcome)
        }
        for entry in try Self.entries() {
            let url = Self.directory.appending(path: entry.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                record(Outcome(file: entry.name, target: "-", ok: false, detail: "missing"))
                continue
            }
            // Probe.
            guard var item = MediaProbe.item(for: url) else {
                record(Outcome(file: entry.name, target: "probe", ok: entry.expectsFailure,
                                        detail: "not recognized as media"))
                continue
            }
            do {
                item.info = try await MediaProbe.info(for: item, tools: tools)
            } catch {
                let friendly = FriendlyErrors.explain(error)
                record(Outcome(file: entry.name, target: "probe", ok: entry.expectsFailure,
                                        detail: friendly.message))
                continue
            }
            if entry.expectsFailure {
                // Damaged files may still probe; converting must then fail with a readable message.
                let result = await Self.convert(item, to: Self.targets(for: item)[0], engine: engine, in: output)
                let readable = !result.ok && !result.detail.contains("@ 0x") && result.detail.count < 200
                record(Outcome(file: entry.name, target: "expected failure", ok: result.ok || readable,
                                        detail: result.detail))
                continue
            }
            let probed = item
            for target in Self.targets(for: probed) {
                let outcome = await Self.withTimeout(seconds: 300, file: probed.name, target: target.rawValue) {
                    await Self.convert(probed, to: target, engine: engine, in: output)
                }
                record(outcome)
            }
        }

        let failures = outcomes.filter { !$0.ok }
        print("\n==== Corpus: \(outcomes.count - failures.count)/\(outcomes.count) conversions OK ====")
        for failure in failures {
            Issue.record("\(failure.file) → \(failure.target): \(failure.detail)")
        }
    }

    /// Gives up on a conversion that hangs (the task is cancelled, which stops ffmpeg).
    static func withTimeout(seconds: Double, file: String, target: String,
                            _ work: @escaping @Sendable () async -> Outcome) async -> Outcome {
        await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return Task.isCancelled ? nil : Outcome(file: file, target: target, ok: false, detail: "timed out")
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Outcome(file: file, target: target, ok: false, detail: "timed out")
        }
    }

    /// Converts one file with default settings and validates the result.
    static func convert(_ item: MediaItem, to target: OutputFormat, engine: FFmpegEngine, in folder: URL) async -> Outcome {
        let settings = ConversionSettings(target: target)
        let pipeline = ConversionPipeline(ffmpeg: engine, cache: EstimateCache())
        let ext = FormatRegistry.outputExtension(for: item, settings: settings, capabilities: engine.capabilities)
        let planner = OutputPlanner(destination: .folder(folder), template: "{name}-\(target.rawValue)",
                                    sameFormatTemplate: "{name}-\(target.rawValue)")
        let destination = planner.url(for: item, fileExtension: ext)
        let started = Date()
        do {
            let estimate = SizeEstimator.quickEstimate(item: item, settings: settings, capabilities: engine.capabilities)
            let job = ConversionJob(items: [item], settings: settings, destination: destination,
                                    page: item.kind == .pdf ? 1 : nil)
            let outcome = try await pipeline.run(job) { _, _ in }
            guard let url = outcome.output else {
                return Outcome(file: item.name, target: target.rawValue, ok: false, detail: "no output")
            }
            let check = try await validate(url, item: item, target: target, engine: engine, note: outcome.note)
            let seconds = Date().timeIntervalSince(started)
            var detail = "\(Formatters.bytes(outcome.bytes)) in \(String(format: "%.1f", seconds)) s · \(check)"
            if let estimate, outcome.bytes > 0 {
                detail += String(format: " · estimate ×%.2f", Double(estimate.bytes) / Double(outcome.bytes))
            }
            if let note = outcome.note { detail += " · note: \(note)" }
            return Outcome(file: item.name, target: target.rawValue, ok: true, detail: detail)
        } catch {
            let explanation = FriendlyErrors.explain(error)
            var detail = explanation.message
            if let ffmpeg = error as? FFmpegError {
                detail += " | " + (ffmpeg.log.split(separator: "\n").suffix(3).joined(separator: " / "))
            }
            return Outcome(file: item.name, target: target.rawValue, ok: false, detail: detail)
        }
    }

    /// The longest audio or video stream (Matroska stores it in a DURATION tag).
    static func mediaStreamDuration(_ url: URL, tools: FFmpegTools) async -> Double? {
        guard let output = try? await ChildProcess.run(tools.ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_type,duration:stream_tags=DURATION", "-of", "compact", url.path,
        ]) else { return nil }
        var longest: Double?
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n")
        where line.contains("codec_type=video") || line.contains("codec_type=audio") {
            var value: Double?
            for field in line.split(separator: "|") {
                if field.hasPrefix("duration="), let d = Double(field.dropFirst("duration=".count)) { value = d }
                if field.hasPrefix("tag:DURATION=") {
                    let parts = field.dropFirst("tag:DURATION=".count).split(separator: ":").compactMap { Double($0) }
                    if parts.count == 3 { value = parts[0] * 3600 + parts[1] * 60 + parts[2] }
                }
            }
            if let value { longest = max(longest ?? 0, value) }
        }
        return longest
    }

    struct ValidationError: LocalizedError {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { "Invalid output: \(description)" }
    }

    /// Checks that an output decodes and matches the source where it should.
    static func validate(_ url: URL, item: MediaItem, target: OutputFormat, engine: FFmpegEngine,
                         note: String?) async throws -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else { throw ValidationError("empty output") }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp", "avif", "gif", "tiff":
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ValidationError("output image doesn't decode")
            }
            // Displayed size: pixels are either rotated already or carry an EXIF orientation.
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let orientation = props[kCGImagePropertyOrientation] as? Int
                ?? (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? Int ?? 1
            let (width, height) = (5...8).contains(orientation) ? (image.height, image.width) : (image.width, image.height)
            if let info = item.info?.image, target != .mp4H264 {
                let same = width == info.width && height == info.height
                let scaled = abs(Double(width) / Double(height) - Double(info.width) / Double(info.height)) < 0.02
                guard same || scaled else {
                    throw ValidationError("displays as \(width)×\(height), expected \(info.width)×\(info.height)")
                }
            }
            return "\(width)×\(height)"
        case "pdf":
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw ValidationError("output PDF doesn't open")
            }
            if let pages = item.info?.pdf?.pageCount, document.pageCount != pages {
                throw ValidationError("\(document.pageCount) pages, expected \(pages)")
            }
            return "\(document.pageCount) pages"
        default:
            let info = try await FFProbe.probe(url: url, tools: engine.tools)
            // Subtitle tracks can outlast the audio and video, so compare with those streams only.
            let expected = await mediaStreamDuration(item.url, tools: engine.tools) ?? item.info?.media?.duration ?? info.duration
            let endedEarly = note?.contains("ends early") == true
            if expected > 1, abs(info.duration - expected) / expected > 0.12, target != .gifAnimated, !endedEarly {
                throw ValidationError(String(format: "duration %.2f s, expected %.2f s", info.duration, expected))
            }
            if target.isVideoTarget {
                guard let video = info.video else { throw ValidationError("no video stream") }
                if let source = item.info?.media?.video {
                    // Rotation must be applied (display size kept), not lost.
                    let sourceAspect = Double(source.displayWidth) / Double(max(1, source.displayHeight))
                    let outputAspect = Double(video.displayWidth) / Double(max(1, video.displayHeight))
                    if abs(sourceAspect - outputAspect) > 0.05 {
                        throw ValidationError("aspect \(video.displayWidth)×\(video.displayHeight) vs source \(source.displayWidth)×\(source.displayHeight)")
                    }
                }
                return "\(video.codec) \(video.displayWidth)×\(video.displayHeight) \(String(format: "%.1f", info.duration)) s"
            }
            guard info.audio != nil || info.video != nil else { throw ValidationError("no streams") }
            return "\(info.audio?.codec ?? info.video?.codec ?? "?") \(String(format: "%.1f", info.duration)) s"
        }
    }
}
