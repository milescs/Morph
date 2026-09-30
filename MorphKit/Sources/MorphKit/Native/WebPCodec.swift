import Accelerate
import CoreGraphics
import Foundation
import libwebp

public struct WebPError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// WebP encoding through libwebp (still + animated), with ICC/XMP metadata via WebPMux.
enum WebPCodec {
    struct Options {
        /// 0…100
        var quality: Float
        var lossless: Bool
        /// 0 (fast) … 6 (slow, smaller)
        var method: Int32
        var alphaQuality: Int32 = 100
        var sharpYUV = true
    }

    struct Frame {
        let image: CGImage
        /// Frame duration in milliseconds.
        let durationMs: Int
    }

    /// Encodes pixels in `colorSpace`; pass that space's ICC profile as `icc` (nil for sRGB).
    static func encode(image: CGImage, colorSpace: CGColorSpace, options: Options, icc: Data?, xmp: Data?) throws -> Data {
        var config = try makeConfig(options)
        let bitstream = try withPicture(image: image, colorSpace: colorSpace, lossless: options.lossless) { picture in
            try encodePicture(&picture, config: &config)
        }
        return try mux(bitstream, icc: icc, xmp: xmp)
    }

    static func encodeAnimation(frames: [Frame], loopCount: Int, colorSpace: CGColorSpace, options: Options,
                                icc: Data?) throws -> Data {
        guard let first = frames.first else { throw WebPError(message: "No frames to encode.") }
        var config = try makeConfig(options)
        var animOptions = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&animOptions) != 0 else { throw WebPError(message: "libwebp version mismatch.") }
        animOptions.anim_params.loop_count = Int32(loopCount)
        animOptions.allow_mixed = options.lossless ? 0 : 1
        guard let encoder = WebPAnimEncoderNew(Int32(first.image.width), Int32(first.image.height), &animOptions) else {
            throw WebPError(message: "Couldn't start the animated WebP encoder.")
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var timestamp: Int32 = 0
        for frame in frames {
            try withPicture(image: frame.image, colorSpace: colorSpace, lossless: options.lossless) { picture in
                guard WebPAnimEncoderAdd(encoder, &picture, timestamp, &config) != 0 else {
                    throw WebPError(message: "Couldn't add an animation frame (\(picture.error_code.rawValue)).")
                }
            }
            timestamp += Int32(max(10, frame.durationMs))
        }
        guard WebPAnimEncoderAdd(encoder, nil, timestamp, nil) != 0 else {
            throw WebPError(message: "Couldn't finish the animation.")
        }
        var output = WebPData()
        guard WebPAnimEncoderAssemble(encoder, &output) != 0, let bytes = output.bytes else {
            throw WebPError(message: "Couldn't assemble the animated WebP.")
        }
        let data = Data(bytes: bytes, count: output.size)
        WebPDataClear(&output)
        return icc == nil ? data : try mux(data, icc: icc, xmp: nil)
    }

    // MARK: - Helpers

    private static func makeConfig(_ options: Options) throws -> WebPConfig {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw WebPError(message: "libwebp version mismatch.") }
        if options.lossless {
            // Map quality to lossless effort level (0–9).
            let level = Int32(max(0, min(9, Int(options.quality / 100 * 9))))
            _ = WebPConfigLosslessPreset(&config, level)
            config.lossless = 1
        } else {
            config.quality = max(0, min(100, options.quality))
            config.method = max(0, min(6, options.method))
            config.alpha_quality = options.alphaQuality
            config.use_sharp_yuv = options.sharpYUV ? 1 : 0
        }
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else { throw WebPError(message: "Invalid WebP settings.") }
        return config
    }

    /// Imports a CGImage into a WebPPicture (straight RGBA), runs `body`, and frees it.
    @discardableResult
    private static func withPicture<T>(image: CGImage, colorSpace: CGColorSpace, lossless: Bool,
                                       _ body: (inout WebPPicture) throws -> T) throws -> T {
        let width = image.width, height = image.height
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw WebPError(message: "Unsupported pixel format.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // libwebp expects straight (un-premultiplied) alpha.
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: stride)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw WebPError(message: "libwebp version mismatch.") }
        picture.use_argb = lossless ? 1 : 0
        picture.width = Int32(width)
        picture.height = Int32(height)
        defer { WebPPictureFree(&picture) }
        let imported = pixels.withUnsafeBufferPointer { ptr in
            WebPPictureImportRGBA(&picture, ptr.baseAddress, Int32(stride))
        }
        guard imported != 0 else { throw WebPError(message: "Out of memory while preparing the image.") }
        return try body(&picture)
    }

    private static func encodePicture(_ picture: inout WebPPicture, config: inout WebPConfig) throws -> Data {
        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        WebPMemoryWriterInit(writer)
        defer {
            WebPMemoryWriterClear(writer)
            writer.deallocate()
        }
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)
        guard WebPEncode(&config, &picture) != 0 else {
            throw WebPError(message: "WebP encoding failed (error \(picture.error_code.rawValue)).")
        }
        guard let mem = writer.pointee.mem else { throw WebPError(message: "WebP encoder produced no data.") }
        return Data(bytes: mem, count: writer.pointee.size)
    }

    /// Adds ICC / XMP chunks to a WebP bitstream.
    private static func mux(_ webp: Data, icc: Data?, xmp: Data?) throws -> Data {
        guard icc != nil || xmp != nil else { return webp }
        return try webp.withUnsafeBytes { raw -> Data in
            var image = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            guard let muxer = WebPMuxCreate(&image, 1) else { throw WebPError(message: "Couldn't add metadata.") }
            defer { WebPMuxDelete(muxer) }
            func setChunk(_ fourCC: String, _ payload: Data) {
                payload.withUnsafeBytes { p in
                    var chunk = WebPData(bytes: p.bindMemory(to: UInt8.self).baseAddress, size: p.count)
                    _ = WebPMuxSetChunk(muxer, fourCC, &chunk, 1)
                }
            }
            if let icc, !icc.isEmpty { setChunk("ICCP", icc) }
            if let xmp, !xmp.isEmpty { setChunk("XMP ", xmp) }
            var output = WebPData()
            guard WebPMuxAssemble(muxer, &output) == WEBP_MUX_OK, let bytes = output.bytes else {
                throw WebPError(message: "Couldn't write WebP metadata.")
            }
            let data = Data(bytes: bytes, count: output.size)
            WebPDataClear(&output)
            return data
        }
    }
}
