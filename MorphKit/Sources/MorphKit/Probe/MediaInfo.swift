import CoreGraphics
import Foundation

public struct ImageInfo: Codable, Sendable, Hashable {
    /// Pixel size after applying EXIF orientation.
    public var width: Int
    public var height: Int
    public var hasAlpha: Bool
    public var frameCount: Int
    public var bitsPerComponent: Int
    public var isHDR: Bool
    public var dpi: Double?

    public var isAnimated: Bool { frameCount > 1 }
    public var pixelCount: Int { width * height }

    public init(width: Int, height: Int, hasAlpha: Bool, frameCount: Int = 1, bitsPerComponent: Int = 8,
                isHDR: Bool = false, dpi: Double? = nil) {
        self.width = width
        self.height = height
        self.hasAlpha = hasAlpha
        self.frameCount = frameCount
        self.bitsPerComponent = bitsPerComponent
        self.isHDR = isHDR
        self.dpi = dpi
    }
}

public struct VideoStreamInfo: Codable, Sendable, Hashable {
    public var index: Int
    public var codec: String
    /// Coded size (before rotation).
    public var width: Int
    public var height: Int
    /// Clockwise display rotation in degrees (0, 90, 180, 270).
    public var rotation: Int
    public var frameRate: Double
    public var bitRate: Int?
    public var pixelFormat: String?
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var colorSpace: String?
    public var profile: String?
    public var hasAlpha: Bool

    public init(index: Int, codec: String, width: Int, height: Int, rotation: Int = 0, frameRate: Double,
                bitRate: Int? = nil, pixelFormat: String? = nil, colorTransfer: String? = nil,
                colorPrimaries: String? = nil, colorSpace: String? = nil, profile: String? = nil,
                hasAlpha: Bool = false) {
        self.index = index
        self.codec = codec
        self.width = width
        self.height = height
        self.rotation = rotation
        self.frameRate = frameRate
        self.bitRate = bitRate
        self.pixelFormat = pixelFormat
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.colorSpace = colorSpace
        self.profile = profile
        self.hasAlpha = hasAlpha
    }

    public var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" }
    public var isHLG: Bool { colorTransfer == "arib-std-b67" }

    public var bitDepth: Int {
        guard let fmt = pixelFormat else { return 8 }
        if fmt.contains("p10") || fmt.contains("10le") || fmt.contains("10be") || fmt == "p010le" || fmt == "p210le" {
            return 10
        }
        if fmt.contains("12le") || fmt.contains("12be") { return 12 }
        if fmt.contains("16le") || fmt.contains("16be") { return 16 }
        return 8
    }

    /// Size as displayed (rotation applied).
    public var displayWidth: Int { rotation % 180 == 0 ? width : height }
    public var displayHeight: Int { rotation % 180 == 0 ? height : width }
}

public struct AudioStreamInfo: Codable, Sendable, Hashable {
    public var index: Int
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var bitRate: Int?

    public init(index: Int, codec: String, sampleRate: Int, channels: Int, bitRate: Int? = nil) {
        self.index = index
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
    }

    public var isLossless: Bool {
        ["flac", "alac", "wavpack", "tta", "ape", "truehd", "mlp"].contains(codec) || codec.hasPrefix("pcm_")
    }
}

/// Probe results for anything FFmpeg reads (video and audio files).
public struct AVInfo: Codable, Sendable, Hashable {
    public var duration: Double
    public var bitRate: Int?
    public var formatName: String
    public var video: VideoStreamInfo?
    public var audio: AudioStreamInfo?
    public var audioStreamCount: Int
    public var hasCoverArt: Bool

    public init(duration: Double, bitRate: Int?, formatName: String, video: VideoStreamInfo?, audio: AudioStreamInfo?,
                audioStreamCount: Int, hasCoverArt: Bool) {
        self.duration = duration
        self.bitRate = bitRate
        self.formatName = formatName
        self.video = video
        self.audio = audio
        self.audioStreamCount = audioStreamCount
        self.hasCoverArt = hasCoverArt
    }

    public var isHDR: Bool { video?.isHDR ?? false }
}

public struct PDFInfo: Codable, Sendable, Hashable {
    public var pageCount: Int
    /// Size of the first page in points (1/72 inch).
    public var pageWidth: Double
    public var pageHeight: Double

    public init(pageCount: Int, pageWidth: Double, pageHeight: Double) {
        self.pageCount = pageCount
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
    }
}

public enum MediaInfo: Codable, Sendable, Hashable {
    case image(ImageInfo)
    case media(AVInfo)
    case pdf(PDFInfo)

    public var image: ImageInfo? { if case .image(let i) = self { i } else { nil } }
    public var media: AVInfo? { if case .media(let m) = self { m } else { nil } }
    public var pdf: PDFInfo? { if case .pdf(let p) = self { p } else { nil } }

    public var duration: Double? { media?.duration }
}

/// A file the user added.
public struct MediaItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let format: FileFormat
    public let fileSize: Int64
    public let modificationDate: Date
    public var info: MediaInfo?

    public init(id: UUID = UUID(), url: URL, format: FileFormat, fileSize: Int64, modificationDate: Date,
                info: MediaInfo? = nil) {
        self.id = id
        self.url = url
        self.format = format
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.info = info
    }

    public var kind: MediaKind { format.kind }
    public var name: String { url.lastPathComponent }
    public var baseName: String { url.deletingPathExtension().lastPathComponent }

    public var isAnimatedImage: Bool { info?.image?.isAnimated ?? false }

    /// Identity used for caching (changes when the file changes).
    public var cacheIdentity: String {
        "\(url.path)|\(fileSize)|\(modificationDate.timeIntervalSinceReferenceDate)"
    }

    /// One-line description, e.g. "HEIC · 4032×3024".
    public var summary: String {
        var parts: [String] = [format == .otherImage || format == .otherVideo || format == .otherAudio
            ? url.pathExtension.uppercased() : format.displayName]
        switch info {
        case .image(let image)?:
            parts.append("\(image.width)×\(image.height)")
            if image.isAnimated { parts.append("\(image.frameCount) frames") }
            if image.isHDR { parts.append("HDR") }
        case .media(let media)?:
            if let video = media.video {
                var res = "\(video.displayWidth)×\(video.displayHeight)"
                if video.isHDR { res += " HDR" }
                parts.append(res)
            } else if let audio = media.audio {
                parts.append(audio.channels == 1 ? "Mono" : audio.channels == 2 ? "Stereo" : "\(audio.channels) ch")
            }
            parts.append(Formatters.duration(media.duration))
        case .pdf(let pdf)?:
            parts.append(pdf.pageCount == 1 ? "1 page" : "\(pdf.pageCount) pages")
        case nil:
            break
        }
        return parts.joined(separator: " · ")
    }
}
