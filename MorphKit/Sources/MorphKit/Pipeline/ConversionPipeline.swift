import Foundation

/// Executes one `ConversionJob`: picks the engine, writes through a temp file, commits atomically.
public struct ConversionPipeline: Sendable {
    public let ffmpeg: FFmpegEngine?
    public let cache: EstimateCache
    public var collisionPolicy: CollisionPolicy
    public var preserveFileDates: Bool

    public init(ffmpeg: FFmpegEngine?, cache: EstimateCache, collisionPolicy: CollisionPolicy = .keepBoth,
                preserveFileDates: Bool = false) {
        self.ffmpeg = ffmpeg
        self.cache = cache
        self.collisionPolicy = collisionPolicy
        self.preserveFileDates = preserveFileDates
    }

    public typealias Progress = @Sendable (_ fraction: Double, _ remaining: Double?) -> Void

    public enum Route: Sendable, Equatable {
        case image, combinePDF, ffmpeg
    }

    public static func route(for item: MediaItem, target: OutputFormat) -> Route {
        if target == .pdfCombined { return .combinePDF }
        switch item.kind {
        case .image:
            // Animated images become videos/animations through FFmpeg.
            return target.isVideoTarget || target.isAnimatedTarget ? .ffmpeg : .image
        case .pdf:
            return .image
        case .video, .audio:
            return .ffmpeg
        }
    }

    public func run(_ job: ConversionJob, progress: @escaping Progress) async throws -> JobOutcome {
        try Task.checkCancellation()
        let originals = Set(job.items.map { $0.url.standardizedFileURL.path })
        let item = job.item
        progress(0, nil)

        let finalURL: URL?
        var note: String?
        switch Self.route(for: item, target: job.settings.target) {
        case .combinePDF:
            let items = job.items, options = job.settings.image
            let data = try await BlockingWork.run {
                try ImageEngine.combinePDF(items: items, options: options) { fraction in progress(fraction * 0.95, nil) }
            }
            try Task.checkCancellation()
            finalURL = try AtomicWriter.write(data, to: job.destination, policy: collisionPolicy, protecting: originals)

        case .image:
            let key = SizeEstimator.cacheKey(item: item, settings: job.settings, page: job.page ?? 1)
            let result: ImageEncodeResult
            if let cached = await cache.image(for: key) {
                result = cached
            } else {
                let target = job.settings.target, options = job.settings.image, page = job.page ?? 1
                result = try await BlockingWork.run {
                    try ImageEngine.convert(item: item, target: target, options: options, page: page)
                }
            }
            note = result.note
            try Task.checkCancellation()
            progress(0.9, nil)
            finalURL = try AtomicWriter.write(result.data, to: job.destination, policy: collisionPolicy,
                                              protecting: originals)

        case .ffmpeg:
            guard let ffmpeg else { throw MediaPlanError("FFmpeg isn't available.") }
            let info = try await ffmpeg.mediaInfo(for: item)
            let temp = AtomicWriter.temporaryURL(for: job.destination)
            do {
                let output = try await ffmpeg.convert(item: item, info: info, settings: job.settings, output: temp,
                                                      progress: progress)
                note = output.note
                try Task.checkCancellation()
                finalURL = try AtomicWriter.commit(temp, to: job.destination, policy: collisionPolicy,
                                                   protecting: originals)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        }

        guard let finalURL else {
            return JobOutcome(output: nil, bytes: 0, note: "Skipped — a file with that name already exists")
        }
        if preserveFileDates {
            let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
            if let values = try? item.url.resourceValues(forKeys: keys) {
                var attributes: [FileAttributeKey: Any] = [:]
                if let created = values.creationDate { attributes[.creationDate] = created }
                if let modified = values.contentModificationDate { attributes[.modificationDate] = modified }
                try? FileManager.default.setAttributes(attributes, ofItemAtPath: finalURL.path)
            }
        }
        let bytes = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress(1, 0)
        return JobOutcome(output: finalURL, bytes: bytes, note: note)
    }
}
