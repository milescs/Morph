import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// The bytes of a converted image, ready to write.
public struct ImageEncodeResult: Sendable {
    public let data: Data
    public let fileExtension: String
    public let pixelSize: CGSizeInt
    /// Human-readable note, e.g. when a size limit forced a downscale.
    public let note: String?

    public var byteCount: Int64 { Int64(data.count) }
}

/// Converts images (raster, SVG, PDF pages, video frames) to image formats, in memory.
public enum ImageEngine {
    /// Formats Morph can write as still images.
    public static let writableFormats: Set<FileFormat> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .bmp, .jp2,
                                                          .ico, .icns, .pdf, .svg]

    /// The concrete image format produced for `target` from `source` (nil for `.auto`, which needs the item).
    public static func outputFormat(for target: OutputFormat, source: FileFormat) -> FileFormat? {
        if target == .original {
            return writableFormats.contains(source) && source != .svg && source != .pdf ? source : nil
        }
        return target.imageFormat
    }

    /// The concrete image format produced for `target` from `item`.
    public static func outputFormat(for target: OutputFormat, item: MediaItem) -> FileFormat? {
        target == .auto ? autoFormat(for: item) : outputFormat(for: target, source: item.format)
    }

    /// "Auto": the most compatible format for this particular file.
    public static func autoFormat(for item: MediaItem) -> FileFormat {
        let info = item.info?.image
        if info?.isAnimated == true { return .gif }
        switch item.format {
        case .jpeg, .png, .gif: return item.format
        case .bmp, .ico, .icns, .svg, .pdf: return .png
        default: return info?.hasAlpha == true ? .png : .jpeg
        }
    }

    /// Converts one file. For PDFs, `page` selects the (1-based) page.
    public static func convert(item: MediaItem, target: OutputFormat, options: ImageOptions,
                               page: Int = 1) throws -> ImageEncodeResult {
        guard let format = outputFormat(for: target, item: item) else {
            throw ImageEngineError("\(item.format.displayName) files can't be saved in their original format.")
        }
        let (input, preferredSize) = try loadInput(item: item, format: format, options: options, page: page)
        return try encode(input: input, outputSize: preferredSize, format: format, options: options)
    }

    /// Converts an in-memory image (e.g. a video frame).
    public static func convert(image: CGImage, to format: FileFormat, options: ImageOptions) throws -> ImageEncodeResult {
        let input = ImageInput.rendered(image, format: .png)
        let size = options.resize.apply(to: input.size, allowUpscale: options.allowUpscale)
        return try encode(input: input, outputSize: size, format: format, options: options)
    }

    // MARK: - Input

    static func loadInput(item: MediaItem, format: FileFormat, options: ImageOptions,
                          page: Int) throws -> (ImageInput, CGSizeInt) {
        switch item.format {
        case .svg:
            let data = try Data(contentsOf: item.url)
            let intrinsic = try svgIntrinsicSize(data)
            let base = CGSizeInt(width: max(1, Int((intrinsic.width * options.svgScale).rounded())),
                                 height: max(1, Int((intrinsic.height * options.svgScale).rounded())))
            // Vectors scale up losslessly.
            let size = options.resize.apply(to: base, allowUpscale: true)
            let image = try renderSVG(data, size: size)
            return (.rendered(image, format: .svg), size)
        case .pdf:
            let background: RGBColor? = options.flattenColor
            let image = try ImageRendering.renderPDFPage(url: item.url, page: page, dpi: options.pdfDPI,
                                                         background: background)
            let input = ImageInput.rendered(image, format: .pdf)
            return (input, options.resize.apply(to: input.size, allowUpscale: options.allowUpscale))
        default:
            let input = try ImageInput.open(url: item.url, format: item.format)
            return (input, options.resize.apply(to: input.size, allowUpscale: options.allowUpscale))
        }
    }

    static func svgIntrinsicSize(_ data: Data) throws -> CGSize {
        if let size = try? RustCodecs.svgSize(data: data), size.width > 0, size.height > 0 { return size }
        if let image = NSImage(data: data), image.size.width > 0 { return image.size }
        throw ImageEngineError("This SVG can't be read.")
    }

    static func renderSVG(_ data: Data, size: CGSizeInt) throws -> CGImage {
        do {
            return try RustCodecs.renderSVG(data: data, width: size.width, height: size.height)
        } catch {
            // Fallback: Apple's built-in SVG support.
            guard let image = NSImage(data: data) else { throw error }
            var rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw error }
            return try ImageRendering.resized(cg, to: size)
        }
    }

    // MARK: - Encoding with an optional size limit

    static func encode(input: ImageInput, outputSize: CGSizeInt, format: FileFormat,
                       options: ImageOptions) throws -> ImageEncodeResult {
        let quality = options.quality
        guard let limit = options.sizeLimit, limit > 0 else {
            let data = try encodeOnce(input: input, size: outputSize, format: format, quality: quality, options: options)
            return ImageEncodeResult(data: data, fileExtension: format.preferredExtension, pixelSize: outputSize, note: nil)
        }

        var size = outputSize
        var note: String?
        for round in 0..<6 {
            try Task.checkCancellation()
            let atSlider = try encodeOnce(input: input, size: size, format: format, quality: quality, options: options)
            if atSlider.count <= limit {
                return ImageEncodeResult(data: atSlider, fileExtension: format.preferredExtension, pixelSize: size,
                                         note: note)
            }
            var smallest = atSlider
            if ImageEncoder.isLossy(format, options: options) {
                // Binary search the highest quality that fits.
                var low = 0.0, high = quality
                var best: Data?
                for _ in 0..<7 {
                    let mid = (low + high) / 2
                    let data = try encodeOnce(input: input, size: size, format: format, quality: mid, options: options)
                    if data.count <= limit {
                        best = data
                        low = mid
                    } else {
                        high = mid
                        smallest = data.count < smallest.count ? data : smallest
                    }
                    if high - low < 0.02 { break }
                }
                if let best {
                    let percent = Int((low * 100).rounded())
                    let qualityNote = "Quality lowered to \(percent) to fit \(Formatters.bytes(limit))"
                    return ImageEncodeResult(data: best, fileExtension: format.preferredExtension, pixelSize: size,
                                             note: note.map { "\($0); \(qualityNote.lowercased())" } ?? qualityNote)
                }
            }
            // Still too big: shrink the pixel size and try again.
            let ratio = Double(limit) / Double(max(1, smallest.count))
            let factor = max(0.25, min(0.9, ratio.squareRoot() * 0.95))
            size = CGSizeInt(width: max(1, Int(Double(size.width) * factor)),
                             height: max(1, Int(Double(size.height) * factor)))
            note = "Resized to \(size.width)×\(size.height) to fit \(Formatters.bytes(limit))"
            if round == 5 || size.longestSide < 16 { break }
        }
        let data = try encodeOnce(input: input, size: size, format: format, quality: 0, options: options)
        return ImageEncodeResult(data: data, fileExtension: format.preferredExtension, pixelSize: size,
                                 note: "Couldn't reach \(Formatters.bytes(limit)); saved the smallest version")
    }

    /// One encode at a fixed size and quality.
    static func encodeOnce(input: ImageInput, size: CGSizeInt, format: FileFormat, quality: Double,
                           options: ImageOptions) throws -> Data {
        let sameSize = size == input.size
        let needsFlatten = input.hasAlpha && !ImageEncoder.supportsAlpha(format)
        let background: RGBColor? = needsFlatten ? options.flattenColor : nil

        // Animation (GIF / WebP / APNG).
        if input.isAnimated && options.keepAnimation && ImageEncoder.supportsAnimation(format) {
            return try encodeAnimation(input: input, size: size, format: format, quality: quality, options: options)
        }

        switch format {
        case .svg:
            let traceSize = size.longestSide > options.trace.maxSide
                ? ResizeMode.longestSide(options.trace.maxSide).apply(to: size, allowUpscale: false) : size
            let image = try input.decode(to: traceSize)
            return try RustCodecs.traceSVG(image: image, options: options.trace)

        case .pdf:
            let image = try prepared(input: input, size: size, options: options, background: nil)
            let dpi = input.properties[kCGImagePropertyDPIWidth] as? Double ?? 72
            return try ImageEncoder.encodePDF(pages: [.init(image: image, dpi: max(dpi, 72))], quality: quality,
                                              options: options)

        case .png:
            let image = try prepared(input: input, size: size, options: options, background: background,
                                     highBitDepth: true)
            let metadata = MetadataPayload.from(input: input, policy: options.metadata)
            return try ImageEncoder.encodePNG(image, quality: quality, options: options, metadata: metadata)

        case .webp:
            let image = try prepared(input: input, size: size, options: options, background: background)
            let space = ImageRendering.workingSpace(for: image, option: options.colorProfile)
            let icc = space.name == CGColorSpace.sRGB ? nil : space.copyICCData() as Data?
            let metadata = MetadataPayload.from(input: input, policy: options.metadata)
            return try WebPCodec.encode(image: image, colorSpace: space,
                                        options: ImageEncoder.webpOptions(quality: quality, options: options),
                                        icc: icc, xmp: metadata.xmp)

        case .ico, .icns:
            let image = try input.decode(to: size)
            return try ImageEncoder.encodeIcon(image, format: format, options: options)

        default:
            // Fast path: straight transcode keeps bit depth, metadata and HDR gain maps.
            if sameSize, !needsFlatten, options.colorProfile == .keep, options.metadata != .removeAll,
               let source = input.imageSource, input.frameCount <= 1 || !options.keepAnimation {
                let index = CGImageSourceGetPrimaryImageIndex(source)
                // Some sources (e.g. multi-page or unusual TIFFs) can't be copied straight into every
                // format; those take the decode-and-encode path below.
                if let data = try? ImageEncoder.writeFromSource(source, index: index, format: format, quality: quality,
                                                                options: options) {
                    return data
                }
            }
            let image = try prepared(input: input, size: size, options: options, background: background,
                                     highBitDepth: format == .tiff)
            let metadata = MetadataPayload.from(input: input, policy: options.metadata)
            let props = ImageEncoder.encodingProperties(format: format, quality: quality, options: options,
                                                        base: metadata.properties)
            do {
                return try ImageEncoder.writeImageIO(images: [(image, props)], format: format)
            } catch {
                // Some encoders (e.g. HEIC) reject float or deep grayscale pixels: retry as 8-bit RGB.
                let rgb = try ImageRendering.redraw(image, size: size, colorSpace: ImageRendering.sRGB,
                                                    background: background)
                return try ImageEncoder.writeImageIO(images: [(rgb, props)], format: format)
            }
        }
    }

    /// Decodes at `size`, then converts color / flattens transparency when needed.
    static func prepared(input: ImageInput, size: CGSizeInt, options: ImageOptions, background: RGBColor?,
                         highBitDepth: Bool = false) throws -> CGImage {
        let fill: Bool
        if case .fill = options.resize { fill = true } else { fill = false }
        var image = try input.decode(to: size)
        let needsColor = options.colorProfile != .keep
        if needsColor || background != nil || (fill && (image.width != size.width || image.height != size.height)) {
            let space = ImageRendering.workingSpace(for: image, option: options.colorProfile)
            image = try ImageRendering.redraw(image, size: size, colorSpace: space, background: background,
                                              fill: fill, highBitDepth: highBitDepth)
        }
        return image
    }

    static func encodeAnimation(input: ImageInput, size: CGSizeInt, format: FileFormat, quality: Double,
                                options: ImageOptions) throws -> Data {
        let (frames, loopCount) = try input.decodeFrames(to: size)
        switch format {
        case .webp:
            let space = ImageRendering.sRGB
            return try WebPCodec.encodeAnimation(
                frames: frames.map { .init(image: $0.image, durationMs: Int(($0.delay * 1000).rounded())) },
                loopCount: loopCount, colorSpace: space,
                options: ImageEncoder.webpOptions(quality: quality, options: options), icc: nil)
        case .gif:
            let container: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
            let images = frames.map { frame -> (CGImage, [CFString: Any]) in
                (frame.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay]])
            }
            return try ImageEncoder.writeImageIO(images: images, format: .gif, containerProperties: container)
        case .png:
            let container: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]]
            let images = frames.map { frame -> (CGImage, [CFString: Any]) in
                (frame.image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: frame.delay]])
            }
            return try ImageEncoder.writeImageIO(images: images, format: .png, containerProperties: container)
        default:
            throw ImageEngineError("\(format.displayName) can't store animations.")
        }
    }

    // MARK: - Many images → one PDF

    /// Combines images (and PDF pages) into one PDF, in order.
    public static func combinePDF(items: [MediaItem], options: ImageOptions,
                                  progress: (@Sendable (Double) -> Void)? = nil) throws -> Data {
        var pages: [ImageEncoder.PDFPageImage] = []
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            switch item.format {
            case .pdf:
                let count = try item.info?.pdf?.pageCount ?? PDFProbe.probe(url: item.url).pageCount
                for page in options.pdfPages.pages(count: count) {
                    let image = try ImageRendering.renderPDFPage(url: item.url, page: page, dpi: options.pdfDPI,
                                                                 background: .white)
                    pages.append(.init(image: image, dpi: options.pdfDPI))
                }
            default:
                let (input, size) = try loadInput(item: item, format: .pdf, options: options, page: 1)
                let image = try prepared(input: input, size: size, options: options, background: nil)
                let dpi = input.properties[kCGImagePropertyDPIWidth] as? Double ?? 72
                pages.append(.init(image: image, dpi: max(72, dpi)))
            }
            progress?(Double(i + 1) / Double(items.count))
        }
        guard !pages.isEmpty else { throw ImageEngineError("There's nothing to combine.") }
        return try ImageEncoder.encodePDF(pages: pages, quality: options.quality, options: options)
    }
}
