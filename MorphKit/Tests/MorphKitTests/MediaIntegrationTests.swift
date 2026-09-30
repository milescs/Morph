import Foundation
import Testing
@testable import MorphKit

/// End-to-end conversions through a real ffmpeg (bundled static build, or Homebrew in development).
@Suite("Media conversions (real ffmpeg)", .serialized)
struct MediaIntegrationTests {
    struct Env {
        let tools: FFmpegTools
        let caps: FFmpegCapabilities
        let engine: FFmpegEngine
        let clip: MediaItem
    }

    static func env() async throws -> Env? {
        guard let tools = Fixtures.tools,
              let url = try await Fixtures.video(name: "clip.mp4", seconds: 4, size: "1280x720") else { return nil }
        let caps = try await FFmpegCapabilities.load(for: tools)
        return Env(tools: tools, caps: caps, engine: FFmpegEngine(tools: tools, capabilities: caps),
                   clip: try await Fixtures.item(url))
    }

    func probe(_ url: URL, _ env: Env) async throws -> AVInfo {
        try await FFProbe.probe(url: url, tools: env.tools)
    }

    func convert(_ env: Env, _ settings: ConversionSettings, item: MediaItem? = nil) async throws -> (URL, AVInfo?) {
        let source = item ?? env.clip
        let ext = FormatRegistry.outputExtension(for: source, settings: settings, capabilities: env.caps)
        let out = Fixtures.directory.appending(path: "out-\(UUID().uuidString.prefix(6)).\(ext)")
        let sourceInfo = try await env.engine.mediaInfo(for: source)
        _ = try await env.engine.convert(item: source, info: sourceInfo, settings: settings, output: out)
        let info = ext == "jpg" || ext == "png" ? nil : try await probe(out, env)
        return (out, info)
    }

    @Test func probesGeneratedClip() async throws {
        guard let env = try await Self.env() else { return }
        let info = try #require(env.clip.info?.media)
        #expect(info.video?.width == 1280)
        #expect(abs(info.duration - 4) < 0.2)
        #expect(info.audio != nil)
    }

    @Test func h264HardwareWithResize() async throws {
        guard let env = try await Self.env() else { return }
        var settings = ConversionSettings(target: .mp4H264)
        settings.video.resolution = .shortSide(360)
        let (_, info) = try await convert(env, settings)
        #expect(info?.video?.codec == "h264")
        #expect(info?.video?.height == 360)
        #expect(info?.video?.width == 640)
        #expect(info?.audio?.codec == "aac")
    }

    @Test func hevcWithoutAudio() async throws {
        guard let env = try await Self.env() else { return }
        var settings = ConversionSettings(target: .movHEVC)
        settings.video.audio.enabled = false
        let (_, info) = try await convert(env, settings)
        #expect(info?.video?.codec == "hevc")
        #expect(info?.audio == nil)
    }

    @Test func webmVP9() async throws {
        guard let env = try await Self.env(), env.caps.hasEncoder("libvpx-vp9") else { return }
        var settings = ConversionSettings(target: .webmVP9)
        settings.video.speed = .fastest
        let (_, info) = try await convert(env, settings)
        #expect(info?.video?.codec == "vp9")
        #expect(info?.audio?.codec == "opus")
    }

    @Test func animatedGIF() async throws {
        guard let env = try await Self.env() else { return }
        var settings = ConversionSettings(target: .gifAnimated)
        settings.video.quality = 0.2
        let (url, info) = try await convert(env, settings)
        #expect(info?.video?.codec == "gif")
        #expect(info?.video?.width == 320)
        let estimate = try await env.engine.sampleEstimate(item: env.clip, info: env.clip.info!.media!, settings: settings)
        let actual = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(abs(Double(estimate) / Double(actual) - 1) < 0.35, "estimate \(estimate) vs actual \(actual)")
    }

    @Test func mp3Extraction() async throws {
        guard let env = try await Self.env(), env.caps.hasEncoder("libmp3lame") else { return }
        let (_, info) = try await convert(env, ConversionSettings(target: .mp3))
        #expect(info?.audio?.codec == "mp3")
        #expect(info?.video == nil)
    }

    @Test func frameGrab() async throws {
        guard let env = try await Self.env() else { return }
        var settings = ConversionSettings(target: .frameJPEG)
        settings.video.frameTime = 1
        let (url, _) = try await convert(env, settings)
        #expect(Fixtures.decodedSize(try Data(contentsOf: url)) == CGSize(width: 1280, height: 720))
    }

    @Test func bitrateEstimateMatches() async throws {
        guard let env = try await Self.env() else { return }
        var settings = ConversionSettings(target: .mp4H264)
        settings.video.rateControl = .averageBitrate
        settings.video.bitrateKbps = 2000
        let estimate = try #require(SizeEstimator.quickEstimate(item: env.clip, settings: settings, capabilities: env.caps))
        let (url, _) = try await convert(env, settings)
        let actual = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(abs(Double(estimate.bytes) / Double(actual) - 1) < 0.3, "estimate \(estimate.bytes) vs actual \(actual)")
    }

    @Test func sizeLimitIsHonored() async throws {
        guard let env = try await Self.env() else { return }
        var settings = ConversionSettings(target: .mp4H264)
        settings.video.sizeLimit = 400_000
        let (url, _) = try await convert(env, settings)
        let actual = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(actual <= 440_000, "actual \(actual)")
    }

    @Test func gifToMP4() async throws {
        guard let env = try await Self.env() else { return }
        let gif = try await Fixtures.item(Fixtures.animatedGIF(frames: 12))
        let (_, info) = try await convert(env, ConversionSettings(target: .mp4H264), item: gif)
        #expect(info?.video?.codec == "h264")
    }

    @Test func queueRunsJobsAndCommits() async throws {
        guard let env = try await Self.env() else { return }
        let cache = EstimateCache()
        let pipeline = ConversionPipeline(ffmpeg: env.engine, cache: cache)
        let queue = ConversionQueue(pipeline: pipeline, policy: ConcurrencyPolicy(cpuBudget: 4, mediaEngines: 2,
                                                                                  memoryBudget: 1 << 30))
        let dir = Fixtures.directory.appending(path: "queue-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let planner = OutputPlanner(destination: .folder(dir))
        let image = try await Fixtures.item(Fixtures.pngWithAlpha())
        var jobs: [ConversionJob] = []
        jobs.append(ConversionJob(items: [image], settings: ConversionSettings(target: .webp),
                                  destination: planner.url(for: image, fileExtension: "webp")))
        jobs.append(ConversionJob(items: [env.clip], settings: ConversionSettings(target: .mp4HEVC),
                                  destination: planner.url(for: env.clip, fileExtension: "mp4")))
        await queue.enqueue(jobs)
        var finished = 0
        for await event in queue.events {
            switch event {
            case .finished(_, let outcome):
                #expect(outcome.output != nil)
                #expect(outcome.bytes > 0)
                finished += 1
            case .failed(_, let message, _, _):
                Issue.record("job failed: \(message)")
                finished += 1
            default: break
            }
            if finished == jobs.count { break }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        #expect(Set(files) == ["alpha.webp", "clip-compressed.mp4"])
    }
}
