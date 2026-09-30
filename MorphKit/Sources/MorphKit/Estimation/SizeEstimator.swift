import Foundation

/// An output size estimate.
public struct SizeEstimate: Sendable, Equatable {
    public var bytes: Int64
    /// True when produced by a real encode (images) — shown without "≈".
    public var isExact: Bool
    public var note: String?

    public init(bytes: Int64, isExact: Bool, note: String? = nil) {
        self.bytes = bytes
        self.isExact = isExact
        self.note = note
    }
}

/// Caches finished in-memory image encodes (reused by Convert) and refined estimates.
public actor EstimateCache {
    private var images: [String: ImageEncodeResult] = [:]
    private var order: [String] = []
    private var bytesUsed = 0
    private let budget: Int
    private var sizes: [String: SizeEstimate] = [:]

    public init(budget: Int = min(1 << 30, Int(ProcessInfo.processInfo.physicalMemory / 20))) {
        self.budget = budget
    }

    public func image(for key: String) -> ImageEncodeResult? {
        guard let hit = images[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return hit
    }

    public func store(_ result: ImageEncodeResult, for key: String) {
        guard result.data.count < budget / 4 else { return }
        if let old = images[key] { bytesUsed -= old.data.count }
        images[key] = result
        order.removeAll { $0 == key }
        order.append(key)
        bytesUsed += result.data.count
        while bytesUsed > budget, let oldest = order.first {
            order.removeFirst()
            if let removed = images.removeValue(forKey: oldest) { bytesUsed -= removed.data.count }
        }
    }

    public func estimate(for key: String) -> SizeEstimate? { sizes[key] }

    public func store(_ estimate: SizeEstimate, for key: String) {
        sizes[key] = estimate
        if sizes.count > 5000 { sizes.removeAll() }
    }

    public func removeAll() {
        images.removeAll()
        order.removeAll()
        sizes.removeAll()
        bytesUsed = 0
    }
}

/// Computes output size estimates: instant heuristics, then exact/refined values.
public struct SizeEstimator: Sendable {
    public let cache: EstimateCache
    public let ffmpeg: FFmpegEngine?

    public init(cache: EstimateCache, ffmpeg: FFmpegEngine?) {
        self.cache = cache
        self.ffmpeg = ffmpeg
    }

    public static func cacheKey(item: MediaItem, settings: ConversionSettings, page: Int = 1) -> String {
        "\(item.cacheIdentity)|p\(page)|\(settings.cacheKey(for: item))"
    }

    // MARK: Quick (synchronous, no I/O)

    /// A fast heuristic estimate; nil when nothing sensible can be said yet (e.g. not probed).
    public static func quickEstimate(item: MediaItem, settings: ConversionSettings,
                                     capabilities: FFmpegCapabilities?) -> SizeEstimate? {
        if ConversionPipeline.route(for: item, target: settings.target) == .ffmpeg, case .image(let image)? = item.info {
            // Animated image → video: approximate FFmpeg's view of it.
            let fps = 10.0
            let video = VideoStreamInfo(index: 0, codec: "gif", width: image.width, height: image.height, frameRate: fps)
            let info = AVInfo(duration: Double(image.frameCount) / fps, bitRate: nil, formatName: "gif", video: video,
                              audio: nil, audioStreamCount: 0, hasCoverArt: false)
            guard let plan = try? MediaPlanner.plan(item: item, info: info, settings: settings,
                                                    capabilities: capabilities) else { return nil }
            return SizeEstimate(bytes: mediaBytes(plan: plan, info: info), isExact: false)
        }
        switch item.info {
        case .image(let info)?:
            return quickImage(pixels: settings.image.resize.apply(
                to: CGSizeInt(width: info.width, height: info.height),
                allowUpscale: settings.image.allowUpscale).pixels,
                frames: settings.image.keepAnimation ? info.frameCount : 1, item: item, settings: settings)
        case .pdf(let info)? where settings.target == .original:
            // Compressing: most of a PDF's bytes are usually its images.
            let ratio = 0.25 + 0.5 * settings.image.quality
            var bytes = Double(item.fileSize) * ratio
            if let limit = settings.image.sizeLimit { bytes = min(bytes, Double(limit)) }
            _ = info
            return SizeEstimate(bytes: Int64(max(1_000, bytes)), isExact: false)
        case .pdf(let info)?:
            let pages = Double(settings.target == .pdfCombined ? info.pageCount
                : settings.image.pdfPages.pages(count: info.pageCount).count)
            let px = info.pageWidth * info.pageHeight * pow(settings.image.pdfDPI / 72, 2)
            guard let single = quickImage(pixels: Int(px), frames: 1, item: item, settings: settings) else { return nil }
            return SizeEstimate(bytes: Int64(Double(single.bytes) * pages), isExact: false)
        case .media(let info)?:
            guard let plan = try? MediaPlanner.plan(item: item, info: info, settings: settings,
                                                    capabilities: capabilities) else { return nil }
            return SizeEstimate(bytes: mediaBytes(plan: plan, info: info), isExact: false)
        case nil:
            return nil
        }
    }

    static func quickImage(pixels: Int, frames: Int, item: MediaItem, settings: ConversionSettings) -> SizeEstimate? {
        let format: FileFormat? = settings.target == .pdfCombined ? .pdf
            : ImageEngine.outputFormat(for: settings.target, item: item)
        guard let format else { return nil }
        let q = settings.image.quality
        let jpegBPP = 0.04 + 0.6 * pow(q, 2.2)
        let bpp: Double = switch format {
        case .jpeg, .pdf: jpegBPP
        case .heic: jpegBPP * 0.5
        case .avif: jpegBPP * 0.45
        case .webp: settings.image.lossless ? 1.4 : jpegBPP * 0.7
        case .jp2: jpegBPP * 0.6
        case .png: q >= 0.98 || settings.image.lossless ? 1.6 : 0.3 + 0.3 * q
        case .tiff: 2.5
        case .bmp: 3
        case .gif: 0.45
        case .svg: 0.25
        case .ico: 0.02
        case .icns: 0.1
        default: 1
        }
        var bytes = Double(pixels) * bpp * Double(max(1, frames)) * (frames > 1 ? 0.4 : 1)
        // Scale by how compressible this particular image is, judged from its own file size.
        if frames <= 1, let info = item.info?.image, info.pixelCount > 0, item.fileSize > 0,
           let typical = typicalBytesPerPixel(item.format), ![.ico, .icns, .svg, .bmp, .tiff].contains(format) {
            let actual = Double(item.fileSize) / Double(info.pixelCount)
            let complexity = min(4, max(0.08, actual / typical))
            bytes *= complexity
        }
        if format == .ico { bytes = 180_000 }
        if format == .icns { bytes = 900_000 }
        if let limit = settings.image.sizeLimit { bytes = min(bytes, Double(limit)) }
        return SizeEstimate(bytes: Int64(max(200, bytes)), isExact: false)
    }

    /// Bytes per pixel a typical photo has in a given source format (JPEG ≈ quality 85).
    static func typicalBytesPerPixel(_ format: FileFormat) -> Double? {
        let jpeg85 = 0.04 + 0.6 * pow(0.85, 2.2)
        return switch format {
        case .jpeg: jpeg85
        case .heic, .heif: jpeg85 * 0.5
        case .avif: jpeg85 * 0.45
        case .webp: jpeg85 * 0.7
        case .jp2: jpeg85 * 0.6
        case .png: 1.6
        default: nil
        }
    }

    /// Deterministic size for a plan: exact math for bitrate modes, heuristics otherwise.
    public static func mediaBytes(plan: MediaPlan, info: AVInfo) -> Int64 {
        let duration = plan.duration
        let audioBits: Double = {
            guard let encoder = plan.audioEncoder else { return 0 }
            let channels = Double(plan.audioChannels ?? min(2, info.audio?.channels ?? 2))
            let rate = Double(plan.audioSampleRate ?? info.audio?.sampleRate ?? 48_000)
            switch encoder {
            case .pcm16: return rate * channels * 16
            case .pcm24: return rate * channels * 24
            case .flac, .alac:
                if let source = info.audio, source.isLossless, let bits = source.bitRate { return Double(bits) * 0.9 }
                return rate * channels * 16 * 0.55
            case .copy: return Double(info.audio?.bitRate ?? 160_000)
            case .mp3:
                if let q = plan.mp3VBRQuality { return Double(AudioBitrateModel.mp3VBRKbps[q] * 1000) }
                return Double(plan.audioBitrate ?? 160_000)
            default: return Double(plan.audioBitrate ?? 128_000)
            }
        }()

        var videoBits: Double = 0
        switch plan.mode {
        case .audioOnly:
            var bytes = audioBits * duration / 8
            if plan.keepCoverArt { bytes += 150_000 }
            return Int64(bytes * 1.005)
        case .frame:
            let size = Double((plan.outputSize?.pixels) ?? 2_000_000)
            return Int64(size * (plan.fileExtension == "png" ? 1.5 : 0.35))
        case .gif:
            let px = Double(plan.outputSize?.pixels ?? 200_000)
            return Int64(px * (plan.animationFPS ?? 12) * duration * 0.11)
        case .animatedWebP:
            let px = Double(plan.outputSize?.pixels ?? 300_000)
            let q = Double(plan.webpQuality ?? 75) / 100
            return Int64(px * (plan.animationFPS ?? 15) * duration * (0.015 + 0.06 * q * q))
        case .video:
            if plan.videoEncoder == .copy {
                videoBits = Double(info.video?.bitRate ?? max(0, (info.bitRate ?? 0) - Int(audioBits)))
            } else if let bitrate = plan.videoBitrate {
                videoBits = Double(bitrate)
            } else if let profile = plan.proresProfile {
                let px = Double(plan.outputSize?.pixels ?? 2_073_600)
                videoBits = profile.bitsPerPixel * px * (plan.outputFrameRate ?? plan.sourceFrameRate)
            } else if let q = plan.constantQuality, let encoder = plan.videoEncoder {
                videoBits = Double(VideoBitrateModel.bitrate(
                    quality: q, family: encoder.family, size: plan.outputSize ?? CGSizeInt(width: 1920, height: 1080),
                    fps: plan.outputFrameRate ?? plan.sourceFrameRate, source: nil, sourceSize: nil))
            }
        }
        return Int64((videoBits + audioBits) * duration / 8 * 1.01)
    }

    // MARK: Refined (async)

    /// Whether `refined` would add information beyond the quick estimate.
    public static func needsRefinement(item: MediaItem, settings: ConversionSettings,
                                       capabilities: FFmpegCapabilities?) -> Bool {
        switch item.kind {
        case .image, .pdf: return true
        case .video, .audio:
            guard let info = item.info?.media,
                  let plan = try? MediaPlanner.plan(item: item, info: info, settings: settings, capabilities: capabilities)
            else { return false }
            switch plan.mode {
            case .gif, .animatedWebP, .frame: return true
            case .audioOnly:
                return [.flac, .alac].contains(plan.audioEncoder ?? .copy) || plan.mp3VBRQuality != nil
            case .video:
                return plan.constantQuality != nil && plan.videoEncoder?.isHardware == true
            }
        }
    }

    /// Exact (images: real encode, cached for Convert) or sampled (media) estimate.
    public func refined(item: MediaItem, settings: ConversionSettings, page: Int = 1) async throws -> SizeEstimate {
        let key = Self.cacheKey(item: item, settings: settings, page: page)
        if let cached = await cache.estimate(for: key) { return cached }

        let estimate: SizeEstimate
        if ConversionPipeline.route(for: item, target: settings.target) == .ffmpeg, item.kind == .image {
            guard let ffmpeg else { throw MediaPlanError("FFmpeg isn't available.") }
            let info = try await ffmpeg.mediaInfo(for: item)
            let bytes = try await ffmpeg.sampleEstimate(item: item, info: info, settings: settings)
            let result = SizeEstimate(bytes: bytes, isExact: false)
            await cache.store(result, for: key)
            return result
        }
        if ConversionPipeline.route(for: item, target: settings.target) == .pdfCompress {
            let url = item.url, options = settings.image
            let result = try await BlockingWork.run(qos: .userInitiated) {
                try PDFCompressor.compress(url: url, options: options)
            }
            await cache.store(result, for: key)
            let exact = SizeEstimate(bytes: result.byteCount, isExact: true, note: result.note)
            await cache.store(exact, for: key)
            return exact
        }
        switch item.kind {
        case .image, .pdf:
            let target = settings.target == .pdfCombined ? OutputFormat.pdf : settings.target
            let options = settings.image
            if item.kind == .pdf, let info = item.info?.pdf {
                // Encode the first selected page and extrapolate.
                let pages = settings.target == .pdfCombined ? Array(1...max(1, info.pageCount))
                    : options.pdfPages.pages(count: info.pageCount)
                let first = try await BlockingWork.run(qos: .userInitiated) {
                    try ImageEngine.convert(item: item, target: target == .pdf ? .png : target, options: options,
                                            page: pages.first ?? 1)
                }
                estimate = SizeEstimate(bytes: first.byteCount * Int64(pages.count), isExact: pages.count == 1,
                                        note: first.note)
                if pages.count == 1 && settings.target != .pdfCombined { await cache.store(first, for: key) }
            } else {
                let result = try await BlockingWork.run(qos: .userInitiated) {
                    try ImageEngine.convert(item: item, target: target, options: options)
                }
                if settings.target != .pdfCombined { await cache.store(result, for: key) }
                estimate = SizeEstimate(bytes: result.byteCount, isExact: settings.target != .pdfCombined,
                                        note: result.note)
            }
        case .video, .audio:
            guard let ffmpeg else { throw MediaPlanError("FFmpeg isn't available.") }
            let info = try await ffmpeg.mediaInfo(for: item)
            let bytes = try await ffmpeg.sampleEstimate(item: item, info: info, settings: settings)
            estimate = SizeEstimate(bytes: bytes, isExact: false)
        }
        await cache.store(estimate, for: key)
        return estimate
    }
}
