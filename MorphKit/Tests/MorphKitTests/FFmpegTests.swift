import Foundation
import Testing
@testable import MorphKit

@Suite("FFmpeg planning and commands")
struct FFmpegCommandTests {
    static let caps = FFmpegCapabilities(
        version: "9.0.1",
        encoders: ["h264_videotoolbox", "hevc_videotoolbox", "prores_videotoolbox", "libx264", "libx265",
                   "libsvtav1", "libvpx-vp9", "libwebp_anim", "libmp3lame", "libopus", "aac_at", "aac", "flac", "alac"],
        filters: ["scale", "zscale", "tonemap", "palettegen", "paletteuse"])

    static func videoItem(codec: String = "h264", width: Int = 1920, height: Int = 1080, rotation: Int = 0,
                          transfer: String? = nil, pixFmt: String = "yuv420p", audioCodec: String? = "aac",
                          format: FileFormat = .mov, duration: Double = 60, bitrate: Int = 12_000_000) -> MediaItem {
        let video = VideoStreamInfo(index: 0, codec: codec, width: width, height: height, rotation: rotation,
                                    frameRate: 30, bitRate: bitrate, pixelFormat: pixFmt, colorTransfer: transfer,
                                    colorPrimaries: transfer == nil ? nil : "bt2020",
                                    colorSpace: transfer == nil ? nil : "bt2020nc")
        let audio = audioCodec.map { AudioStreamInfo(index: 2, codec: $0, sampleRate: 48000, channels: 2, bitRate: 256_000) }
        let info = AVInfo(duration: duration, bitRate: bitrate + 256_000, formatName: "mov,mp4", video: video,
                          audio: audio, audioStreamCount: audio == nil ? 0 : 1, hasCoverArt: false)
        return MediaItem(url: URL(filePath: "/in/clip.\(format.preferredExtension)"), format: format,
                         fileSize: 100_000_000, modificationDate: .distantPast, info: .media(info))
    }

    static func args(_ item: MediaItem, _ settings: ConversionSettings) throws -> [[String]] {
        let plan = try MediaPlanner.plan(item: item, info: item.info!.media!, settings: settings, capabilities: caps)
        return FFmpegCommandBuilder.passes(plan: plan, input: item.url, output: URL(filePath: "/out/o.\(plan.fileExtension)"),
                                           passLogPrefix: URL(filePath: "/tmp/pass"), capabilities: caps)
    }

    func joined(_ passes: [[String]]) -> String { passes.map { $0.joined(separator: " ") }.joined(separator: " && ") }

    @Test func mp4H264HardwareUsesBitrateModel() throws {
        let cmd = joined(try Self.args(Self.videoItem(), ConversionSettings(target: .mp4H264)))
        #expect(cmd.contains("-hwaccel videotoolbox"))
        #expect(cmd.contains("-map 0:0 -map 0:2"))
        #expect(cmd.contains("-c:v h264_videotoolbox -profile:v high"))
        #expect(cmd.contains("-b:v "))
        #expect(cmd.contains("-g 60"))
        #expect(cmd.contains("-c:a aac_at -b:a"))
        #expect(cmd.contains("-movflags +faststart"))
        #expect(cmd.hasSuffix("-f mp4 /out/o.mp4"))
        #expect(!cmd.contains("-allow_sw"))
    }

    @Test func hdrKeptForHEVC() throws {
        let item = Self.videoItem(codec: "hevc", transfer: "arib-std-b67", pixFmt: "yuv420p10le")
        let cmd = joined(try Self.args(item, ConversionSettings(target: .mp4HEVC)))
        #expect(cmd.contains("-profile:v main10 -tag:v hvc1"))
        #expect(cmd.contains("format=p010le"))
        #expect(cmd.contains("-color_trc arib-std-b67"))
        #expect(!cmd.contains("intent=perceptual"))
    }

    @Test func hdrToneMappedForH264() throws {
        let item = Self.videoItem(codec: "hevc", transfer: "arib-std-b67", pixFmt: "yuv420p10le")
        let cmd = joined(try Self.args(item, ConversionSettings(target: .mp4H264)))
        #expect(cmd.contains("out_transfer=bt709:out_range=tv:intent=perceptual"))
        #expect(cmd.contains("format=yuv420p"))
        #expect(cmd.contains("-color_trc bt709"))
    }

    @Test func resolutionAndFrameRate() throws {
        var settings = ConversionSettings(target: .mp4H264)
        settings.video.resolution = .shortSide(720)
        settings.video.frameRate = .fps(24)
        let cmd = joined(try Self.args(Self.videoItem(width: 3840, height: 2160), settings))
        #expect(cmd.contains("fps=24,scale=1280:720:flags=lanczos"))
        #expect(cmd.contains("-g 48"))
    }

    @Test func portraitVideoScalesShortSide() throws {
        var settings = ConversionSettings(target: .mp4H264)
        settings.video.resolution = .shortSide(1080)
        // Coded 3840x2160 rotated 90° → displayed 2160x3840.
        let cmd = joined(try Self.args(Self.videoItem(width: 3840, height: 2160, rotation: 90), settings))
        #expect(cmd.contains("scale=1080:1920"))
    }

    @Test func webmVP9ConstantQualityPro() throws {
        var settings = ConversionSettings(target: .webmVP9)
        settings.video.rateControl = .constantQuality
        settings.video.constantQuality = 0.6
        let cmd = joined(try Self.args(Self.videoItem(), settings))
        #expect(cmd.contains("-c:v libvpx-vp9"))
        #expect(cmd.contains("-crf 35 -b:v 0"))
        #expect(cmd.contains("-row-mt 1"))
        #expect(cmd.contains("-c:a libopus"))
        #expect(cmd.hasSuffix("-f webm /out/o.webm"))
    }

    @Test func svtAV1() throws {
        var settings = ConversionSettings(target: .mp4AV1)
        settings.video.speed = .fast
        let cmd = joined(try Self.args(Self.videoItem(), settings))
        #expect(cmd.contains("-c:v libsvtav1 -preset 10 -b:v"))
    }

    @Test func proResProfileFromSlider() throws {
        var settings = ConversionSettings(target: .movProRes)
        settings.video.quality = 0.9
        let cmd = joined(try Self.args(Self.videoItem(), settings))
        #expect(cmd.contains("-c:v prores_videotoolbox -profile:v hq"))
        #expect(cmd.contains("-c:a pcm_s16le"))
        #expect(!cmd.contains("-g "))
    }

    @Test func targetSizeUsesTwoPassForX264() throws {
        var settings = ConversionSettings(target: .mp4H264)
        settings.video.encoder = .x264
        settings.video.sizeLimit = 25_000_000
        let passes = try Self.args(Self.videoItem(duration: 60), settings)
        #expect(passes.count == 2)
        #expect(joined([passes[0]]).contains("-pass 1 -passlogfile /tmp/pass -an -f null /dev/null"))
        #expect(joined([passes[1]]).contains("-pass 2"))
        // (25 MB * 8 * 0.97 / 60 s) - 160 kbps audio ≈ 3.07 Mbps video.
        let bitrate = passes[1][passes[1].firstIndex(of: "-b:v")! + 1]
        #expect((2_900_000...3_200_000).contains(Int(bitrate)!))
    }

    @Test func removeAudioAndTrim() throws {
        var settings = ConversionSettings(target: .mp4HEVC)
        settings.video.audio.enabled = false
        settings.video.trim = TrimRange(start: 5, end: 15)
        let cmd = joined(try Self.args(Self.videoItem(), settings))
        #expect(cmd.contains("-ss 5 -i /in/clip.mov -t 10"))
        #expect(cmd.contains("-an"))
        #expect(!cmd.contains("-map 0:2"))
    }

    @Test func remuxCopiesStreams() throws {
        var settings = ConversionSettings(target: .mkvHEVC)
        settings.video.encoder = .copy
        let cmd = joined(try Self.args(Self.videoItem(), settings))
        #expect(cmd.contains("-c:v copy"))
        #expect(!cmd.contains("-hwaccel"))
        #expect(!cmd.contains("-vf"))
    }

    @Test func gifPalette() throws {
        var settings = ConversionSettings(target: .gifAnimated)
        settings.video.quality = 0.9
        let cmd = joined(try Self.args(Self.videoItem(), settings))
        #expect(cmd.contains("palettegen=max_colors=256:stats_mode=diff"))
        #expect(cmd.contains("paletteuse=dither=sierra2_4a"))
        #expect(cmd.contains("fps=20,scale=800:-1"))
    }

    @Test func mp3ExtractionVBR() throws {
        var settings = ConversionSettings(target: .mp3)
        settings.audio.quality = 1
        let cmd = joined(try Self.args(Self.videoItem(), settings))
        #expect(cmd.contains("-map 0:2 -vn -c:a libmp3lame -q:a 0"))
        #expect(cmd.hasSuffix("-f mp3 /out/o.mp3"))
    }

    @Test func noCompatibleEncoderIsAnError() {
        var settings = ConversionSettings(target: .webmVP9)
        settings.video.encoder = .h264VT
        #expect(throws: MediaPlanError.self) { try Self.args(Self.videoItem(), settings) }
    }

    @Test func iPhoneSpatialAudioIsSkipped() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_name":"hevc","codec_type":"video","width":3840,"height":2160,"pix_fmt":"yuv420p10le",
           "color_transfer":"arib-std-b67","avg_frame_rate":"30/1","side_data_list":[{"rotation":-90}]},
          {"index":1,"codec_name":"apac","codec_type":"audio","channels":4,"sample_rate":"48000"},
          {"index":2,"codec_name":"aac","codec_type":"audio","channels":2,"sample_rate":"44100","disposition":{"default":1}},
          {"index":3,"codec_type":"data","codec_name":"none"}
        ],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"12.5","bit_rate":"40000000"}}
        """
        let info = try FFProbe.parse(json: Data(json.utf8))
        #expect(info.audio?.index == 2)
        #expect(info.video?.rotation == 90)
        #expect(info.video?.displayWidth == 2160)
        #expect(info.isHDR)
        #expect(info.duration == 12.5)
    }

    @Test func progressParsing() {
        var parser = ProgressParser()
        for line in ["frame=10", "out_time_us=2500000", "speed=2.5x", "total_size=1234"] {
            #expect(parser.consume(line) == nil)
        }
        let update = parser.consume("progress=continue")
        #expect(update == FFmpegProgress(outTime: 2.5, speed: 2.5, totalSize: 1234, finished: false))
        #expect(parser.consume("progress=end")?.finished == true)
    }

    @Test func shellWords() {
        #expect(ShellWords.split(#"-metadata title="My Movie" -tune 'film grain' a\ b"#)
            == ["-metadata", "title=My Movie", "-tune", "film grain", "a b"])
    }
}

@Suite("Output naming")
struct OutputTests {
    static func item(_ path: String) -> MediaItem {
        MediaItem(url: URL(filePath: path), format: FileFormat.detect(url: URL(filePath: path))!, fileSize: 1,
                  modificationDate: .distantPast)
    }

    @Test func namesNextToOriginal() {
        let planner = OutputPlanner(destination: .nextToOriginal)
        #expect(planner.url(for: Self.item("/a/b/photo.HEIC"), fileExtension: "jpg").path == "/a/b/photo.jpg")
        #expect(planner.url(for: Self.item("/a/b/photo.jpg"), fileExtension: "jpg").path == "/a/b/photo-compressed.jpg")
    }

    @Test func namesInFolder() {
        let planner = OutputPlanner(destination: .folder(URL(filePath: "/out")), template: "{name}-web")
        #expect(planner.url(for: Self.item("/a/b/photo.png"), fileExtension: "webp").path == "/out/photo-web.webp")
    }

    @Test func collisionsGetNumbered() throws {
        let dir = Fixtures.directory.appending(path: "collide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: "photo.jpg")
        let first = try AtomicWriter.write(Data([1]), to: target, policy: .keepBoth)
        let second = try AtomicWriter.write(Data([2]), to: target, policy: .keepBoth)
        let third = try AtomicWriter.write(Data([3]), to: target, policy: .keepBoth)
        #expect(first?.lastPathComponent == "photo.jpg")
        #expect(second?.lastPathComponent == "photo 2.jpg")
        #expect(third?.lastPathComponent == "photo 3.jpg")
        let skipped = try AtomicWriter.write(Data([4]), to: target, policy: .skip)
        #expect(skipped == nil)
        // The original is protected even with "replace".
        let replaced = try AtomicWriter.write(Data([5]), to: target, policy: .replace, protecting: [target.path])
        #expect(replaced?.lastPathComponent == "photo 4.jpg")
    }

    @Test func parallelWritersNeverClobber() async throws {
        let dir = Fixtures.directory.appending(path: "race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: "clip.mp4")
        let urls = try await withThrowingTaskGroup(of: URL?.self) { group in
            for i in 0..<16 {
                group.addTask { try AtomicWriter.write(Data([UInt8(i)]), to: target, policy: .keepBoth) }
            }
            return try await group.reduce(into: [URL]()) { if let u = $1 { $0.append(u) } }
        }
        #expect(Set(urls).count == 16)
    }

    @Test func policyScalesWithMachine() {
        let policy = ConcurrencyPolicy(cpuBudget: 12, mediaEngines: 2, memoryBudget: 8 << 30)
        let image = ConversionJob(items: [OutputTests.item("/a/x.png")], settings: ConversionSettings(target: .jpeg),
                                  destination: URL(filePath: "/a/x.jpg"))
        #expect(policy.requirement(for: image, capabilities: nil).cpu == 1)
        let video = ConversionJob(items: [FFmpegCommandTests.videoItem()], settings: ConversionSettings(target: .mp4H264),
                                  destination: URL(filePath: "/a/x.mp4"))
        let hw = policy.requirement(for: video, capabilities: FFmpegCommandTests.caps)
        #expect(hw.engine && hw.cpu == 2)
        var sw = ConversionSettings(target: .mp4H264)
        sw.video.encoder = .x264
        let swJob = ConversionJob(items: [FFmpegCommandTests.videoItem()], settings: sw, destination: URL(filePath: "/a/x.mp4"))
        #expect(policy.requirement(for: swJob, capabilities: FFmpegCommandTests.caps).cpu == 12)
    }
}
