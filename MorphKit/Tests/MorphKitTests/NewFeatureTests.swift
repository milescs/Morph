import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import MorphKit

@Suite struct DestinationTests {
    static var catalogURL: URL { Fixtures.repoRoot.appending(path: "App/Resources/Destinations.json") }

    @Test func bundledCatalogIsValid() throws {
        let catalog = try DestinationCatalog.decode(Data(contentsOf: Self.catalogURL))
        #expect(catalog.version == DestinationCatalog.supportedVersion)
        #expect(catalog.destinations.count >= 5)
        #expect(Set(catalog.destinations.map(\.id)).count == catalog.destinations.count)
        for destination in catalog.destinations {
            #expect(!destination.rules.isEmpty, "\(destination.id) has no rules")
            #expect(!destination.summary.isEmpty)
            for (kindName, rule) in destination.rules {
                let kind = try #require(MediaKind(rawValue: kindName))
                // Every target must be one the format picker offers for that kind.
                let item = MediaItem(url: URL(filePath: "/tmp/x.\(kind == .pdf ? "pdf" : "bin")"),
                                     format: kind == .pdf ? .pdf : kind == .image ? .jpeg : kind == .video ? .mp4 : .mp3,
                                     fileSize: 1, modificationDate: .now)
                let offered = FormatRegistry.targets(for: kind, items: [item], capabilities: nil)
                if kind == .image || kind == .pdf {
                    #expect(offered.contains(rule.target), "\(destination.id): \(rule.target) not offered for \(kind)")
                }
            }
        }
    }

    @Test func unknownTargetsAreSkipped() throws {
        let json = """
        {"version": 1, "updated": "2030-01-01", "destinations": [
          {"id": "future", "name": "Future", "rules": {
            "image": {"target": "hologram", "sizeLimitMB": 3},
            "video": {"target": "mp4H264", "sizeLimitMB": 8}}}]}
        """
        let catalog = try DestinationCatalog.decode(Data(json.utf8))
        let destination = try #require(catalog.destination(id: "future"))
        #expect(destination.rule(for: .image) == nil)
        #expect(destination.rule(for: .video)?.sizeLimit == 8_000_000)
        let newer = #"{"version": 99, "updated": "2030-01-01", "destinations": []}"#
        #expect(throws: (any Error).self) { try DestinationCatalog.decode(Data(newer.utf8)) }
    }

    @Test func settingsStartFromDefaultsButKeepPrivacy() throws {
        let destination = Destination(id: "d", name: "D", symbol: "x", badge: "10 MB", summary: "s", rules: [
            .video: .init(target: .mp4H264, sizeLimitMB: 10, shortSide: 720),
            .image: .init(target: .auto, sizeLimitMB: 2, maxLongSide: 2000),
        ])
        var base = ConversionSettings(target: .movProRes)
        base.video.encoder = .x265
        base.video.stripMetadata = true
        let video = try #require(destination.settings(for: .video, keepingPrivacyFrom: base))
        #expect(video.target == .mp4H264)
        #expect(video.video.encoder == nil)
        #expect(video.video.sizeLimit == 10_000_000)
        #expect(video.video.resolution == .shortSide(720))
        #expect(video.video.stripMetadata)
        let image = try #require(destination.settings(for: .image, keepingPrivacyFrom: base))
        #expect(image.image.resize == .longestSide(2000))
        #expect(image.image.metadata == .removeLocation)
        #expect(destination.settings(for: .audio, keepingPrivacyFrom: base) == nil)
    }
}

@Suite struct SettingsCompatibilityTests {
    @Test func oldSettingsDecodeWithNewDefaults() throws {
        // Saved by 1.0 (no removeLocation keys), plus an unknown future key.
        let json = """
        {"target": "mp4HEVC", "image": {"quality": 0.5, "metadata": "keep", "futureOption": 3},
         "video": {"quality": 0.3, "stripMetadata": false}, "audio": {}}
        """
        let settings = try JSONDecoder().decode(ConversionSettings.self, from: Data(json.utf8))
        #expect(settings.target == .mp4HEVC)
        #expect(settings.image.quality == 0.5)
        #expect(settings.image.metadata == .keep)
        #expect(settings.image.pngOptimization == ImageOptions().pngOptimization)
        #expect(settings.video.quality == 0.3)
        #expect(settings.video.removeLocation)
        #expect(settings.audio.removeLocation)
        // Round trip.
        let again = try JSONDecoder().decode(ConversionSettings.self, from: JSONEncoder().encode(settings))
        #expect(again == settings)
    }

    @Test func newDefaultsArePrivate() {
        #expect(ImageOptions().metadata == .removeLocation)
        #expect(VideoOptions().removeLocation)
        #expect(FormatRegistry.defaultTarget(for: .image) == .auto)
        #expect(FormatRegistry.defaultTarget(for: .pdf) == .original)
    }
}

@Suite struct AutoFormatTests {
    @Test func picksTheMostCompatibleFormat() async throws {
        let heic = try await Fixtures.item(Fixtures.heic())
        #expect(ImageEngine.autoFormat(for: heic) == .jpeg)
        let png = try await Fixtures.item(Fixtures.pngWithAlpha())
        #expect(ImageEngine.autoFormat(for: png) == .png)
        let gif = try await Fixtures.item(Fixtures.animatedGIF())
        #expect(ImageEngine.autoFormat(for: gif) == .gif)
        let svg = try await Fixtures.item(Fixtures.svg())
        #expect(ImageEngine.autoFormat(for: svg) == .png)

        let settings = ConversionSettings(target: .auto)
        #expect(FormatRegistry.outputExtension(for: heic, settings: settings, capabilities: nil) == "jpg")
        #expect(FormatRegistry.outputExtension(for: png, settings: settings, capabilities: nil) == "png")
        let converted = try ImageEngine.convert(item: gif, target: .auto, options: ImageOptions())
        let source = try #require(CGImageSourceCreateWithData(converted.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) > 1, "animation kept")
    }

    @Test func removesLocationByDefault() async throws {
        let photo = try await Fixtures.item(Fixtures.jpegWithGPS())
        let result = try ImageEngine.convert(item: photo, target: .auto, options: ImageOptions())
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(props[kCGImagePropertyExifDictionary] != nil, "other metadata is kept")
    }
}

@Suite struct PDFCompressionTests {
    /// A 3-page PDF with a large noisy photo on each page, some text, a link and an outline.
    static func imageHeavyPDF() throws -> URL {
        let url = Fixtures.directory.appending(path: "photos.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 0..<3 {
            let image = Fixtures.gradientImage(width: 2400, height: 1800, alpha: false)
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: CGRect(x: 36, y: 300, width: 540, height: 405))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 36, y: 200 - CGFloat(page), width: 300, height: 4))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let document = try #require(PDFDocument(url: url))
        let link = PDFAnnotation(bounds: CGRect(x: 36, y: 190, width: 300, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        document.page(at: 0)?.addAnnotation(link)
        let root = PDFOutline()
        let entry = PDFOutline()
        entry.label = "Page 2"
        if let page = document.page(at: 1) { entry.destination = PDFDestination(page: page, at: .zero) }
        root.insertChild(entry, at: 0)
        document.outlineRoot = root
        document.write(to: url)
        return url
    }

    @Test func shrinksImagesAndKeepsStructure() throws {
        let url = try Self.imageHeavyPDF()
        let original = try Data(contentsOf: url).count
        var options = ImageOptions()
        options.quality = 0.5
        let result = try PDFCompressor.compress(url: url, options: options)
        #expect(result.data.count < original / 2, "\(result.data.count) vs \(original)")
        let output = try #require(PDFDocument(data: result.data))
        #expect(output.pageCount == 3)
        #expect(output.page(at: 0)?.annotations.contains { $0.url != nil } == true, "link kept")
        #expect(output.outlineRoot?.numberOfChildren == 1, "outline kept")
    }

    @Test func meetsASizeLimit() throws {
        let url = try Self.imageHeavyPDF()
        var options = ImageOptions()
        options.quality = 0.9
        options.sizeLimit = 150_000
        let result = try PDFCompressor.compress(url: url, options: options)
        #expect(result.data.count <= 150_000)
        #expect(result.note != nil)
    }

    @Test func neverGrowsAVectorPDF() throws {
        let url = Fixtures.twoPagePDF()
        let original = try Data(contentsOf: url)
        let result = try PDFCompressor.compress(url: url, options: ImageOptions())
        #expect(result.data.count <= original.count)
    }

    @Test func routesPDFCompressionThroughThePipeline() async throws {
        let url = try Self.imageHeavyPDF()
        let item = try await Fixtures.item(url)
        #expect(ConversionPipeline.route(for: item, target: .original) == .pdfCompress)
        let settings = ConversionSettings(target: .original)
        #expect(FormatRegistry.outputExtension(for: item, settings: settings, capabilities: nil) == "pdf")
        let estimate = try await SizeEstimator(cache: EstimateCache(), ffmpeg: nil).refined(item: item, settings: settings)
        #expect(estimate.isExact)
        #expect(estimate.bytes < item.fileSize)
    }
}

@Suite struct FriendlyErrorTests {
    @Test func explainsCommonFFmpegFailures() {
        let cases: [(String, String)] = [
            ("[mov,mp4,m4a @ 0x1] moov atom not found\nError opening input file", "incomplete"),
            ("av_interleaved_write_frame(): No space left on device", "disk is full"),
            ("[vost#0:0 @ 0x1] Decoder (codec apac) not found for input stream #0:1", "apac"),
            ("[out#0/mp4 @ 0x1] Could not find tag for codec pcm_s16le in stream #1, codec not currently supported in container", "can't hold"),
            ("[h264_videotoolbox @ 0x1] Error: cannot create compression session: -12902", "hardware"),
            ("Something entirely new happened here", "Something entirely new"),
        ]
        for (log, expected) in cases {
            let explanation = FriendlyErrors.explain(ffmpegLog: log)
            #expect(explanation.message.localizedCaseInsensitiveContains(expected), "\(log) → \(explanation.message)")
        }
    }

    @Test func explainsSystemErrors() {
        let full = FriendlyErrors.explain(CocoaError(.fileWriteOutOfSpace))
        #expect(full.message == "The disk is full.")
        #expect(full.suggestion != nil)
        // A probe failure that was already explained keeps its advice.
        let probe = FriendlyErrors.explain(ffmpegLog: "[mov @ 0x1] moov atom not found")
        let again = FriendlyErrors.explain(ProbeError.unreadable(probe.message))
        #expect(again.suggestion == probe.suggestion)
        #expect(again.suggestion != nil)
        let locked = FriendlyErrors.explain(ImageEngineError("This PDF is password-protected."))
        #expect(locked.message == "This PDF is password-protected.")
        #expect(locked.suggestion?.contains("Preview") == true)
    }
}

@Suite struct LocationStrippingTests {
    @Test func videoCommandsDropLocationTags() async throws {
        guard let url = try await Fixtures.video(name: "loc.mov", seconds: 1, extra: [
            "-metadata", "com.apple.quicktime.location.ISO6709=+37.3349-122.0090+010.000/",
            "-metadata", "location=+37.3349-122.0090/", "-movflags", "use_metadata_tags",
        ]) else { return }
        let item = try await Fixtures.item(url)
        let tools = try #require(Fixtures.tools)
        let caps = try await FFmpegCapabilities.load(for: tools)
        let engine = FFmpegEngine(tools: tools, capabilities: caps)
        let output = Fixtures.directory.appending(path: "loc-out.mov")
        var settings = ConversionSettings(target: .movH264)
        settings.video.quality = 0.3
        _ = try await engine.convert(item: item, info: try #require(item.info?.media), settings: settings, output: output)
        let probe = try await ChildProcess.run(tools.ffprobe, arguments: ["-v", "error", "-show_entries", "format_tags",
                                                                         "-of", "json", output.path])
        let text = String(decoding: probe.stdout, as: UTF8.self)
        #expect(!text.contains("37.3349"), "location removed: \(text)")
    }
}
