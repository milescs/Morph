import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata to write alongside pixels.
struct MetadataPayload {
    /// ImageIO property dictionaries (EXIF, GPS, TIFF, IPTC …), orientation normalized to 1.
    var properties: [CFString: Any] = [:]
    /// XMP packet (used for WebP).
    var xmp: Data?

    static var empty: MetadataPayload { MetadataPayload() }

    static func from(input: ImageInput, policy: MetadataPolicy) -> MetadataPayload {
        guard policy != .removeAll else { return .empty }
        var props: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary] {
            if let value = input.properties[key] { props[key] = value }
        }
        if policy == .removeLocation { props.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            props[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props[kCGImagePropertyOrientation] = 1

        var xmp: Data?
        if let metadata = input.metadata, let mutable = CGImageMetadataCreateMutableCopy(metadata) {
            if policy == .removeLocation {
                var gpsPaths: [String] = []
                CGImageMetadataEnumerateTagsUsingBlock(mutable, nil, nil) { path, _ in
                    let p = path as String
                    if p.hasPrefix("exif:GPS") { gpsPaths.append(p) }
                    return true
                }
                for path in gpsPaths { CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString) }
            }
            // Orientation is baked into the pixels.
            CGImageMetadataSetValueWithPath(mutable, nil, "tiff:Orientation" as CFString, 1 as CFNumber)
            xmp = CGImageMetadataCreateXMPData(mutable, nil) as Data?
        }
        return MetadataPayload(properties: props, xmp: xmp)
    }
}

enum ImageEncoder {
    /// Maps the 0…1 slider to an ImageIO/libwebp quality with a useful spread.
    static func lossyQuality(_ slider: Double) -> Double {
        0.05 + 0.95 * max(0, min(1, slider))
    }

    static func utType(for format: FileFormat) -> String? {
        switch format {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .bmp: "com.microsoft.bmp"
        case .jp2: "public.jpeg-2000"
        case .ico: "com.microsoft.ico"
        case .icns: "com.apple.icns"
        case .psd: "com.adobe.photoshop-image"
        case .tga: "com.truevision.tga-image"
        case .exr: "com.ilm.openexr-image"
        default: nil
        }
    }

    static func supportsAlpha(_ format: FileFormat) -> Bool {
        [.png, .heic, .avif, .webp, .tiff, .gif, .ico, .icns, .jp2, .svg, .pdf, .psd, .tga, .exr].contains(format)
    }

    static func supportsAnimation(_ format: FileFormat) -> Bool {
        [.gif, .webp, .png].contains(format)
    }

    static func isLossy(_ format: FileFormat, options: ImageOptions) -> Bool {
        switch format {
        case .jpeg, .heic, .avif, .jp2: !options.lossless
        case .webp: !options.lossless
        case .png: true // quantization
        case .gif, .pdf: true
        default: false
        }
    }

    // MARK: ImageIO

    /// Format-specific destination properties.
    static func encodingProperties(format: FileFormat, quality: Double, options: ImageOptions,
                                   base: [CFString: Any]) -> [CFString: Any] {
        var props = base
        switch format {
        case .jpeg, .heic, .avif, .jp2:
            props[kCGImageDestinationLossyCompressionQuality] = options.lossless ? 1.0 : lossyQuality(quality)
        default:
            break
        }
        if format == .jpeg && options.progressive {
            props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        if format == .tiff {
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let dpi = options.dpi {
            props[kCGImagePropertyDPIWidth] = dpi
            props[kCGImagePropertyDPIHeight] = dpi
        }
        return props
    }

    static func writeImageIO(images: [(CGImage, [CFString: Any])], format: FileFormat,
                             containerProperties: [CFString: Any]? = nil) throws -> Data {
        guard let type = utType(for: format) else {
            throw ImageEngineError("\(format.displayName) can't be written.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil) else {
            throw ImageEngineError("\(format.displayName) isn't supported on this Mac.")
        }
        if let containerProperties {
            CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)
        }
        for (image, props) in images {
            CGImageDestinationAddImage(destination, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEngineError("Couldn't encode \(format.displayName).")
        }
        return data as Data
    }

    /// Transcodes straight from the source (keeps bit depth, metadata, gain maps).
    static func writeFromSource(_ source: CGImageSource, index: Int, format: FileFormat, quality: Double,
                                options: ImageOptions) throws -> Data {
        guard let type = utType(for: format) else { throw ImageEngineError("\(format.displayName) can't be written.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ImageEngineError("\(format.displayName) isn't supported on this Mac.")
        }
        var props = encodingProperties(format: format, quality: quality, options: options, base: [:])
        if options.metadata == .removeLocation {
            props[kCGImagePropertyGPSDictionary] = kCFNull
        }
        CGImageDestinationAddImageFromSource(destination, source, index, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEngineError("Couldn't encode \(format.displayName).")
        }
        return data as Data
    }

    // MARK: PNG

    static func encodePNG(_ image: CGImage, quality: Double, options: ImageOptions,
                          metadata: MetadataPayload) throws -> Data {
        let lossless = options.lossless || quality >= 0.98
        if !lossless {
            // Palette quality target: 40 (slider 0, 16 colors) … 100 (slider 1, 256 colors).
            let target = Int((40 + 60 * quality).rounded())
            do {
                return try RustCodecs.quantizePNG(image: image, qualityMin: 0, qualityMax: target,
                                                  dithering: options.pngDithering,
                                                  optimization: options.pngOptimization)
            } catch let error as RustCodecError where error.isQualityTooLow {
                // Fall through to lossless.
            }
        }
        let props = encodingProperties(format: .png, quality: quality, options: options, base: metadata.properties)
        let png = try writeImageIO(images: [(image, props)], format: .png)
        return try RustCodecs.optimizePNG(png, level: options.pngOptimization,
                                          stripMetadata: options.metadata == .removeAll)
    }

    // MARK: WebP

    static func webpOptions(quality: Double, options: ImageOptions) -> WebPCodec.Options {
        WebPCodec.Options(quality: Float(lossyQuality(quality) * 100), lossless: options.lossless,
                          method: Int32(options.webpMethod), alphaQuality: 100,
                          sharpYUV: options.chroma != .half)
    }

    // MARK: Icons

    static func encodeIcon(_ image: CGImage, format: FileFormat, options: ImageOptions) throws -> Data {
        let sizes: [Int]
        if format == .ico {
            sizes = options.icoSizes.filter { $0 <= 256 }.sorted()
        } else {
            sizes = [16, 32, 64, 128, 256, 512, 1024]
        }
        let images = try sizes.map { side in try ImageRendering.squareIcon(image, side: side) }
        if format == .ico {
            // ImageIO's ICO writer rejects more than a few entries; write the container ourselves
            // with PNG-compressed entries (supported since Windows Vista and by every browser).
            return try writeICO(images)
        }
        return try writeImageIO(images: images.map { ($0, [CFString: Any]()) }, format: format)
    }

    static func writeICO(_ images: [CGImage]) throws -> Data {
        let payloads = try images.map { try writeImageIO(images: [($0, [:])], format: .png) }
        var data = Data()
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append16(0) // reserved
        append16(1) // type: icon
        append16(UInt16(images.count))
        var offset = 6 + 16 * images.count
        for (image, payload) in zip(images, payloads) {
            data.append(UInt8(image.width >= 256 ? 0 : image.width))
            data.append(UInt8(image.height >= 256 ? 0 : image.height))
            data.append(0) // palette size
            data.append(0) // reserved
            append16(1)    // color planes
            append16(32)   // bits per pixel
            append32(UInt32(payload.count))
            append32(UInt32(offset))
            offset += payload.count
        }
        for payload in payloads { data.append(payload) }
        return data
    }

    // MARK: PDF

    struct PDFPageImage {
        let image: CGImage
        let dpi: Double
    }

    /// Builds a PDF with one page per image. Opaque images are embedded as JPEG at `quality`.
    static func encodePDF(pages: [PDFPageImage], quality: Double, options: ImageOptions) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ImageEngineError("Couldn't create the PDF.")
        }
        for page in pages {
            let image = page.image
            let imagePoints = CGSize(width: CGFloat(image.width) * 72 / page.dpi,
                                     height: CGFloat(image.height) * 72 / page.dpi)
            var mediaBox: CGRect
            var drawRect: CGRect
            switch options.pdfPageSize {
            case .fitImage:
                mediaBox = CGRect(origin: .zero, size: imagePoints)
                drawRect = mediaBox
            case .a4, .letter:
                var paper = options.pdfPageSize == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792)
                if image.width > image.height { paper = CGSize(width: paper.height, height: paper.width) }
                mediaBox = CGRect(origin: .zero, size: paper)
                let margin: CGFloat = 36
                let available = mediaBox.insetBy(dx: margin, dy: margin)
                let scale = min(1, min(available.width / imagePoints.width, available.height / imagePoints.height))
                let size = CGSize(width: imagePoints.width * scale, height: imagePoints.height * scale)
                drawRect = CGRect(x: (paper.width - size.width) / 2, y: (paper.height - size.height) / 2,
                                  width: size.width, height: size.height)
            }
            let boxData = withUnsafeBytes(of: &mediaBox) { Data($0) }
            context.beginPDFPage([kCGPDFContextMediaBox: boxData as CFData] as CFDictionary)
            if !image.hasAlpha && !options.lossless, let jpeg = jpegBacked(image, quality: quality) {
                context.draw(jpeg, in: drawRect)
            } else {
                context.draw(image, in: drawRect)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A CGImage backed by JPEG data, which Quartz embeds in PDFs without re-encoding.
    static func jpegBacked(_ image: CGImage, quality: Double) -> CGImage? {
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: lossyQuality(quality)]
        guard let jpeg = try? writeImageIO(images: [(image, props)], format: .jpeg),
              let provider = CGDataProvider(data: jpeg as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
