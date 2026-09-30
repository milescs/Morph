import Foundation

/// A fully resolved description of an FFmpeg conversion. Built by `MediaPlanner`, turned into
/// arguments by `FFmpegCommandBuilder`, and used for size estimates.
public struct MediaPlan: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case video          // re-encode (or copy) video, optional audio
        case gif
        case animatedWebP
        case audioOnly
        case frame          // single still frame (PNG, then ImageEngine)
    }

    public var mode: Mode
    public var container: String          // ffmpeg muxer (-f)
    public var fileExtension: String

    // Video
    public var videoEncoder: VideoEncoder?
    public var outputSize: CGSizeInt?
    public var sourceFrameRate: Double
    public var outputFrameRate: Double?   // nil = unchanged
    public var videoBitrate: Int?         // bps (bitrate / target-size modes)
    public var constantQuality: Double?   // 0…1 (CQ/CRF modes)
    public var twoPass: Bool
    public var keepHDR: Bool
    public var sourcePrimaries: String?
    public var sourceTransfer: String?
    public var sourceColorSpace: String?
    public var toneMap: ToneMapper?
    public var tenBit: Bool
    public var proresProfile: ProResProfile?
    public var speed: EncoderSpeed
    public var keyframeInterval: Int?
    public var rotation: RotationOption
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    // GIF / animated WebP
    public var animationFPS: Double?
    public var animationWidth: Int?
    public var gifColors: Int?
    public var gifDither: String?
    public var webpQuality: Int?

    // Audio
    public var audioEncoder: AudioEncoder?  // nil = no audio
    public var audioBitrate: Int?           // bps; nil for lossless/copy/VBR-quality
    public var mp3VBRQuality: Int?          // LAME -q:a 0…9
    public var audioSampleRate: Int?
    public var audioChannels: Int?
    public var normalizeLoudness: Bool
    public var keepCoverArt: Bool

    // Common
    public var trim: TrimRange?
    public var duration: Double             // output duration (after trim)
    public var frameTime: Double
    public var stripMetadata: Bool
    public var fastStart: Bool
    public var customArguments: [String]

    /// Streams to map (input stream indexes).
    public var videoStreamIndex: Int?
    public var audioStreamIndex: Int?
    public var coverArtIncluded: Bool
}

public struct MediaPlanError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Resolves targets + options into a `MediaPlan` for one input.
public enum MediaPlanner {
    public static func plan(item: MediaItem, info: AVInfo, settings: ConversionSettings,
                            capabilities: FFmpegCapabilities?) throws -> MediaPlan {
        let target = settings.target
        let v = settings.video
        let video = info.video

        var plan = MediaPlan(
            mode: .video, container: "mp4", fileExtension: "mp4", videoEncoder: nil, outputSize: nil,
            sourceFrameRate: video?.frameRate ?? 30, outputFrameRate: nil, videoBitrate: nil, constantQuality: nil,
            twoPass: false, keepHDR: false, sourcePrimaries: video?.colorPrimaries, sourceTransfer: video?.colorTransfer,
            sourceColorSpace: video?.colorSpace, toneMap: nil, tenBit: false, proresProfile: nil, speed: v.speed,
            keyframeInterval: nil, rotation: v.rotation, flipHorizontal: v.flipHorizontal,
            flipVertical: v.flipVertical, animationFPS: nil, animationWidth: nil, gifColors: nil, gifDither: nil,
            webpQuality: nil, audioEncoder: nil, audioBitrate: nil, mp3VBRQuality: nil, audioSampleRate: nil,
            audioChannels: nil, normalizeLoudness: false, keepCoverArt: false, trim: nil, duration: info.duration,
            frameTime: 0, stripMetadata: v.stripMetadata, fastStart: v.fastStart,
            customArguments: ShellWords.split(v.customArguments), videoStreamIndex: video?.index,
            audioStreamIndex: info.audio?.index, coverArtIncluded: false)

        let resolved = resolveTarget(target, item: item, info: info)
        switch resolved {
        case .audio(let encoder, let container, let ext):
            try planAudio(&plan, encoder: encoder, container: container, ext: ext, info: info, options: settings.audio,
                          capabilities: capabilities)
            return plan
        case .frame(let ext):
            guard video != nil else { throw MediaPlanError("This file has no video to take a frame from.") }
            plan.mode = .frame
            plan.container = "image2"
            plan.fileExtension = ext
            plan.frameTime = min(max(0, v.frameTime), max(0, info.duration - 0.05))
            plan.videoStreamIndex = video?.index
            plan.audioStreamIndex = nil
            if video?.isHDR == true { plan.toneMap = v.toneMapper }
            return plan
        case .gif, .animatedWebP:
            guard let video else { throw MediaPlanError("This file has no video.") }
            plan.mode = resolved == .gif ? .gif : .animatedWebP
            plan.container = resolved == .gif ? "gif" : "webp"
            plan.fileExtension = resolved == .gif ? "gif" : "webp"
            plan.audioStreamIndex = nil
            plan.trim = v.trim
            plan.duration = v.trim?.duration(of: info.duration) ?? info.duration
            planAnimation(&plan, video: video, options: v, gif: resolved == .gif)
            if video.isHDR { plan.toneMap = v.toneMapper }
            return plan
        case .video(var encoder, var container):
            guard let video else { throw MediaPlanError("This file has no video.") }
            if let override = v.container { container = override }
            if let override = v.encoder { encoder = override }
            if !encoder.isSupported(in: container) {
                throw MediaPlanError("\(encoder.displayName) can't be saved in \(container.displayName).")
            }
            if let capabilities, encoder != .copy, !capabilities.hasEncoder(encoder.ffmpegName) {
                throw MediaPlanError("This FFmpeg build doesn't include \(encoder.displayName).")
            }
            plan.mode = .video
            plan.container = container.ffmpegFormat
            plan.fileExtension = target == .original && container.rawValue == item.url.pathExtension.lowercased()
                ? item.url.pathExtension : container.fileExtension
            plan.videoEncoder = encoder
            plan.trim = v.trim
            plan.duration = v.trim?.duration(of: info.duration) ?? info.duration
            plan.fastStart = v.fastStart && container.supportsFastStart
            try planVideo(&plan, encoder: encoder, video: video, info: info, options: v, container: container)
            planTrackAudio(&plan, info: info, options: v, container: container, capabilities: capabilities)
            return plan
        }
    }

    // MARK: - Target resolution

    /// The encoder and container a video target implies for `item` (before Pro overrides).
    public static func videoDefaults(for target: OutputFormat, item: MediaItem,
                                     info: AVInfo) -> (encoder: VideoEncoder, container: VideoContainer)? {
        if case .video(let encoder, let container) = resolveTarget(target, item: item, info: info) {
            return (encoder, container)
        }
        return nil
    }

    enum Resolved: Equatable {
        case video(VideoEncoder, VideoContainer)
        case audio(AudioEncoder, container: String, ext: String)
        case gif, animatedWebP
        case frame(ext: String)
    }

    static func resolveTarget(_ target: OutputFormat, item: MediaItem, info: AVInfo) -> Resolved {
        switch target {
        case .mp4H264: return .video(.h264VT, .mp4)
        case .mp4HEVC: return .video(.hevcVT, .mp4)
        case .mp4AV1: return .video(.svtAV1, .mp4)
        case .movH264: return .video(.h264VT, .mov)
        case .movHEVC: return .video(.hevcVT, .mov)
        case .movProRes: return .video(.proresVT, .mov)
        case .webmVP9: return .video(.vp9, .webm)
        case .webmAV1: return .video(.svtAV1, .webm)
        case .mkvHEVC: return .video(.hevcVT, .mkv)
        case .gifAnimated, .gif: return .gif
        case .webpAnimated, .webp: return .animatedWebP
        case .mp3: return .audio(.mp3, container: "mp3", ext: "mp3")
        case .m4aAAC: return .audio(.aac, container: "ipod", ext: "m4a")
        case .m4aALAC: return .audio(.alac, container: "ipod", ext: "m4a")
        case .wav: return .audio(.pcm16, container: "wav", ext: "wav")
        case .aiff: return .audio(.pcm16, container: "aiff", ext: "aiff")
        case .flac: return .audio(.flac, container: "flac", ext: "flac")
        case .opus: return .audio(.opus, container: "opus", ext: "opus")
        case .frameJPEG: return .frame(ext: "jpg")
        case .framePNG: return .frame(ext: "png")
        case .original:
            if item.kind == .audio || info.video == nil {
                return resolveAudioOriginal(item: item, info: info)
            }
            return resolveVideoOriginal(item: item, info: info)
        default:
            return .video(.h264VT, .mp4)
        }
    }

    static func resolveVideoOriginal(item: MediaItem, info: AVInfo) -> Resolved {
        let container: VideoContainer = switch item.format {
        case .mov: .mov
        case .m4v: .m4v
        case .mkv: .mkv
        case .webm: .webm
        default: .mp4
        }
        let encoder: VideoEncoder = switch info.video?.codec {
        case "hevc": .hevcVT
        case "prores": .proresVT
        case "vp9": .vp9
        case "av1": .svtAV1
        default: .h264VT
        }
        if !encoder.isSupported(in: container) {
            return .video(container == .webm ? .vp9 : .h264VT, container)
        }
        return .video(encoder, container)
    }

    static func resolveAudioOriginal(item: MediaItem, info: AVInfo) -> Resolved {
        switch item.format {
        case .mp3: return .audio(.mp3, container: "mp3", ext: "mp3")
        case .m4a, .aac:
            return info.audio?.codec == "alac"
                ? .audio(.alac, container: "ipod", ext: "m4a") : .audio(.aac, container: "ipod", ext: "m4a")
        case .wav: return .audio(.pcm16, container: "wav", ext: "wav")
        case .aiff: return .audio(.pcm16, container: "aiff", ext: "aiff")
        case .flac: return .audio(.flac, container: "flac", ext: "flac")
        case .opus, .ogg: return .audio(.opus, container: "opus", ext: "opus")
        default: return .audio(.mp3, container: "mp3", ext: "mp3")
        }
    }

    // MARK: - Video

    static func planVideo(_ plan: inout MediaPlan, encoder: VideoEncoder, video: VideoStreamInfo, info: AVInfo,
                          options v: VideoOptions, container: VideoContainer) throws {
        if encoder == .copy {
            plan.outputSize = CGSizeInt(width: video.displayWidth, height: video.displayHeight)
            return
        }
        // Size and frame rate
        var size = v.resolution.apply(width: video.displayWidth, height: video.displayHeight,
                                      allowUpscale: v.allowUpscale)
        if v.rotation == .clockwise90 || v.rotation == .clockwise270 {
            size = CGSizeInt(width: size.height, height: size.width)
        }
        plan.outputSize = size
        if case .fps(let fps) = v.frameRate, fps < video.frameRate - 0.01 || v.allowUpscale {
            plan.outputFrameRate = fps
        }
        let fps = plan.outputFrameRate ?? video.frameRate
        plan.keyframeInterval = max(1, Int((fps * max(0.5, v.keyframeSeconds)).rounded()))

        // HDR / bit depth
        let canCarryHDR = [.hevc, .av1, .vp9, .prores].contains(encoder.family)
        if video.isHDR {
            if v.hdr == .automatic && canCarryHDR {
                plan.keepHDR = true
                plan.tenBit = true
            } else {
                plan.toneMap = v.toneMapper
            }
        }
        switch v.bitDepth {
        case .eight: plan.tenBit = false
        case .ten: plan.tenBit = encoder.family != .h264
        case .automatic:
            if !plan.keepHDR && video.bitDepth > 8 && encoder.family != .h264 && plan.toneMap == nil {
                plan.tenBit = true
            }
        }
        if plan.keepHDR && !plan.tenBit { plan.keepHDR = false; plan.toneMap = v.toneMapper }

        // Rate control
        if encoder == .proresVT {
            plan.proresProfile = v.proresProfile ?? ProResProfile.forQuality(v.quality)
            return
        }
        if let limit = v.sizeLimit, limit > 0 {
            let audioBits = plannedAudioBitrate(info: info, options: v)
            let total = Double(limit) * 8 * 0.97 / max(1, plan.duration)
            var videoBits = Int(total) - audioBits
            videoBits = max(80_000, videoBits)
            plan.videoBitrate = videoBits
            // Too few bits for this resolution: lower it automatically.
            let bpp = Double(videoBits) / Double(size.pixels) / fps
            if bpp < 0.035, case .original = v.resolution {
                let scale = (bpp / 0.05).squareRoot()
                let target = max(240, Int(Double(min(size.width, size.height)) * scale))
                plan.outputSize = ResolutionPreset.shortSide(target).apply(width: size.width, height: size.height,
                                                                            allowUpscale: false)
            }
            plan.twoPass = [.x264, .vp9].contains(encoder)
            return
        }
        switch v.rateControl {
        case .automatic:
            plan.videoBitrate = VideoBitrateModel.bitrate(quality: v.quality, family: encoder.family,
                                                          size: plan.outputSize ?? size, fps: fps, source: video,
                                                          sourceSize: CGSizeInt(width: video.displayWidth,
                                                                                height: video.displayHeight))
        case .constantQuality:
            plan.constantQuality = v.constantQuality
        case .averageBitrate:
            plan.videoBitrate = max(50, v.bitrateKbps) * 1000
        }
    }

    static func planAnimation(_ plan: inout MediaPlan, video: VideoStreamInfo, options v: VideoOptions, gif: Bool) {
        let q = v.quality
        let defaultFPS: Double = gif ? (q < 0.3 ? 10 : q < 0.6 ? 12 : q < 0.85 ? 15 : 20) : (q < 0.5 ? 12 : q < 0.8 ? 15 : 24)
        let fps = min(v.gif.fps ?? defaultFPS, video.frameRate)
        let defaultWidth = gif ? (q < 0.3 ? 320 : q < 0.6 ? 480 : q < 0.85 ? 640 : 800) : (q < 0.5 ? 480 : q < 0.8 ? 640 : 960)
        let width = min(v.gif.maxWidth ?? defaultWidth, video.displayWidth)
        plan.animationFPS = fps
        plan.animationWidth = max(16, width - width % 2)
        let height = Int(Double(video.displayHeight) * Double(plan.animationWidth!) / Double(max(1, video.displayWidth)))
        plan.outputSize = CGSizeInt(width: plan.animationWidth!, height: max(2, height))
        if gif {
            plan.gifColors = v.gif.colors ?? (q < 0.3 ? 64 : q < 0.6 ? 128 : 256)
            plan.gifDither = switch v.gif.dither {
            case .automatic: q < 0.5 ? "bayer:bayer_scale=4" : "sierra2_4a"
            case .none: "none"
            case .bayer: "bayer:bayer_scale=3"
            case .floydSteinberg: "floyd_steinberg"
            case .sierra: "sierra2_4a"
            }
        } else {
            plan.webpQuality = Int((ImageEncoder.lossyQuality(q) * 100).rounded())
        }
    }

    // MARK: - Audio

    /// Audio bitrate (bps) implied by video options, for estimates and target sizes.
    static func plannedAudioBitrate(info: AVInfo, options v: VideoOptions) -> Int {
        guard v.audio.enabled, let audio = info.audio else { return 0 }
        if let kbps = v.audio.bitrateKbps { return kbps * 1000 }
        if v.audio.encoder == .copy { return audio.bitRate ?? 160_000 }
        let channels = v.audio.channels == .mono ? 1 : min(2, audio.channels)
        let perChannel = v.quality < 0.3 ? 48_000 : v.quality < 0.6 ? 64_000 : v.quality < 0.85 ? 80_000 : 96_000
        return perChannel * channels
    }

    static func planTrackAudio(_ plan: inout MediaPlan, info: AVInfo, options v: VideoOptions, container: VideoContainer,
                               capabilities: FFmpegCapabilities?) {
        guard v.audio.enabled, let audio = info.audio else {
            plan.audioEncoder = nil
            plan.audioStreamIndex = nil
            return
        }
        var encoder = v.audio.encoder
        if encoder == .automatic {
            switch container {
            case .webm: encoder = .opus
            case .mkv:
                let copyable = ["aac", "mp3", "opus", "flac", "ac3", "eac3", "vorbis", "alac"].contains(audio.codec)
                    || audio.codec.hasPrefix("pcm_")
                encoder = copyable && v.trim == nil ? .copy : .aac
            case .mov where plan.videoEncoder == .proresVT: encoder = .pcm16
            default: encoder = .aac
            }
        }
        // Keep the container legal.
        if container == .webm && ![.opus, .copy].contains(encoder) { encoder = .opus }
        if [.mp4, .m4v].contains(container) && [.pcm16, .pcm24].contains(encoder) { encoder = .alac }
        plan.audioEncoder = encoder
        plan.audioStreamIndex = audio.index
        plan.audioSampleRate = v.audio.sampleRate
        plan.audioChannels = v.audio.channels == .mono ? 1 : v.audio.channels == .stereo ? 2 : (audio.channels > 2 ? 2 : nil)
        if !encoder.isLossless && encoder != .copy {
            plan.audioBitrate = plannedAudioBitrate(info: info, options: v)
        }
    }

    static func planAudio(_ plan: inout MediaPlan, encoder: AudioEncoder, container: String, ext: String, info: AVInfo,
                          options a: AudioOptions, capabilities: FFmpegCapabilities?) throws {
        guard let audio = info.audio else { throw MediaPlanError("This file has no audio track.") }
        plan.mode = .audioOnly
        plan.container = container
        plan.fileExtension = ext
        plan.videoEncoder = nil
        plan.videoStreamIndex = nil
        plan.audioEncoder = encoder
        plan.audioStreamIndex = audio.index
        plan.audioSampleRate = a.sampleRate
        plan.audioChannels = a.channels == .mono ? 1 : a.channels == .stereo ? 2 : nil
        plan.normalizeLoudness = a.normalizeLoudness
        plan.trim = a.trim
        plan.duration = a.trim?.duration(of: info.duration) ?? info.duration
        plan.stripMetadata = a.stripMetadata
        plan.customArguments = ShellWords.split(a.customArguments)
        plan.fastStart = container == "ipod"
        plan.keepCoverArt = a.keepCoverArt && info.hasCoverArt && ["mp3", "ipod", "flac"].contains(container)
        plan.coverArtIncluded = plan.keepCoverArt

        let channels = plan.audioChannels ?? min(2, audio.channels)
        switch encoder {
        case .mp3:
            if let kbps = a.bitrateKbps {
                plan.audioBitrate = kbps * 1000
            } else if a.variableBitrate {
                plan.mp3VBRQuality = max(0, min(9, Int(((1 - a.quality) * 7).rounded())))
            } else {
                plan.audioBitrate = AudioBitrateModel.lossyBitrate(quality: a.quality, codec: .mp3, channels: channels)
            }
        case .aac, .opus:
            plan.audioBitrate = (a.bitrateKbps.map { $0 * 1000 })
                ?? AudioBitrateModel.lossyBitrate(quality: a.quality, codec: encoder, channels: channels)
        default:
            plan.audioBitrate = nil
        }
        if let capabilities {
            if encoder == .mp3 && !capabilities.hasEncoder("libmp3lame") {
                throw MediaPlanError("This FFmpeg build can't write MP3.")
            }
            if encoder == .opus && !capabilities.hasEncoder("libopus") {
                throw MediaPlanError("This FFmpeg build can't write Opus.")
            }
        }
    }
}

/// Bitrate heuristics (bits per pixel per frame), calibrated for "good" H.264 at 1080p30.
public enum VideoBitrateModel {
    /// Relative bits needed vs. H.264 for similar quality.
    static func efficiency(_ family: VideoCodecFamily) -> Double {
        switch family {
        case .h264: 1.0
        case .hevc: 0.6
        case .av1: 0.5
        case .vp9: 0.65
        case .prores, .copy: 1.0
        }
    }

    static func family(ofCodec codec: String) -> VideoCodecFamily {
        switch codec {
        case "h264": .h264
        case "hevc": .hevc
        case "av1": .av1
        case "vp9": .vp9
        case "prores": .prores
        default: .h264
        }
    }

    /// Target bitrate (bps) for a 0…1 quality.
    public static func bitrate(quality: Double, family: VideoCodecFamily, size: CGSizeInt, fps: Double,
                               source: VideoStreamInfo?, sourceSize: CGSizeInt?) -> Int {
        let q = max(0, min(1, quality))
        // 0.025 … 0.25 bits per pixel per frame for H.264 at 1080p.
        let bpp = 0.025 * pow(10, q)
        let pixels = Double(max(1, size.pixels))
        let resolutionFactor = pow(2_073_600 / pixels, 0.25)
        let fpsFactor = pow(max(1, fps) / 30, 0.75)
        var bits = bpp * resolutionFactor * pixels * 30 * fpsFactor * efficiency(family)

        // Never inflate beyond what the source carries (scaled to the new size and codec).
        if let source, let sourceBits = source.bitRate, sourceBits > 0, let sourceSize {
            let sourceFamily = Self.family(ofCodec: source.codec)
            let ratio = efficiency(family) / efficiency(sourceFamily == .prores ? .h264 : sourceFamily)
            let sizeRatio = pow(pixels / Double(max(1, sourceSize.pixels)), 0.75)
            let cap = Double(sourceBits) * max(0.1, min(1.5, ratio)) * min(1, sizeRatio)
            bits = min(bits, max(cap, 150_000))
        }
        return max(100_000, Int(bits))
    }
}

public enum AudioBitrateModel {
    static let standard = [48, 64, 96, 128, 160, 192, 224, 256, 320]

    /// Stereo-equivalent bitrate for lossy codecs, snapped to common values.
    public static func lossyBitrate(quality: Double, codec: AudioEncoder, channels: Int) -> Int {
        let q = max(0, min(1, quality))
        let stereoKbps: Double = switch codec {
        case .opus: 48 + 144 * q        // 48 … 192
        case .mp3: 96 + 224 * q         // 96 … 320
        default: 64 + 192 * q           // AAC 64 … 256
        }
        let scaled = channels <= 1 ? stereoKbps * 0.55 : stereoKbps
        let snapped = standard.min { abs(Double($0) - scaled) < abs(Double($1) - scaled) } ?? 128
        return snapped * 1000
    }

    /// Typical LAME VBR bitrates (kbps) for -q:a 0…9.
    public static let mp3VBRKbps = [245, 225, 190, 175, 165, 130, 115, 100, 85, 65]
}
