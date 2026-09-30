import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageEngineError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One frame of an animated image.
struct AnimationFrame {
    let image: CGImage
    /// Seconds.
    let delay: Double
}

/// A readable image input: an ImageIO source, a rendered SVG, or a rendered PDF page.
/// Not Sendable (wraps CGImageSource) — use within a single synchronous job.
final class ImageInput {
    enum Backing {
        case imageIO(CGImageSource, index: Int)
        case rendered(CGImage)
    }

    let backing: Backing
    /// Oriented pixel size.
    let size: CGSizeInt
    let hasAlpha: Bool
    let bitsPerComponent: Int
    /// EXIF orientation (1…8) of the ImageIO source.
    let orientation: Int
    /// Top-level properties of the source image (EXIF, GPS, TIFF, IPTC …).
    let properties: [CFString: Any]
    let metadata: CGImageMetadata?
    let frameCount: Int
    let sourceColorSpace: CGColorSpace?
    let sourceFormat: FileFormat

    private init(backing: Backing, size: CGSizeInt, hasAlpha: Bool, bitsPerComponent: Int, orientation: Int,
                 properties: [CFString: Any], metadata: CGImageMetadata?, frameCount: Int,
                 sourceColorSpace: CGColorSpace?, sourceFormat: FileFormat) {
        self.backing = backing
        self.size = size
        self.hasAlpha = hasAlpha
        self.bitsPerComponent = bitsPerComponent
        self.orientation = orientation
        self.properties = properties
        self.metadata = metadata
        self.frameCount = frameCount
        self.sourceColorSpace = sourceColorSpace
        self.sourceFormat = sourceFormat
    }

    var isAnimated: Bool { frameCount > 1 }

    var imageSource: CGImageSource? {
        if case .imageIO(let source, _) = backing { source } else { nil }
    }

    // MARK: Loading

    /// Opens a raster image file with ImageIO.
    static func open(url: URL, format: FileFormat) throws -> ImageInput {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageEngineError("This image can't be read.")
        }
        return try open(source: source, format: format)
    }

    static func open(data: Data, format: FileFormat) throws -> ImageInput {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageEngineError("This image can't be read.")
        }
        return try open(source: source, format: format)
    }

    static func open(source: CGImageSource, format: FileFormat) throws -> ImageInput {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let info = try ImageProbe.probe(source: source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil)
        // Cheap: header-only decode to learn the color space.
        let colorSpace = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary)?
            .colorSpace
        return ImageInput(backing: .imageIO(source, index: index),
                          size: CGSizeInt(width: info.width, height: info.height), hasAlpha: info.hasAlpha,
                          bitsPerComponent: info.bitsPerComponent, orientation: orientation, properties: props,
                          metadata: metadata, frameCount: info.frameCount, sourceColorSpace: colorSpace,
                          sourceFormat: format)
    }

    /// Wraps an already-rendered image (SVG, PDF page, video frame).
    static func rendered(_ image: CGImage, format: FileFormat, properties: [CFString: Any] = [:]) -> ImageInput {
        ImageInput(backing: .rendered(image), size: CGSizeInt(width: image.width, height: image.height),
                   hasAlpha: image.hasAlpha, bitsPerComponent: image.bitsPerComponent, orientation: 1,
                   properties: properties, metadata: nil, frameCount: 1, sourceColorSpace: image.colorSpace,
                   sourceFormat: format)
    }

    // MARK: Decoding

    /// Decodes the primary image at `target` size with orientation applied.
    func decode(to target: CGSizeInt) throws -> CGImage {
        switch backing {
        case .rendered(let image):
            if image.width == target.width && image.height == target.height { return image }
            return try ImageRendering.resized(image, to: target)
        case .imageIO(let source, let index):
            return try Self.decode(source: source, index: index, orientedSize: size, orientation: orientation,
                                   target: target)
        }
    }

    static func decode(source: CGImageSource, index: Int, orientedSize: CGSizeInt, orientation: Int,
                       target: CGSizeInt) throws -> CGImage {
        let sameSize = target.width == orientedSize.width && target.height == orientedSize.height
        if sameSize && orientation == 1 {
            // Full-size decode keeps the source bit depth (16-bit PNG/TIFF, HDR).
            guard let image = CGImageSourceCreateImageAtIndex(
                source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw ImageEngineError("The image data is damaged.") }
            return image
        }
        let upscale = target.longestSide > orientedSize.longestSide
        let maxSide = upscale ? orientedSize.longestSide : target.longestSide
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ImageEngineError("The image data is damaged.")
        }
        if thumbnail.width == target.width && thumbnail.height == target.height { return thumbnail }
        // Aspect-changing resize (fill) or upscale: finish with Core Graphics.
        return try ImageRendering.resized(thumbnail, to: target, fill: true)
    }

    /// All frames of an animated image, decoded at `target` size.
    func decodeFrames(to target: CGSizeInt) throws -> (frames: [AnimationFrame], loopCount: Int) {
        guard case .imageIO(let source, _) = backing, frameCount > 1 else {
            return ([AnimationFrame(image: try decode(to: target), delay: 0.1)], 0)
        }
        let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        var loopCount = 0
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary,
                    kCGImagePropertyHEICSDictionary] {
            if let dict = containerProps[key] as? [CFString: Any] {
                loopCount = dict[kCGImagePropertyGIFLoopCount] as? Int
                    ?? dict[kCGImagePropertyAPNGLoopCount] as? Int
                    ?? dict[kCGImagePropertyWebPLoopCount] as? Int
                    ?? dict[kCGImagePropertyHEICSLoopCount] as? Int ?? 0
            }
        }
        var frames: [AnimationFrame] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] ?? [:]
            let image = try Self.decode(source: source, index: i, orientedSize: size, orientation: 1, target: target)
            frames.append(AnimationFrame(image: image, delay: Self.frameDelay(props)))
        }
        return (frames, loopCount)
    }

    static func frameDelay(_ props: [CFString: Any]) -> Double {
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictKey, unclamped, clamped) in pairs {
            if let dict = props[dictKey] as? [CFString: Any] {
                let value = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double) ?? 0.1
                // Browsers treat very small delays as 100 ms.
                return value < 0.02 ? 0.1 : value
            }
        }
        return 0.1
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
