import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// One `-progress` update.
public struct FFmpegProgress: Sendable, Equatable {
    public var outTime: Double
    public var speed: Double?
    public var totalSize: Int64?
    public var finished: Bool
}

/// Parses ffmpeg's `-progress pipe:1` key=value blocks.
public struct ProgressParser: Sendable {
    private var values: [String: String] = [:]

    public init() {}

    public mutating func consume(_ line: String) -> FFmpegProgress? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard key != "progress" else {
            defer { values.removeAll(keepingCapacity: true) }
            return FFmpegProgress(outTime: Self.outTime(values), speed: Self.speed(values["speed"]),
                                  totalSize: values["total_size"].flatMap { Int64($0) }, finished: value == "end")
        }
        values[key] = value
        return nil
    }

    static func outTime(_ values: [String: String]) -> Double {
        if let us = values["out_time_us"].flatMap(Double.init), us >= 0 { return us / 1_000_000 }
        if let ms = values["out_time_ms"].flatMap(Double.init), ms >= 0 { return ms / 1_000_000 }
        if let text = values["out_time"] {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        }
        return 0
    }

    static func speed(_ text: String?) -> Double? {
        guard let text, text.hasSuffix("x") else { return nil }
        return Double(text.dropLast().trimmingCharacters(in: .whitespaces))
    }
}

public struct FFmpegError: Error, LocalizedError, Sendable {
    public let message: String
    public let log: String
    public var suggestion: String? = nil

    public var errorDescription: String? { message }
}

/// Runs FFmpeg conversions described by `MediaPlan`s.
public struct FFmpegEngine: Sendable {
    public let tools: FFmpegTools
    public let capabilities: FFmpegCapabilities

    public init(tools: FFmpegTools, capabilities: FFmpegCapabilities) {
        self.tools = tools
        self.capabilities = capabilities
    }

    /// Progress callback: fraction 0…1 and estimated seconds remaining.
    public typealias ProgressHandler = @Sendable (_ fraction: Double, _ remaining: Double?) -> Void

    public struct Output: Sendable {
        public var note: String?
    }

    /// FFmpeg's view of an item (animated images are probed on demand).
    public func mediaInfo(for item: MediaItem) async throws -> AVInfo {
        if let info = item.info?.media { return info }
        return try await FFProbe.probe(url: item.url, tools: tools)
    }

    /// Converts `item` into `output` (a temp path with the final extension).
    public func convert(item: MediaItem, info: AVInfo, settings: ConversionSettings, output: URL,
                        progress: ProgressHandler? = nil) async throws -> Output {
        var plan = try MediaPlanner.plan(item: item, info: info, settings: settings, capabilities: capabilities)

        if plan.mode == .frame {
            try await extractFrame(plan: plan, item: item, settings: settings, output: output, progress: progress)
            return Output(note: nil)
        }

        var fallbackNote: String?
        var reached = 0.0
        do {
            reached = try await run(plan: plan, input: item.url, output: output, progress: progress)
        } catch let error as FFmpegError {
            if plan.hardwareDecode && Self.isDecodeFailure(error.log) {
                // Apple's hardware decoder rejects some streams that decode fine in software.
                plan.hardwareDecode = false
            } else if plan.videoEncoder?.isHardware == true, let fallback = plan.videoEncoder?.softwareFallback,
                      capabilities.hasEncoder(fallback.ffmpegName) {
                // Hardware encoder unavailable (e.g. too many sessions): retry in software.
                plan.videoEncoder = fallback
                fallbackNote = "Used \(fallback.displayName) because hardware encoding failed"
            } else {
                throw error
            }
            reached = try await run(plan: plan, input: item.url, output: output, progress: progress)
        }
        // A file whose index promises more than its data holds (e.g. a partial download).
        if [.video, .audioOnly].contains(plan.mode), plan.duration > 2, reached > 0,
           plan.duration - reached > max(1, plan.duration * 0.1) {
            fallbackNote = "The file ends early: converted \(Formatters.duration(reached)) of \(Formatters.duration(plan.duration))"
        }

        // Size limit: one corrective pass if the encoder overshot.
        if let limit = limitFor(settings: settings), let size = fileSize(output), size > limit,
           let bitrate = plan.videoBitrate {
            plan.videoBitrate = Int(Double(bitrate) * 0.88 * Double(limit) / Double(size))
            try await run(plan: plan, input: item.url, output: output, progress: progress)
            if let newSize = fileSize(output), newSize > limit {
                return Output(note: "Came out at \(Formatters.bytes(newSize)); the limit was \(Formatters.bytes(limit))")
            }
        }
        return Output(note: fallbackNote)
    }

    /// Whether a failure came from decoding the input (so software decoding may succeed).
    static func isDecodeFailure(_ log: String) -> Bool {
        ["Decode error rate", "hardware accelerator failed", "Failed setup for format videotoolbox",
         "Error while decoding", "error while decoding", "Error submitting packet to decoder"]
            .contains { log.contains($0) }
    }

    func limitFor(settings: ConversionSettings) -> Int64? {
        switch settings.target.category {
        case .audio: settings.audio.sizeLimit
        default: settings.video.sizeLimit
        }
    }

    func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// The command lines a plan will run (for "Show command").
    public func commandPreview(item: MediaItem, info: AVInfo, settings: ConversionSettings) throws -> String {
        let plan = try MediaPlanner.plan(item: item, info: info, settings: settings, capabilities: capabilities)
        let output = item.url.deletingPathExtension().appendingPathExtension(plan.fileExtension)
        let passes = FFmpegCommandBuilder.passes(plan: plan, input: item.url, output: output,
                                                 passLogPrefix: URL(filePath: "/tmp/morph-pass"),
                                                 capabilities: capabilities)
        return FFmpegCommandBuilder.displayCommand(passes: passes)
    }

    // MARK: - Running

    @discardableResult
    func run(plan: MediaPlan, input: URL, output: URL, progress: ProgressHandler?) async throws -> Double {
        let passDir = FileManager.default.temporaryDirectory.appending(path: "morph-pass-\(UUID().uuidString)")
        if plan.twoPass { try FileManager.default.createDirectory(at: passDir, withIntermediateDirectories: true) }
        defer { if plan.twoPass { try? FileManager.default.removeItem(at: passDir) } }

        let passes = FFmpegCommandBuilder.passes(plan: plan, input: input, output: output,
                                                 passLogPrefix: passDir.appending(path: "pass"),
                                                 capabilities: capabilities)
        var reached = 0.0
        for (index, arguments) in passes.enumerated() {
            let base = Double(index) / Double(passes.count)
            let span = 1 / Double(passes.count)
            let passesLeft = Double(passes.count - index - 1)
            reached = try await Self.execute(tools.ffmpeg, arguments: arguments, duration: plan.duration) { fraction, remaining in
                // Assume later passes take about as long as this one.
                let perPass = remaining.map { fraction < 0.999 ? $0 / max(0.001, 1 - fraction) : 0 }
                progress?(base + fraction * span, remaining.map { $0 + passesLeft * (perPass ?? 0) })
            }
        }
        return reached
    }

    /// Runs one ffmpeg invocation with progress and cancellation.
    /// Returns how far into the media the output got (seconds), from ffmpeg's progress reports.
    @discardableResult
    static func execute(_ executable: URL, arguments: [String], duration: Double,
                        progress: (@Sendable (Double, Double?) -> Void)?) async throws -> Double {
        let parser = Mutex(ProgressParser())
        let reached = Mutex(0.0)
        let started = Date()
        let output = try await ChildProcess.run(executable, arguments: arguments) { line in
            guard let update = parser.withLock({ $0.consume(line) }) else { return }
            reached.withLock { $0 = max($0, update.outTime) }
            guard duration > 0 else { return }
            let fraction = min(1, max(0, update.outTime / duration))
            var remaining: Double?
            if let speed = update.speed, speed > 0 {
                remaining = max(0, (duration - update.outTime) / speed)
            } else if fraction > 0.02 {
                remaining = Date().timeIntervalSince(started) * (1 - fraction) / fraction
            }
            progress?(update.finished ? 1 : fraction, remaining)
        }
        try Task.checkCancellation()
        guard output.status == 0 else {
            let log = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = FriendlyErrors.explain(ffmpegLog: log, exitStatus: output.status)
            throw FFmpegError(message: explanation.message, log: log, suggestion: explanation.suggestion)
        }
        return reached.withLock { $0 }
    }

    // MARK: - Frames

    func extractFrame(plan: MediaPlan, item: MediaItem, settings: ConversionSettings, output: URL,
                      progress: ProgressHandler?) async throws {
        let png = FileManager.default.temporaryDirectory.appending(path: "morph-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let args = FFmpegCommandBuilder.passes(plan: plan, input: item.url, output: png)[0]
        try await Self.execute(tools.ffmpeg, arguments: args, duration: 0, progress: nil)
        progress?(0.6, nil)
        let format: FileFormat = settings.target == .frameJPEG ? .jpeg : .png
        let options = settings.image
        let data = try await BlockingWork.run {
            guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ImageEngineError("Couldn't read the extracted frame.")
            }
            return try ImageEngine.convert(image: image, to: format, options: options).data
        }
        try data.write(to: output)
        progress?(1, 0)
    }

    /// Grabs a frame as a CGImage (for thumbnails/previews of formats Quick Look can't read).
    public func frameImage(url: URL, at time: Double, maxSide: Int = 512) async throws -> CGImage {
        let png = FileManager.default.temporaryDirectory.appending(path: "morph-thumb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let args = FFmpegCommandBuilder.commonPrefix + [
            "-ss", FFmpegCommandBuilder.number(max(0, time)), "-i", url.path, "-frames:v", "1",
            "-vf", "scale='min(\(maxSide),iw)':-2", "-update", "1", "-f", "image2", png.path,
        ]
        try await Self.execute(tools.ffmpeg, arguments: args, duration: 0, progress: nil)
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ImageEngineError("Couldn't read the frame.") }
        return image
    }

    // MARK: - Estimates

    /// Encodes short samples and extrapolates the output size (constant-quality modes, GIF, WebP).
    public func sampleEstimate(item: MediaItem, info: AVInfo, settings: ConversionSettings) async throws -> Int64 {
        var plan = try MediaPlanner.plan(item: item, info: info, settings: settings, capabilities: capabilities)
        let duration = plan.duration
        guard duration > 0 else { return 0 }
        plan.twoPass = false
        let audioBits = Double(plan.audioBitrate ?? 0)
        plan.audioEncoder = plan.mode == .video ? nil : plan.audioEncoder
        let sampleLength = min(duration, 2.5)
        let offsets: [Double] = duration <= 8
            ? [plan.trim?.start ?? 0]
            : [0.15, 0.5, 0.8].map { (plan.trim?.start ?? 0) + duration * $0 - sampleLength / 2 }
        var totalBytes: Double = 0
        var totalSeconds: Double = 0
        for offset in offsets {
            try Task.checkCancellation()
            var sample = plan
            sample.trim = TrimRange(start: max(0, offset), end: max(0, offset) + (duration <= 8 ? duration : sampleLength))
            sample.duration = duration <= 8 ? duration : sampleLength
            sample.customArguments = []
            sample.fastStart = false
            let null = URL(filePath: "/dev/null")
            var args = FFmpegCommandBuilder.passes(plan: sample, input: item.url, output: null,
                                                   capabilities: capabilities)[0]
            // Measure the stream itself (no container overhead or audio) via the null muxer's total_size.
            if let formatIndex = args.lastIndex(of: "-f") {
                args[formatIndex + 1] = sample.mode == .video ? "matroska" : sample.container
            }
            let size = Mutex<Int64>(0)
            var output = try await ChildProcess.run(tools.ffmpeg, arguments: args) { line in
                if line.hasPrefix("total_size="), let v = Int64(line.dropFirst("total_size=".count)) {
                    size.withLock { $0 = v }
                }
            }
            if output.status != 0 && sample.hardwareDecode && Self.isDecodeFailure(output.stderrText) {
                sample.hardwareDecode = false
                plan.hardwareDecode = false
                args = FFmpegCommandBuilder.passes(plan: sample, input: item.url, output: null, capabilities: capabilities)[0]
                if let formatIndex = args.lastIndex(of: "-f") {
                    args[formatIndex + 1] = sample.mode == .video ? "matroska" : sample.container
                }
                output = try await ChildProcess.run(tools.ffmpeg, arguments: args) { line in
                    if line.hasPrefix("total_size="), let v = Int64(line.dropFirst("total_size=".count)) {
                        size.withLock { $0 = v }
                    }
                }
            }
            guard output.status == 0 else {
                throw FFmpegError(message: "Couldn't estimate the size.", log: output.stderrText)
            }
            totalBytes += Double(size.withLock { $0 })
            totalSeconds += sample.duration
        }
        guard totalSeconds > 0 else { return 0 }
        let videoBytes = totalBytes / totalSeconds * duration
        let audioBytes = plan.mode == .video ? audioBits * duration / 8 : 0
        return Int64((videoBytes + audioBytes) * 1.01)
    }
}
