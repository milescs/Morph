import CoreGraphics
import Foundation
import MorphRust

public struct RustCodecError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String

    public var errorDescription: String? { message }
    public var isQualityTooLow: Bool { code == MORPH_ERR_QUALITY_TOO_LOW }
}

/// Options for raster → SVG tracing (vtracer).
public struct TraceOptions: Codable, Sendable, Hashable {
    public enum Mode: Int, Codable, Sendable, CaseIterable { case pixel = 0, polygon = 1, spline = 2 }

    public var color = true
    public var stacked = true
    /// Remove specks smaller than this many pixels.
    public var filterSpeckle = 4
    /// Bits of color precision per channel (1–8). More = more colors.
    public var colorPrecision = 6
    public var layerDifference = 16
    public var mode: Mode = .spline
    public var cornerThreshold = 60
    public var lengthThreshold = 4.0
    public var spliceThreshold = 45
    public var pathPrecision = 2
    /// Images are downscaled so their longest side is at most this before tracing.
    public var maxSide = 1600

    public init() {}
}

/// Swift wrappers around morph-rs (resvg, vtracer, oxipng, quantizr).
public enum RustCodecs {
    public static var version: String { String(cString: morph_version()) }

    private static func check(_ status: Int32) throws {
        guard status == MORPH_OK else {
            let message = morph_last_error().map { String(cString: $0) } ?? "Unknown error (\(status))"
            throw RustCodecError(code: status, message: message)
        }
    }

    private static func take(_ buffer: MorphBuffer) -> Data {
        defer { morph_buffer_free(buffer) }
        guard let ptr = buffer.ptr, buffer.len > 0 else { return Data() }
        return Data(bytes: ptr, count: buffer.len)
    }

    // MARK: SVG

    public static func warmUpFonts() {
        morph_svg_warm_up()
    }

    public static func svgSize(data: Data) throws -> CGSize {
        var width: Float = 0, height: Float = 0
        let status = data.withUnsafeBytes { raw in
            morph_svg_size(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &width, &height)
        }
        try check(status)
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// Renders an SVG. Pass 0 for a dimension to keep the aspect ratio; both 0 = intrinsic size.
    public static func renderSVG(data: Data, width: Int = 0, height: Int = 0) throws -> CGImage {
        var buffer = MorphBuffer(ptr: nil, len: 0, cap: 0)
        var outW: UInt32 = 0, outH: UInt32 = 0
        let status = data.withUnsafeBytes { raw in
            morph_svg_render(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                             UInt32(max(0, width)), UInt32(max(0, height)), &buffer, &outW, &outH)
        }
        try check(status)
        let pixels = take(buffer)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: Int(outW), height: Int(outH), bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: Int(outW) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            throw RustCodecError(code: MORPH_ERR_ENCODE, message: "Couldn't create the rendered image.")
        }
        return image
    }

    // MARK: PNG

    /// Lossy palette PNG (quantizr) + oxipng. `qualityMax` (40–100) sets the palette size (16–256 colors).
    public static func quantizePNG(image: CGImage, qualityMin: Int, qualityMax: Int, dithering: Double,
                                   optimization: Int, zopfli: Bool = false, speed: Int = 4) throws -> Data {
        let pixels = try RGBAPixels(image: image)
        let icc = pixels.iccProfile
        var options = MorphPNGOptions(
            quality_min: UInt8(clamping: qualityMin), quality_max: UInt8(clamping: qualityMax),
            dithering: Float(dithering), speed: Int32(speed), optimization: UInt8(clamping: optimization),
            zopfli: zopfli, premultiplied: true, icc: nil, icc_len: 0, timeout_ms: 0)
        var buffer = MorphBuffer(ptr: nil, len: 0, cap: 0)
        let status: Int32 = pixels.data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            if let icc {
                return icc.withUnsafeBytes { iccRaw in
                    options.icc = iccRaw.bindMemory(to: UInt8.self).baseAddress
                    options.icc_len = iccRaw.count
                    return morph_png_quantize(base, UInt32(pixels.width), UInt32(pixels.height), &options, &buffer)
                }
            }
            return morph_png_quantize(base, UInt32(pixels.width), UInt32(pixels.height), &options, &buffer)
        }
        try check(status)
        return take(buffer)
    }

    /// Losslessly recompresses PNG data (keeps bit depth, ICC and metadata unless stripped).
    public static func optimizePNG(_ png: Data, level: Int, zopfli: Bool = false, stripMetadata: Bool = false,
                                   timeoutMilliseconds: Int = 0) throws -> Data {
        var buffer = MorphBuffer(ptr: nil, len: 0, cap: 0)
        let status = png.withUnsafeBytes { raw in
            morph_png_optimize(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, UInt8(clamping: level), zopfli,
                               stripMetadata, UInt32(clamping: timeoutMilliseconds), &buffer)
        }
        try check(status)
        return take(buffer)
    }

    // MARK: Trace

    public static func traceSVG(image: CGImage, options: TraceOptions) throws -> Data {
        let pixels = try RGBAPixels(image: image, forceSRGB: true)
        var opts = MorphTraceOptions(
            color: options.color, stacked: options.stacked, filter_speckle: UInt32(clamping: options.filterSpeckle),
            color_precision: Int32(options.colorPrecision), layer_difference: Int32(options.layerDifference),
            mode: UInt8(options.mode.rawValue), corner_threshold: Int32(options.cornerThreshold),
            length_threshold: options.lengthThreshold, max_iterations: 10,
            splice_threshold: Int32(options.spliceThreshold), path_precision: UInt32(clamping: options.pathPrecision),
            premultiplied: true)
        var buffer = MorphBuffer(ptr: nil, len: 0, cap: 0)
        let status = pixels.data.withUnsafeBytes { raw in
            morph_trace_svg(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(pixels.width), UInt32(pixels.height),
                            &opts, &buffer)
        }
        try check(status)
        return take(buffer)
    }
}

/// Tightly packed, premultiplied RGBA8 pixels of a CGImage.
struct RGBAPixels {
    let data: Data
    let width: Int
    let height: Int
    /// ICC profile to embed (nil when the pixels are sRGB).
    let iccProfile: Data?

    init(image: CGImage, forceSRGB: Bool = false) throws {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var space = srgb
        if !forceSRGB, let own = image.colorSpace, own.model == .rgb, own.numberOfComponents == 3 {
            space = own
        }
        let bytesPerRow = width * 4
        var buffer = Data(count: bytesPerRow * height)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw RustCodecError(code: MORPH_ERR_INVALID_ARGUMENT, message: "Unsupported pixel format.") }
        data = buffer
        let isSRGB = space.name == CGColorSpace.sRGB
        iccProfile = isSRGB ? nil : space.copyICCData() as Data?
    }
}
