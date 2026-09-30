import Foundation

// MARK: - Shared

public struct RGBColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)
}

public struct TrimRange: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double?

    public init(start: Double = 0, end: Double? = nil) {
        self.start = start
        self.end = end
    }

    /// Effective duration of the trimmed media.
    public func duration(of total: Double) -> Double {
        let upper = min(end ?? total, total)
        return max(0, upper - max(0, start))
    }
}

public enum MetadataPolicy: String, Codable, Sendable, CaseIterable {
    case keep, removeLocation, removeAll

    public var displayName: String {
        switch self {
        case .keep: "Keep all"
        case .removeLocation: "Remove location"
        case .removeAll: "Remove all"
        }
    }
}

public enum ChannelLayout: String, Codable, Sendable, CaseIterable {
    case original, mono, stereo

    public var displayName: String {
        switch self {
        case .original: "Original"
        case .mono: "Mono"
        case .stereo: "Stereo"
        }
    }
}

// MARK: - Images

public enum ResizeMode: Codable, Sendable, Hashable {
    case none
    /// Scale by a percentage (1–400).
    case percent(Double)
    /// Longest side in pixels.
    case longestSide(Int)
    /// Fit inside a box, keeping the aspect ratio.
    case fit(width: Int, height: Int)
    /// Fill a box exactly (crops to keep the aspect ratio).
    case fill(width: Int, height: Int)

    /// Output pixel size for an input of `size`.
    public func apply(to size: CGSizeInt, allowUpscale: Bool) -> CGSizeInt {
        let w = Double(size.width), h = Double(size.height)
        var scale: Double
        switch self {
        case .none: return size
        case .percent(let p): scale = max(0.01, p / 100)
        case .longestSide(let side): scale = Double(side) / max(w, h)
        case .fit(let bw, let bh): scale = min(Double(bw) / w, Double(bh) / h)
        case .fill(let bw, let bh):
            if !allowUpscale && (bw > size.width || bh > size.height) {
                let s = min(1, min(w / Double(bw), h / Double(bh)))
                return CGSizeInt(width: max(1, Int(Double(bw) * s)), height: max(1, Int(Double(bh) * s)))
            }
            return CGSizeInt(width: max(1, bw), height: max(1, bh))
        }
        if !allowUpscale { scale = min(scale, 1) }
        return CGSizeInt(width: max(1, Int((w * scale).rounded())), height: max(1, Int((h * scale).rounded())))
    }
}

/// Integer pixel size (CGSize is Double-based and not Codable-stable for hashing).
public struct CGSizeInt: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixels: Int { width * height }
    public var longestSide: Int { max(width, height) }
}

public enum ColorProfileOption: String, Codable, Sendable, CaseIterable {
    case keep, sRGB, displayP3

    public var displayName: String {
        switch self {
        case .keep: "Keep original"
        case .sRGB: "sRGB (web)"
        case .displayP3: "Display P3"
        }
    }
}

public enum ChromaSubsampling: String, Codable, Sendable, CaseIterable {
    case automatic, full, half

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .full: "4:4:4 (sharpest)"
        case .half: "4:2:0 (smallest)"
        }
    }
}

public enum PageSelection: Codable, Sendable, Hashable {
    case all
    case first
    case range(from: Int, to: Int)

    public func pages(count: Int) -> [Int] {
        switch self {
        case .all: Array(1...max(1, count))
        case .first: [1]
        case .range(let from, let to):
            Array(max(1, from)...max(max(1, from), min(to, count)))
        }
    }
}

public enum PDFPageSize: String, Codable, Sendable, CaseIterable {
    case fitImage, a4, letter

    public var displayName: String {
        switch self {
        case .fitImage: "Fit each image"
        case .a4: "A4"
        case .letter: "US Letter"
        }
    }
}

public struct ImageOptions: Codable, Sendable, Hashable {
    /// Quality slider, 0 (smallest) … 1 (best).
    public var quality: Double = 0.8
    /// Maximum output size per file, in bytes.
    public var sizeLimit: Int64?

    // Pro
    public var resize: ResizeMode = .none
    public var allowUpscale = false
    public var colorProfile: ColorProfileOption = .keep
    public var metadata: MetadataPolicy = .removeLocation
    /// Lossless WebP/AVIF/HEIC/JPEG 2000 encoding.
    public var lossless = false
    public var progressive = false
    public var chroma: ChromaSubsampling = .automatic
    /// oxipng preset 0–6.
    public var pngOptimization = 2
    public var pngDithering = 1.0
    /// Background used when transparency is flattened (JPEG, BMP, PDF pages).
    public var flattenColor: RGBColor = .white
    public var keepAnimation = true
    public var icoSizes: [Int] = [16, 24, 32, 48, 64, 128, 256]
    /// Written DPI metadata (nil = keep).
    public var dpi: Int?
    /// Rasterization resolution for PDF pages.
    public var pdfDPI: Double = 150
    /// Compressing PDFs: resolution of the images inside (nil = from the quality slider).
    public var pdfImageDPI: Int?
    public var pdfPages: PageSelection = .all
    public var pdfPageSize: PDFPageSize = .fitImage
    /// Scale factor for SVG rendering (1 = intrinsic size).
    public var svgScale: Double = 2
    public var trace = TraceOptions()
    /// libwebp effort 0 (fast) – 6 (slow, smaller).
    public var webpMethod = 4

    public init() {}
}

// MARK: - Video

public enum VideoCodecFamily: String, Codable, Sendable {
    case h264, hevc, prores, av1, vp9, copy
}

public enum VideoEncoder: String, Codable, Sendable, CaseIterable, Identifiable {
    case h264VT, hevcVT, proresVT, x264, x265, svtAV1, vp9, copy

    public var id: String { rawValue }

    public var ffmpegName: String {
        switch self {
        case .h264VT: "h264_videotoolbox"
        case .hevcVT: "hevc_videotoolbox"
        case .proresVT: "prores_videotoolbox"
        case .x264: "libx264"
        case .x265: "libx265"
        case .svtAV1: "libsvtav1"
        case .vp9: "libvpx-vp9"
        case .copy: "copy"
        }
    }

    public var displayName: String {
        switch self {
        case .h264VT: "H.264 — Apple hardware"
        case .hevcVT: "HEVC — Apple hardware"
        case .proresVT: "ProRes — Apple hardware"
        case .x264: "H.264 — x264"
        case .x265: "HEVC — x265"
        case .svtAV1: "AV1 — SVT-AV1"
        case .vp9: "VP9 — libvpx"
        case .copy: "Copy (no re-encode)"
        }
    }

    public var family: VideoCodecFamily {
        switch self {
        case .h264VT, .x264: .h264
        case .hevcVT, .x265: .hevc
        case .proresVT: .prores
        case .svtAV1: .av1
        case .vp9: .vp9
        case .copy: .copy
        }
    }

    public var isHardware: Bool { [.h264VT, .hevcVT, .proresVT].contains(self) }

    /// Software fallback used if the hardware encoder fails.
    public var softwareFallback: VideoEncoder? {
        switch self {
        case .h264VT: .x264
        case .hevcVT: .x265
        default: nil
        }
    }

    public func isSupported(in container: VideoContainer) -> Bool {
        switch container {
        case .mp4, .m4v: [.h264, .hevc, .av1, .vp9, .copy].contains(family)
        case .mov: [.h264, .hevc, .prores, .copy].contains(family)
        case .mkv: true
        case .webm: [.vp9, .av1, .copy].contains(family)
        }
    }
}

public enum VideoContainer: String, Codable, Sendable, CaseIterable, Identifiable {
    case mp4, mov, mkv, webm, m4v

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
    public var ffmpegFormat: String {
        switch self {
        case .mp4: "mp4"
        case .mov: "mov"
        case .mkv: "matroska"
        case .webm: "webm"
        case .m4v: "ipod"
        }
    }
    public var supportsFastStart: Bool { [.mp4, .mov, .m4v].contains(self) }
}

public enum RateControl: String, Codable, Sendable, CaseIterable {
    /// Simple mode: the quality slider picks a target bitrate (exact size estimates).
    case automatic
    /// Constant quality (VideoToolbox -q:v / CRF).
    case constantQuality
    /// Average bitrate in kbps.
    case averageBitrate

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .constantQuality: "Constant quality"
        case .averageBitrate: "Average bitrate"
        }
    }
}

public enum ResolutionPreset: Codable, Sendable, Hashable, Identifiable {
    case original
    /// Short side in pixels (2160 = 4K, 1080, 720 …).
    case shortSide(Int)
    case custom(width: Int, height: Int)

    public var id: String {
        switch self {
        case .original: "original"
        case .shortSide(let s): "s\(s)"
        case .custom(let w, let h): "c\(w)x\(h)"
        }
    }

    public static let presets: [ResolutionPreset] = [
        .original, .shortSide(2160), .shortSide(1440), .shortSide(1080), .shortSide(720), .shortSide(480), .shortSide(360),
    ]

    public var displayName: String {
        switch self {
        case .original: "Original"
        case .shortSide(2160): "4K (2160p)"
        case .shortSide(let s): "\(s)p"
        case .custom(let w, let h): "\(w)×\(h)"
        }
    }

    /// Output display size (even dimensions) for a source display size.
    public func apply(width: Int, height: Int, allowUpscale: Bool) -> CGSizeInt {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        switch self {
        case .original:
            return CGSizeInt(width: even(Double(width)), height: even(Double(height)))
        case .shortSide(let target):
            let short = Double(min(width, height))
            var scale = Double(target) / short
            if !allowUpscale { scale = min(1, scale) }
            return CGSizeInt(width: even(Double(width) * scale), height: even(Double(height) * scale))
        case .custom(let w, let h):
            // Fit inside the custom box keeping the aspect ratio.
            var scale = min(Double(w) / Double(width), Double(h) / Double(height))
            if !allowUpscale { scale = min(1, scale) }
            return CGSizeInt(width: even(Double(width) * scale), height: even(Double(height) * scale))
        }
    }
}

public enum FrameRateOption: Codable, Sendable, Hashable, Identifiable {
    case original
    case fps(Double)

    public var id: String {
        switch self {
        case .original: "original"
        case .fps(let f): "\(f)"
        }
    }

    public static let presets: [FrameRateOption] = [.original, .fps(60), .fps(30), .fps(25), .fps(24), .fps(15)]

    public var displayName: String {
        switch self {
        case .original: "Original"
        case .fps(let f): f == f.rounded() ? "\(Int(f)) fps" : String(format: "%.2f fps", f)
        }
    }
}

public enum HDRMode: String, Codable, Sendable, CaseIterable {
    /// Keep HDR when the output can carry it, otherwise tone-map.
    case automatic
    /// Always tone-map to SDR (BT.709).
    case toneMap

    public var displayName: String {
        switch self {
        case .automatic: "Keep when possible"
        case .toneMap: "Convert to SDR"
        }
    }
}

public enum ToneMapper: String, Codable, Sendable, CaseIterable {
    case perceptual, hable, clip

    public var displayName: String {
        switch self {
        case .perceptual: "Perceptual"
        case .hable: "Filmic (Hable)"
        case .clip: "Clip"
        }
    }
}

public enum BitDepthOption: String, Codable, Sendable, CaseIterable {
    case automatic, eight, ten

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .eight: "8-bit"
        case .ten: "10-bit"
        }
    }
}

public enum EncoderSpeed: String, Codable, Sendable, CaseIterable {
    case fastest, fast, balanced, slow, slowest

    public var displayName: String {
        switch self {
        case .fastest: "Fastest"
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .slow: "Smaller (slow)"
        case .slowest: "Smallest (slowest)"
        }
    }
}

public enum ProResProfile: String, Codable, Sendable, CaseIterable {
    case proxy, lt, standard, hq, p4444 = "4444", xq

    public var displayName: String {
        switch self {
        case .proxy: "422 Proxy"
        case .lt: "422 LT"
        case .standard: "422"
        case .hq: "422 HQ"
        case .p4444: "4444"
        case .xq: "4444 XQ"
        }
    }

    public var ffmpegProfile: String { rawValue }

    /// Approximate bits per pixel per frame (Apple ProRes white paper ratios at 1080p30).
    public var bitsPerPixel: Double {
        switch self {
        case .proxy: 0.73
        case .lt: 1.64
        case .standard: 2.36
        case .hq: 3.54
        case .p4444: 5.30
        case .xq: 7.96
        }
    }

    /// Picks a profile for a 0…1 quality value.
    public static func forQuality(_ quality: Double) -> ProResProfile {
        switch quality {
        case ..<0.25: .proxy
        case ..<0.5: .lt
        case ..<0.75: .standard
        default: .hq
        }
    }
}

public enum AudioEncoder: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, aac, opus, mp3, flac, alac, pcm16, pcm24, copy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .aac: "AAC (Apple)"
        case .opus: "Opus"
        case .mp3: "MP3 (LAME)"
        case .flac: "FLAC"
        case .alac: "Apple Lossless"
        case .pcm16: "PCM 16-bit"
        case .pcm24: "PCM 24-bit"
        case .copy: "Copy (no re-encode)"
        }
    }

    public var isLossless: Bool { [.flac, .alac, .pcm16, .pcm24].contains(self) }
}

public struct AudioTrackOptions: Codable, Sendable, Hashable {
    public var enabled = true
    public var encoder: AudioEncoder = .automatic
    /// nil = automatic (based on the quality slider).
    public var bitrateKbps: Int?
    public var sampleRate: Int?
    public var channels: ChannelLayout = .original

    public init() {}
}

public enum GIFDither: String, Codable, Sendable, CaseIterable {
    case automatic, none, bayer, floydSteinberg, sierra

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .none: "None"
        case .bayer: "Ordered (Bayer)"
        case .floydSteinberg: "Floyd–Steinberg"
        case .sierra: "Sierra"
        }
    }
}

public struct GIFOptions: Codable, Sendable, Hashable {
    /// nil = derived from the quality slider.
    public var fps: Double?
    public var maxWidth: Int?
    public var colors: Int?
    public var dither: GIFDither = .automatic
    public var loop = true

    public init() {}
}

public enum RotationOption: Int, Codable, Sendable, CaseIterable {
    case none = 0, clockwise90 = 90, clockwise180 = 180, clockwise270 = 270

    public var displayName: String {
        switch self {
        case .none: "None"
        case .clockwise90: "90° clockwise"
        case .clockwise180: "180°"
        case .clockwise270: "90° counterclockwise"
        }
    }
}

public struct VideoOptions: Codable, Sendable, Hashable {
    /// Quality slider, 0 (smallest) … 1 (best).
    public var quality: Double = 0.6
    public var sizeLimit: Int64?

    // Pro
    /// nil = the target's default encoder.
    public var encoder: VideoEncoder?
    /// nil = the target's container.
    public var container: VideoContainer?
    public var rateControl: RateControl = .automatic
    /// Used with `.constantQuality` (0…1).
    public var constantQuality: Double = 0.6
    /// Used with `.averageBitrate`.
    public var bitrateKbps = 8000
    public var speed: EncoderSpeed = .balanced
    public var resolution: ResolutionPreset = .original
    public var allowUpscale = false
    public var frameRate: FrameRateOption = .original
    public var keyframeSeconds: Double = 2
    public var bitDepth: BitDepthOption = .automatic
    public var hdr: HDRMode = .automatic
    public var toneMapper: ToneMapper = .perceptual
    /// nil = picked from the quality slider.
    public var proresProfile: ProResProfile?
    public var audio = AudioTrackOptions()
    public var trim: TrimRange?
    public var rotation: RotationOption = .none
    public var flipHorizontal = false
    public var flipVertical = false
    public var stripMetadata = false
    /// Drops GPS location tags (on by default; `stripMetadata` removes everything).
    public var removeLocation = true
    public var fastStart = true
    public var customArguments = ""
    public var gif = GIFOptions()
    /// Timestamp for still-frame targets (seconds).
    public var frameTime: Double = 0

    public init() {}
}

// MARK: - Audio

public struct AudioOptions: Codable, Sendable, Hashable {
    /// Quality slider, 0 (smallest) … 1 (best).
    public var quality: Double = 0.6
    public var sizeLimit: Int64?

    // Pro
    /// nil = derived from the slider.
    public var bitrateKbps: Int?
    /// Variable bitrate (MP3/AAC/Opus).
    public var variableBitrate = true
    public var sampleRate: Int?
    public var channels: ChannelLayout = .original
    public var normalizeLoudness = false
    public var trim: TrimRange?
    public var keepCoverArt = true
    public var stripMetadata = false
    /// Drops GPS location tags (e.g. when extracting audio from an iPhone video).
    public var removeLocation = true
    public var customArguments = ""

    public init() {}
}

// MARK: - Bundle

/// Everything needed to convert one group of files (one per media kind in the UI).
public struct ConversionSettings: Codable, Sendable, Hashable {
    public var target: OutputFormat
    public var image = ImageOptions()
    public var video = VideoOptions()
    public var audio = AudioOptions()

    public init(target: OutputFormat) {
        self.target = target
    }

    /// Which option struct the quality slider & size limit edit for this target.
    public enum SliderDomain: Sendable { case image, video, audio }

    public func sliderDomain(for item: MediaItem) -> SliderDomain {
        Self.sliderDomain(target: target, kind: item.kind)
    }

    public static func sliderDomain(target: OutputFormat, kind: MediaKind) -> SliderDomain {
        switch target.category {
        case .video, .animated: return .video
        case .audio: return .audio
        case .image, .document, .vector, .frame: return .image
        case .original:
            switch kind {
            case .video: return .video
            case .audio: return .audio
            case .image, .pdf: return .image
            }
        }
    }

    /// Stable key describing only the options that affect `item`'s output (for caching).
    public func cacheKey(for item: MediaItem) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload: Data?
        switch sliderDomain(for: item) {
        case .image: payload = try? encoder.encode(image)
        case .video: payload = try? encoder.encode(video)
        case .audio: payload = try? encoder.encode(audio)
        }
        let body = payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(target.rawValue)|\(body)"
    }
}

// MARK: - Tolerant decoding

// Settings and presets are saved as JSON. These decoders keep working when a newer version adds
// options: missing or unreadable keys fall back to their defaults instead of failing the whole decode.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension ImageOptions {
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = c.value(.quality, or: quality)
        sizeLimit = c.optional(.sizeLimit)
        resize = c.value(.resize, or: resize)
        allowUpscale = c.value(.allowUpscale, or: allowUpscale)
        colorProfile = c.value(.colorProfile, or: colorProfile)
        metadata = c.value(.metadata, or: metadata)
        lossless = c.value(.lossless, or: lossless)
        progressive = c.value(.progressive, or: progressive)
        chroma = c.value(.chroma, or: chroma)
        pngOptimization = c.value(.pngOptimization, or: pngOptimization)
        pngDithering = c.value(.pngDithering, or: pngDithering)
        flattenColor = c.value(.flattenColor, or: flattenColor)
        keepAnimation = c.value(.keepAnimation, or: keepAnimation)
        icoSizes = c.value(.icoSizes, or: icoSizes)
        dpi = c.optional(.dpi)
        pdfDPI = c.value(.pdfDPI, or: pdfDPI)
        pdfImageDPI = c.optional(.pdfImageDPI)
        pdfPages = c.value(.pdfPages, or: pdfPages)
        pdfPageSize = c.value(.pdfPageSize, or: pdfPageSize)
        svgScale = c.value(.svgScale, or: svgScale)
        trace = c.value(.trace, or: trace)
        webpMethod = c.value(.webpMethod, or: webpMethod)
    }
}

extension AudioTrackOptions {
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, or: enabled)
        encoder = c.value(.encoder, or: encoder)
        bitrateKbps = c.optional(.bitrateKbps)
        sampleRate = c.optional(.sampleRate)
        channels = c.value(.channels, or: channels)
    }
}

extension GIFOptions {
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = c.optional(.fps)
        maxWidth = c.optional(.maxWidth)
        colors = c.optional(.colors)
        dither = c.value(.dither, or: dither)
        loop = c.value(.loop, or: loop)
    }
}

extension VideoOptions {
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = c.value(.quality, or: quality)
        sizeLimit = c.optional(.sizeLimit)
        encoder = c.optional(.encoder)
        container = c.optional(.container)
        rateControl = c.value(.rateControl, or: rateControl)
        constantQuality = c.value(.constantQuality, or: constantQuality)
        bitrateKbps = c.value(.bitrateKbps, or: bitrateKbps)
        speed = c.value(.speed, or: speed)
        resolution = c.value(.resolution, or: resolution)
        allowUpscale = c.value(.allowUpscale, or: allowUpscale)
        frameRate = c.value(.frameRate, or: frameRate)
        keyframeSeconds = c.value(.keyframeSeconds, or: keyframeSeconds)
        bitDepth = c.value(.bitDepth, or: bitDepth)
        hdr = c.value(.hdr, or: hdr)
        toneMapper = c.value(.toneMapper, or: toneMapper)
        proresProfile = c.optional(.proresProfile)
        audio = c.value(.audio, or: audio)
        trim = c.optional(.trim)
        rotation = c.value(.rotation, or: rotation)
        flipHorizontal = c.value(.flipHorizontal, or: flipHorizontal)
        flipVertical = c.value(.flipVertical, or: flipVertical)
        stripMetadata = c.value(.stripMetadata, or: stripMetadata)
        removeLocation = c.value(.removeLocation, or: removeLocation)
        fastStart = c.value(.fastStart, or: fastStart)
        customArguments = c.value(.customArguments, or: customArguments)
        gif = c.value(.gif, or: gif)
        frameTime = c.value(.frameTime, or: frameTime)
    }
}

extension AudioOptions {
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = c.value(.quality, or: quality)
        sizeLimit = c.optional(.sizeLimit)
        bitrateKbps = c.optional(.bitrateKbps)
        variableBitrate = c.value(.variableBitrate, or: variableBitrate)
        sampleRate = c.optional(.sampleRate)
        channels = c.value(.channels, or: channels)
        normalizeLoudness = c.value(.normalizeLoudness, or: normalizeLoudness)
        trim = c.optional(.trim)
        keepCoverArt = c.value(.keepCoverArt, or: keepCoverArt)
        stripMetadata = c.value(.stripMetadata, or: stripMetadata)
        removeLocation = c.value(.removeLocation, or: removeLocation)
        customArguments = c.value(.customArguments, or: customArguments)
    }
}

extension ConversionSettings {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try c.decode(OutputFormat.self, forKey: .target))
        image = c.value(.image, or: image)
        video = c.value(.video, or: video)
        audio = c.value(.audio, or: audio)
    }
}
