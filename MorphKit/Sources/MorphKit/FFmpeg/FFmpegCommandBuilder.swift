import Foundation

/// Turns a `MediaPlan` into ffmpeg argument lists (one per pass). Pure — no I/O.
public enum FFmpegCommandBuilder {
    public static let commonPrefix = ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1",
                                      "-nostats"]

    /// - Parameters:
    ///   - passLogPrefix: temp path prefix for 2-pass statistics (required when `plan.twoPass`).
    public static func passes(plan: MediaPlan, input: URL, output: URL, passLogPrefix: URL? = nil,
                              capabilities: FFmpegCapabilities? = nil) -> [[String]] {
        switch plan.mode {
        case .audioOnly:
            return [audioOnlyArguments(plan: plan, input: input, output: output, capabilities: capabilities)]
        case .frame:
            return [frameArguments(plan: plan, input: input, output: output)]
        case .gif:
            return [gifArguments(plan: plan, input: input, output: output)]
        case .animatedWebP:
            return [webpArguments(plan: plan, input: input, output: output)]
        case .video:
            if plan.twoPass, let passLogPrefix {
                let first = videoArguments(plan: plan, input: input, output: output, pass: 1,
                                           passLog: passLogPrefix, capabilities: capabilities)
                let second = videoArguments(plan: plan, input: input, output: output, pass: 2,
                                            passLog: passLogPrefix, capabilities: capabilities)
                return [first, second]
            }
            return [videoArguments(plan: plan, input: input, output: output, pass: nil, passLog: nil,
                                   capabilities: capabilities)]
        }
    }

    // MARK: - Pieces

    static func number(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.3f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func inputArguments(plan: MediaPlan, input: URL, hardwareDecode: Bool) -> [String] {
        var args: [String] = []
        if hardwareDecode { args += ["-hwaccel", "videotoolbox"] }
        if let start = plan.trim?.start, start > 0 { args += ["-ss", number(start)] }
        args += ["-i", input.path]
        if plan.trim != nil, plan.trim?.end != nil { args += ["-t", number(plan.duration)] }
        return args
    }

    /// Filters for rotation, frame rate, scaling and tone mapping.
    static func videoFilters(plan: MediaPlan, pixelFormat: String?) -> [String] {
        var filters: [String] = []
        if let fps = plan.outputFrameRate { filters.append("fps=\(number(fps))") }
        switch plan.rotation {
        case .none: break
        case .clockwise90: filters.append("transpose=clock")
        case .clockwise180: filters += ["hflip", "vflip"]
        case .clockwise270: filters.append("transpose=cclock")
        }
        if plan.flipHorizontal { filters.append("hflip") }
        if plan.flipVertical { filters.append("vflip") }

        let size = plan.outputSize.map { "\($0.width):\($0.height)" } ?? "iw:ih"
        if let toneMap = plan.toneMap {
            switch toneMap {
            case .hable:
                filters += ["zscale=t=linear:npl=100", "format=gbrpf32le", "zscale=p=bt709",
                            "tonemap=tonemap=hable:desat=0", "zscale=t=bt709:m=bt709:r=tv",
                            "scale=\(size):flags=lanczos"]
            case .perceptual, .clip:
                let intent = toneMap == .perceptual ? "perceptual" : "relative_colorimetric"
                filters.append("scale=\(size):flags=lanczos:out_color_matrix=bt709:out_primaries=bt709"
                    + ":out_transfer=bt709:out_range=tv:intent=\(intent)")
            }
        } else if plan.outputSize != nil {
            filters.append("scale=\(size):flags=lanczos")
        }
        if let pixelFormat { filters.append("format=\(pixelFormat)") }
        return filters
    }

    static func pixelFormat(plan: MediaPlan, encoder: VideoEncoder) -> String? {
        switch encoder {
        case .copy, .proresVT: return nil
        case .h264VT, .x264: return "yuv420p"
        case .hevcVT: return plan.tenBit ? "p010le" : "yuv420p"
        case .x265, .svtAV1, .vp9: return plan.tenBit ? "yuv420p10le" : "yuv420p"
        }
    }

    static func speedPreset(_ speed: EncoderSpeed, for encoder: VideoEncoder) -> [String] {
        switch encoder {
        case .x264, .x265:
            let preset = ["fastest": "veryfast", "fast": "faster", "balanced": "medium", "slow": "slow",
                          "slowest": "veryslow"][speed.rawValue]!
            return ["-preset", preset]
        case .svtAV1:
            let preset = ["fastest": "12", "fast": "10", "balanced": "8", "slow": "6", "slowest": "4"][speed.rawValue]!
            return ["-preset", preset]
        case .vp9:
            let cpu = ["fastest": "8", "fast": "6", "balanced": "4", "slow": "2", "slowest": "1"][speed.rawValue]!
            return ["-deadline", "good", "-cpu-used", cpu, "-row-mt", "1"]
        case .h264VT, .hevcVT:
            return speed == .fastest || speed == .fast ? ["-prio_speed", "1"] : []
        case .proresVT, .copy:
            return []
        }
    }

    /// CRF / quality value for constant-quality mode (quality 0…1, higher is better).
    static func constantQualityArguments(_ q: Double, encoder: VideoEncoder) -> [String] {
        let q = max(0, min(1, q))
        switch encoder {
        case .h264VT, .hevcVT: return ["-q:v", String(Int((30 + 55 * q).rounded()))]
        case .x264: return ["-crf", String(Int((35 - 17 * q).rounded()))]
        case .x265: return ["-crf", String(Int((37 - 17 * q).rounded()))]
        case .svtAV1: return ["-crf", String(Int((55 - 30 * q).rounded()))]
        case .vp9: return ["-crf", String(Int((50 - 25 * q).rounded())), "-b:v", "0"]
        case .proresVT, .copy: return []
        }
    }

    static func videoEncoderArguments(plan: MediaPlan, encoder: VideoEncoder) -> [String] {
        var args = ["-c:v", encoder.ffmpegName]
        switch encoder {
        case .copy:
            return args
        case .proresVT:
            args += ["-profile:v", (plan.proresProfile ?? .hq).ffmpegProfile]
            return args
        case .h264VT:
            args += ["-profile:v", "high"]
        case .hevcVT:
            args += ["-profile:v", plan.tenBit ? "main10" : "main", "-tag:v", "hvc1"]
        case .x264:
            args += ["-profile:v", "high"]
        case .x265:
            args += ["-tag:v", "hvc1", "-x265-params", "log-level=error"]
        case .svtAV1, .vp9:
            if encoder == .vp9 && plan.tenBit { args += ["-profile:v", "2"] }
        }
        args += speedPreset(plan.speed, for: encoder)
        if let bitrate = plan.videoBitrate {
            args += ["-b:v", String(bitrate)]
            if encoder != .svtAV1 {
                args += ["-maxrate", String(Int(Double(bitrate) * 1.5)), "-bufsize", String(bitrate * 2)]
            }
        } else if let q = plan.constantQuality {
            args += constantQualityArguments(q, encoder: encoder)
        }
        if let gop = plan.keyframeInterval { args += ["-g", String(gop)] }
        return args
    }

    static func colorArguments(plan: MediaPlan) -> [String] {
        if plan.toneMap != nil {
            return ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        if plan.keepHDR {
            var args: [String] = []
            if let p = plan.sourcePrimaries { args += ["-color_primaries", p] }
            if let t = plan.sourceTransfer { args += ["-color_trc", t] }
            if let s = plan.sourceColorSpace { args += ["-colorspace", s] }
            return args
        }
        return []
    }

    static func audioEncoderArguments(plan: MediaPlan, capabilities: FFmpegCapabilities?) -> [String] {
        guard let encoder = plan.audioEncoder else { return ["-an"] }
        var args: [String]
        let aiff = plan.container == "aiff"
        switch encoder {
        case .automatic, .aac:
            let name = capabilities?.hasEncoder("aac_at") == false ? "aac" : "aac_at"
            args = ["-c:a", name]
            if let bitrate = plan.audioBitrate { args += ["-b:a", String(bitrate)] }
        case .opus:
            args = ["-c:a", "libopus", "-vbr", "on"]
            if let bitrate = plan.audioBitrate { args += ["-b:a", String(bitrate)] }
        case .mp3:
            args = ["-c:a", "libmp3lame"]
            if let q = plan.mp3VBRQuality {
                args += ["-q:a", String(q)]
            } else if let bitrate = plan.audioBitrate {
                args += ["-b:a", String(bitrate)]
            }
        case .flac: args = ["-c:a", "flac", "-compression_level", "8"]
        case .alac: args = ["-c:a", "alac"]
        case .pcm16: args = ["-c:a", aiff ? "pcm_s16be" : "pcm_s16le"]
        case .pcm24: args = ["-c:a", aiff ? "pcm_s24be" : "pcm_s24le"]
        case .copy: return ["-c:a", "copy"]
        }
        if let rate = plan.audioSampleRate { args += ["-ar", String(rate)] }
        if let channels = plan.audioChannels { args += ["-ac", String(channels)] }
        if plan.normalizeLoudness { args += ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] }
        return args
    }

    static func metadataArguments(plan: MediaPlan) -> [String] {
        var args = plan.stripMetadata ? ["-map_metadata", "-1", "-map_chapters", "-1"] : ["-map_metadata", "0"]
        var flags: [String] = []
        if plan.fastStart && ["mp4", "mov", "ipod"].contains(plan.container) { flags.append("+faststart") }
        if !plan.stripMetadata && plan.container == "mov" { flags.append("+use_metadata_tags") }
        if !flags.isEmpty { args += ["-movflags", flags.joined()] }
        return args
    }

    // MARK: - Modes

    static func videoArguments(plan: MediaPlan, input: URL, output: URL, pass: Int?, passLog: URL?,
                               capabilities: FFmpegCapabilities?) -> [String] {
        let encoder = plan.videoEncoder ?? .h264VT
        var args = commonPrefix
        args += inputArguments(plan: plan, input: input, hardwareDecode: encoder != .copy)
        if let v = plan.videoStreamIndex { args += ["-map", "0:\(v)"] }
        if let a = plan.audioStreamIndex, plan.audioEncoder != nil, pass != 1 { args += ["-map", "0:\(a)"] }

        if encoder != .copy {
            let filters = videoFilters(plan: plan, pixelFormat: pixelFormat(plan: plan, encoder: encoder))
            if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        }
        args += videoEncoderArguments(plan: plan, encoder: encoder)
        args += colorArguments(plan: plan)

        if let pass, let passLog {
            args += ["-pass", String(pass), "-passlogfile", passLog.path]
            if pass == 1 {
                return args + ["-an", "-f", "null", "/dev/null"]
            }
        }
        args += plan.audioStreamIndex != nil ? audioEncoderArguments(plan: plan, capabilities: capabilities) : ["-an"]
        args += metadataArguments(plan: plan)
        args += plan.customArguments
        args += ["-f", plan.container, output.path]
        return args
    }

    static func gifArguments(plan: MediaPlan, input: URL, output: URL) -> [String] {
        var args = commonPrefix + inputArguments(plan: plan, input: input, hardwareDecode: true)
        let fps = plan.animationFPS ?? 12
        let width = plan.animationWidth ?? 480
        var pre = ["fps=\(number(fps))"]
        if plan.toneMap != nil {
            pre.append("scale=\(width):-1:flags=lanczos:out_color_matrix=bt709:out_primaries=bt709:out_transfer=bt709:out_range=tv:intent=perceptual")
        } else {
            pre.append("scale=\(width):-1:flags=lanczos")
        }
        let colors = plan.gifColors ?? 256
        let dither = plan.gifDither ?? "sierra2_4a"
        let graph = "[0:v:0]\(pre.joined(separator: ",")),split[a][b];[a]palettegen=max_colors=\(colors):stats_mode=diff[p];"
            + "[b][p]paletteuse=dither=\(dither):diff_mode=rectangle"
        args += ["-filter_complex", graph, "-loop", "0"]
        args += plan.customArguments
        args += ["-f", "gif", output.path]
        return args
    }

    static func webpArguments(plan: MediaPlan, input: URL, output: URL) -> [String] {
        var args = commonPrefix + inputArguments(plan: plan, input: input, hardwareDecode: true)
        if let v = plan.videoStreamIndex { args += ["-map", "0:\(v)"] }
        let fps = plan.animationFPS ?? 15
        let width = plan.animationWidth ?? 640
        var filters = ["fps=\(number(fps))"]
        if plan.toneMap != nil {
            filters.append("scale=\(width):-1:flags=lanczos:out_color_matrix=bt709:out_primaries=bt709:out_transfer=bt709:out_range=tv:intent=perceptual")
        } else {
            filters.append("scale=\(width):-1:flags=lanczos")
        }
        args += ["-vf", filters.joined(separator: ","), "-c:v", "libwebp_anim", "-quality",
                 String(plan.webpQuality ?? 75), "-compression_level", "4", "-loop", "0", "-an"]
        args += plan.customArguments
        args += ["-f", "webp", output.path]
        return args
    }

    static func frameArguments(plan: MediaPlan, input: URL, output: URL) -> [String] {
        var args = commonPrefix + ["-ss", number(plan.frameTime), "-i", input.path]
        if let v = plan.videoStreamIndex { args += ["-map", "0:\(v)"] }
        if plan.toneMap != nil {
            args += ["-vf", "scale=iw:ih:flags=lanczos:out_color_matrix=bt709:out_primaries=bt709:out_transfer=bt709:out_range=pc:intent=perceptual"]
        }
        args += ["-frames:v", "1", "-update", "1", "-c:v", "png", "-f", "image2", output.path]
        return args
    }

    static func audioOnlyArguments(plan: MediaPlan, input: URL, output: URL,
                                   capabilities: FFmpegCapabilities?) -> [String] {
        var args = commonPrefix + inputArguments(plan: plan, input: input, hardwareDecode: false)
        if let a = plan.audioStreamIndex { args += ["-map", "0:\(a)"] }
        if plan.keepCoverArt {
            args += ["-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic"]
        } else {
            args += ["-vn"]
        }
        args += audioEncoderArguments(plan: plan, capabilities: capabilities)
        args += metadataArguments(plan: plan)
        if plan.container == "mp3" { args += ["-id3v2_version", "3"] }
        args += plan.customArguments
        args += ["-f", plan.container, output.path]
        return args
    }

    /// A copy-pasteable command line for "Show command".
    public static func displayCommand(passes: [[String]]) -> String {
        passes.map { (["ffmpeg"] + $0.filter { !["-progress", "pipe:1", "-nostats"].contains($0) })
            .map(ShellWords.quote).joined(separator: " ") }
            .joined(separator: " && \\\n")
    }
}
