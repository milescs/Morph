import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MorphKit

@Suite("Image engine")
struct ImageEngineTests {
    @Test("PNG with alpha converts to every raster format", arguments: [
        OutputFormat.jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .bmp, .jp2, .ico, .icns,
    ])
    func convertsToRasterFormats(target: OutputFormat) async throws {
        let item = try await Fixtures.item(Fixtures.pngWithAlpha())
        var options = ImageOptions()
        options.quality = 0.7
        let result = try ImageEngine.convert(item: item, target: target, options: options)
        #expect(result.data.count > 100)
        let size = try #require(Fixtures.decodedSize(result.data), "output must decode")
        if target != .ico && target != .icns {
            #expect(size == CGSize(width: 640, height: 480))
        }
    }

    @Test func jpegRemovesLocationButKeepsDate() async throws {
        let item = try await Fixtures.item(Fixtures.jpegWithGPS())
        var options = ImageOptions()
        options.metadata = .removeLocation
        options.resize = .percent(50) // forces the decode path (orientation baked in)
        let result = try ImageEngine.convert(item: item, target: .jpeg, options: options)
        let src = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        // Source was 640x480 with orientation 6 → displayed 480x640, then halved.
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 240)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 320)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:30 12:00:00")
    }

    @Test func fastPathRemovesLocation() async throws {
        let item = try await Fixtures.item(Fixtures.jpegWithGPS())
        var options = ImageOptions()
        options.metadata = .removeLocation
        let result = try ImageEngine.convert(item: item, target: .jpeg, options: options)
        let src = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func qualityLowersSize() async throws {
        let item = try await Fixtures.item(Fixtures.heic())
        var low = ImageOptions(), high = ImageOptions()
        low.quality = 0.2
        high.quality = 0.95
        let small = try ImageEngine.convert(item: item, target: .jpeg, options: low)
        let big = try ImageEngine.convert(item: item, target: .jpeg, options: high)
        #expect(small.data.count < big.data.count)
    }

    @Test func sizeLimitIsRespected() async throws {
        let item = try await Fixtures.item(Fixtures.heic())
        var options = ImageOptions()
        options.quality = 1
        options.sizeLimit = 30_000
        let result = try ImageEngine.convert(item: item, target: .jpeg, options: options)
        #expect(result.data.count <= 30_000)
        #expect(result.note != nil)
    }

    @Test func pngQuantizationShrinks() async throws {
        let item = try await Fixtures.item(Fixtures.pngWithAlpha())
        var lossy = ImageOptions(), lossless = ImageOptions()
        lossy.quality = 0.5
        lossless.quality = 1
        let small = try ImageEngine.convert(item: item, target: .png, options: lossy)
        let big = try ImageEngine.convert(item: item, target: .png, options: lossless)
        #expect(small.data.count < big.data.count)
        #expect(Fixtures.decodedSize(small.data) == CGSize(width: 640, height: 480))
    }

    @Test func svgRendersWithText() async throws {
        let item = try await Fixtures.item(Fixtures.svg())
        #expect(item.info?.image?.width == 200)
        var options = ImageOptions()
        options.svgScale = 2
        let result = try ImageEngine.convert(item: item, target: .png, options: options)
        #expect(Fixtures.decodedSize(result.data) == CGSize(width: 400, height: 200))
    }

    @Test func traceProducesSVG() async throws {
        let item = try await Fixtures.item(Fixtures.pngWithAlpha())
        let result = try ImageEngine.convert(item: item, target: .svgTrace, options: ImageOptions())
        let text = String(decoding: result.data, as: UTF8.self)
        #expect(text.contains("<svg"))
        #expect(result.fileExtension == "svg")
    }

    @Test func pdfPagesRasterize() async throws {
        let item = try await Fixtures.item(Fixtures.twoPagePDF())
        #expect(item.info?.pdf?.pageCount == 2)
        var options = ImageOptions()
        options.pdfDPI = 144
        let page2 = try ImageEngine.convert(item: item, target: .png, options: options, page: 2)
        #expect(Fixtures.decodedSize(page2.data) == CGSize(width: 1224, height: 1584))
    }

    @Test func imagesCombineIntoPDF() async throws {
        let items = [try await Fixtures.item(Fixtures.heic()), try await Fixtures.item(Fixtures.pngWithAlpha())]
        let data = try ImageEngine.combinePDF(items: items, options: ImageOptions())
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 2)
    }

    @Test func gifStaysAnimatedAsWebP() async throws {
        let item = try await Fixtures.item(Fixtures.animatedGIF())
        #expect(item.info?.image?.frameCount == 6)
        let result = try ImageEngine.convert(item: item, target: .webp, options: ImageOptions())
        let src = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetCount(src) == 6)
    }
}
