import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ProbeError: Error, LocalizedError, Sendable {
    case unreadable(String)
    case noFFmpeg

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): reason
        case .noFFmpeg: "FFmpeg isn't available, so videos and audio can't be read."
        }
    }
}

/// Reads image properties with ImageIO (no pixel decoding).
public enum ImageProbe {
    public static func probe(url: URL, format: FileFormat) throws -> ImageInfo {
        if format == .svg {
            let data = try Data(contentsOf: url)
            let size = try RustCodecs.svgSize(data: data)
            return ImageInfo(width: Int(size.width.rounded()), height: Int(size.height.rounded()), hasAlpha: true)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else {
            throw ProbeError.unreadable("This image can't be read.")
        }
        return try probe(source: source)
    }

    public static func probe(source: CGImageSource) throws -> ImageInfo {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            throw ProbeError.unreadable("This image has no readable properties.")
        }
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }
        guard width > 0, height > 0 else { throw ProbeError.unreadable("This image has no pixels.") }

        let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let depth = props[kCGImagePropertyDepth] as? Int ?? 8
        let dpi = props[kCGImagePropertyDPIWidth] as? Double
        let hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil

        // Animated GIF/APNG/WebP/HEICS report several images; multi-image HEIC (bursts, depth)
        // are not animations, so only count frames for formats with delay metadata.
        var frames = CGImageSourceGetCount(source)
        if frames > 1 {
            let isAnimation = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary,
                               kCGImagePropertyWebPDictionary, kCGImagePropertyHEICSDictionary]
                .contains { key in
                    guard let dict = props[key] as? [CFString: Any] else { return false }
                    return dict[kCGImagePropertyGIFDelayTime] != nil || dict[kCGImagePropertyAPNGDelayTime] != nil
                        || dict[kCGImagePropertyWebPDelayTime] != nil || dict[kCGImagePropertyHEICSDelayTime] != nil
                        || dict[kCGImagePropertyGIFUnclampedDelayTime] != nil
                        || dict[kCGImagePropertyAPNGUnclampedDelayTime] != nil
                        || dict[kCGImagePropertyWebPUnclampedDelayTime] != nil
                        || dict[kCGImagePropertyHEICSUnclampedDelayTime] != nil
                }
            if !isAnimation { frames = 1 }
        }
        return ImageInfo(width: width, height: height, hasAlpha: hasAlpha, frameCount: frames,
                         bitsPerComponent: depth, isHDR: hasGainMap || depth > 8, dpi: dpi)
    }
}

/// Reads PDF page count and size.
public enum PDFProbe {
    public static func probe(url: URL) throws -> PDFInfo {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw ProbeError.unreadable("This PDF can't be opened.")
        }
        if document.isEncrypted && !document.isUnlocked {
            throw ProbeError.unreadable("This PDF is password-protected.")
        }
        guard document.numberOfPages > 0, let page = document.page(at: 1) else {
            throw ProbeError.unreadable("This PDF has no pages.")
        }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        return PDFInfo(pageCount: document.numberOfPages,
                       pageWidth: Double(rotated ? box.height : box.width),
                       pageHeight: Double(rotated ? box.width : box.height))
    }
}

/// Runs `ffprobe` and parses its JSON.
public enum FFProbe {
    public static func probe(url: URL, tools: FFmpegTools) async throws -> AVInfo {
        let output = try await ChildProcess.run(tools.ffprobe, arguments: [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "--", url.path,
        ])
        guard output.status == 0 else {
            let log = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProbeError.unreadable(log.isEmpty ? "This file can't be read."
                : FriendlyErrors.explain(ffmpegLog: log, exitStatus: output.status).message)
        }
        return try parse(json: output.stdout)
    }

    /// Codecs FFmpeg can't decode or that aren't real media (iPhone spatial audio, metadata tracks).
    static let ignoredCodecs: Set<String> = ["apac", "none", "bin_data", "mebx", "tmcd", "timed_id3"]

    public static func parse(json: Data) throws -> AVInfo {
        let root = try JSONDecoder().decode(Root.self, from: json)
        let streams = root.streams ?? []

        let videoStream = streams.first { s in
            s.codec_type == "video" && s.disposition?.attached_pic != 1 && !ignoredCodecs.contains(s.codec_name ?? "none")
        }
        let audioStreams = streams.filter { s in
            s.codec_type == "audio" && !ignoredCodecs.contains(s.codec_name ?? "none") && (s.channels ?? 0) > 0
        }
        // Prefer the default stereo track; iPhone files list spatial audio first.
        let audioStream = audioStreams.first { $0.disposition?.default == 1 } ?? audioStreams.first
        let coverArt = streams.contains { $0.codec_type == "video" && $0.disposition?.attached_pic == 1 }

        var duration = Double(root.format?.duration ?? "") ?? 0
        if duration <= 0 {
            duration = streams.compactMap { Double($0.duration ?? "") }.max() ?? 0
        }

        let video = videoStream.map { s -> VideoStreamInfo in
            VideoStreamInfo(
                index: s.index,
                codec: s.codec_name ?? "unknown",
                width: s.width ?? 0,
                height: s.height ?? 0,
                rotation: rotation(of: s),
                frameRate: rate(s.avg_frame_rate) ?? rate(s.r_frame_rate) ?? 30,
                bitRate: Int(s.bit_rate ?? ""),
                pixelFormat: s.pix_fmt,
                colorTransfer: s.color_transfer,
                colorPrimaries: s.color_primaries,
                colorSpace: s.color_space,
                profile: s.profile,
                hasAlpha: (s.pix_fmt ?? "").contains("a") && ["yuva420p", "yuva444p", "rgba", "bgra", "argb", "gbrap", "yuva444p10le", "ya8", "pal8"].contains(s.pix_fmt ?? "")
            )
        }
        let audio = audioStream.map { s in
            AudioStreamInfo(index: s.index, codec: s.codec_name ?? "unknown",
                            sampleRate: Int(s.sample_rate ?? "") ?? 48000, channels: s.channels ?? 2,
                            bitRate: Int(s.bit_rate ?? ""))
        }
        return AVInfo(duration: duration, bitRate: Int(root.format?.bit_rate ?? ""),
                      formatName: root.format?.format_name ?? "", video: video, audio: audio,
                      audioStreamCount: audioStreams.count, hasCoverArt: coverArt)
    }

    static func rate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 {
            let value = n / d
            return value > 0 && value < 1000 ? value : nil
        }
        return Double(text)
    }

    static func rotation(of stream: Stream) -> Int {
        var degrees = 0.0
        if let side = stream.side_data_list?.first(where: { $0.rotation != nil })?.rotation {
            // FFmpeg reports counter-clockwise rotation of the display matrix.
            degrees = -side
        } else if let tag = stream.tags?.rotate, let value = Double(tag) {
            degrees = value
        }
        let normalized = ((Int(degrees.rounded()) % 360) + 360) % 360
        return (normalized / 90) * 90
    }

    struct Root: Decodable {
        var streams: [Stream]?
        var format: Format?
    }

    struct Format: Decodable {
        var format_name: String?
        var duration: String?
        var bit_rate: String?
    }

    struct Disposition: Decodable {
        var `default`: Int?
        var attached_pic: Int?
    }

    struct SideData: Decodable {
        var rotation: Double?
    }

    struct Tags: Decodable {
        var rotate: String?
    }

    struct Stream: Decodable {
        var index: Int
        var codec_name: String?
        var codec_type: String?
        var profile: String?
        var width: Int?
        var height: Int?
        var pix_fmt: String?
        var color_transfer: String?
        var color_primaries: String?
        var color_space: String?
        var avg_frame_rate: String?
        var r_frame_rate: String?
        var bit_rate: String?
        var duration: String?
        var sample_rate: String?
        var channels: Int?
        var disposition: Disposition?
        var side_data_list: [SideData]?
        var tags: Tags?
    }
}

/// Creates `MediaItem`s from URLs and fills in their `MediaInfo`.
public enum MediaProbe {
    /// Basic, synchronous identification (no decoding). Returns nil for unsupported files.
    public static func item(for url: URL) -> MediaItem? {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        // Symlinks are read through (the item keeps the link's path, so outputs land next to it).
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys),
              values.isRegularFile == true else { return nil }
        guard let format = FileFormat.detect(url: url, contentType: values.contentType) else { return nil }
        return MediaItem(url: url, format: format, fileSize: Int64(values.fileSize ?? 0),
                         modificationDate: values.contentModificationDate ?? .distantPast)
    }

    /// Reads format details. Images and PDFs are probed natively; video/audio with ffprobe.
    public static func info(for item: MediaItem, tools: FFmpegTools?) async throws -> MediaInfo {
        switch item.kind {
        case .image:
            let url = item.url, format = item.format
            return .image(try await BlockingWork.run { try ImageProbe.probe(url: url, format: format) })
        case .pdf:
            let url = item.url
            return .pdf(try await BlockingWork.run { try PDFProbe.probe(url: url) })
        case .video, .audio:
            guard let tools else { throw ProbeError.noFFmpeg }
            let info = try await FFProbe.probe(url: item.url, tools: tools)
            if item.kind == .video && info.video == nil && info.audio == nil {
                throw ProbeError.unreadable("No playable video or audio was found.")
            }
            return .media(info)
        }
    }
}
