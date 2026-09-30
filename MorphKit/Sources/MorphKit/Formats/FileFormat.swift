import Foundation
import UniformTypeIdentifiers

/// The broad family a file belongs to. Drives grouping in the UI and engine routing.
public enum MediaKind: String, Codable, Sendable, CaseIterable, Comparable {
    case image, video, audio, pdf

    public var displayName: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        }
    }

    public var singularName: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        }
    }

    public var symbolName: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: MediaKind, rhs: MediaKind) -> Bool { lhs.order < rhs.order }
}

/// A concrete container/file format that Morph can read (and possibly write).
public enum FileFormat: String, Codable, Sendable, CaseIterable, Hashable {
    // Raster & vector images
    case jpeg, png, heic, heif, avif, webp, tiff, gif, bmp, ico, icns, jp2, psd, tga, exr, dds, jxl, raw, svg
    case otherImage
    // Documents
    case pdf
    // Video
    case mp4, mov, m4v, mkv, webm, avi, wmv, flv, mpeg, ts, mts, threeGP, ogv, mxf, dv, vob
    case otherVideo
    // Audio
    case mp3, m4a, aac, wav, aiff, flac, ogg, opus, wma, ac3, caf, amr
    case otherAudio

    public var kind: MediaKind {
        switch self {
        case .jpeg, .png, .heic, .heif, .avif, .webp, .tiff, .gif, .bmp, .ico, .icns, .jp2, .psd, .tga, .exr,
             .dds, .jxl, .raw, .svg, .otherImage:
            .image
        case .pdf:
            .pdf
        case .mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv, .flv, .mpeg, .ts, .mts, .threeGP, .ogv, .mxf, .dv, .vob,
             .otherVideo:
            .video
        case .mp3, .m4a, .aac, .wav, .aiff, .flac, .ogg, .opus, .wma, .ac3, .caf, .amr, .otherAudio:
            .audio
        }
    }

    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .jp2: "JPEG 2000"
        case .threeGP: "3GP"
        case .raw: "RAW"
        case .otherImage: "Image"
        case .otherVideo: "Video"
        case .otherAudio: "Audio"
        case .aiff: "AIFF"
        default: rawValue.uppercased()
        }
    }

    /// Preferred extension when writing this format.
    public var preferredExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .threeGP: "3gp"
        case .jp2: "jp2"
        case .tiff: "tiff"
        case .aiff: "aiff"
        case .otherImage, .otherVideo, .otherAudio, .raw: "bin"
        default: rawValue
        }
    }

    public var isVector: Bool { self == .svg }

    /// Formats whose files may contain several frames (animation).
    public var mayBeAnimated: Bool {
        switch self {
        case .gif, .webp, .png, .heic, .heif, .avif: true
        default: false
        }
    }

    public var utType: UTType? {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .heif: .heif
        case .avif: UTType("public.avif")
        case .webp: .webP
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .ico: .ico
        case .icns: .icns
        case .jp2: UTType("public.jpeg-2000")
        case .psd: UTType("com.adobe.photoshop-image")
        case .tga: UTType("com.truevision.tga-image")
        case .exr: UTType("com.ilm.openexr-image")
        case .dds: UTType("com.microsoft.dds")
        case .jxl: UTType("public.jpeg-xl")
        case .raw: .rawImage
        case .svg: .svg
        case .pdf: .pdf
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .m4v: UTType("com.apple.m4v-video")
        case .mkv: UTType("org.matroska.mkv")
        case .webm: UTType("org.webmproject.webm")
        case .avi: .avi
        case .mpeg: .mpeg
        case .ts, .mts: UTType("public.mpeg-2-transport-stream")
        case .threeGP: UTType("public.3gpp")
        case .mp3: .mp3
        case .m4a: .mpeg4Audio
        case .aac: UTType("public.aac-audio")
        case .wav: .wav
        case .aiff: .aiff
        case .flac: UTType("org.xiph.flac")
        case .opus: UTType("org.xiph.opus")
        case .ogg: UTType("org.xiph.ogg-audio")
        default: nil
        }
    }

    // MARK: Detection

    private static let byExtension: [String: FileFormat] = [
        "jpg": .jpeg, "jpeg": .jpeg, "jpe": .jpeg, "jfif": .jpeg,
        "png": .png, "apng": .png,
        "heic": .heic, "heics": .heic, "hif": .heif, "heif": .heif,
        "avif": .avif, "avifs": .avif,
        "webp": .webp,
        "tif": .tiff, "tiff": .tiff,
        "gif": .gif,
        "bmp": .bmp, "dib": .bmp,
        "ico": .ico, "cur": .ico,
        "icns": .icns,
        "jp2": .jp2, "j2k": .jp2, "jpf": .jp2, "jpx": .jp2,
        "psd": .psd,
        "tga": .tga,
        "exr": .exr,
        "dds": .dds,
        "jxl": .jxl,
        "dng": .raw, "cr2": .raw, "cr3": .raw, "crw": .raw, "nef": .raw, "nrw": .raw, "arw": .raw, "srf": .raw,
        "sr2": .raw, "raf": .raw, "orf": .raw, "rw2": .raw, "pef": .raw, "srw": .raw, "3fr": .raw, "fff": .raw,
        "iiq": .raw, "rwl": .raw, "mrw": .raw, "x3f": .raw, "erf": .raw, "kdc": .raw, "dcr": .raw, "mos": .raw,
        "svg": .svg, "svgz": .svg,
        "pdf": .pdf,
        "mp4": .mp4, "m4v": .m4v, "mov": .mov, "qt": .mov,
        "mkv": .mkv, "mk3d": .mkv, "webm": .webm, "avi": .avi, "wmv": .wmv, "asf": .wmv, "flv": .flv,
        "mpg": .mpeg, "mpeg": .mpeg, "m2v": .mpeg, "ts": .ts, "m2ts": .mts, "mts": .mts,
        "3gp": .threeGP, "3g2": .threeGP, "ogv": .ogv, "mxf": .mxf, "dv": .dv, "vob": .vob,
        "mp3": .mp3, "m4a": .m4a, "m4b": .m4a, "aac": .aac, "adts": .aac, "wav": .wav, "wave": .wav,
        "aif": .aiff, "aiff": .aiff, "aifc": .aiff, "flac": .flac, "ogg": .ogg, "oga": .ogg, "opus": .opus,
        "wma": .wma, "ac3": .ac3, "eac3": .ac3, "caf": .caf, "amr": .amr,
    ]

    /// Detects the format of a file from its extension, falling back to its Uniform Type.
    public static func detect(url: URL, contentType: UTType? = nil) -> FileFormat? {
        let ext = url.pathExtension.lowercased()
        if let format = byExtension[ext] { return format }
        let type = contentType ?? UTType(filenameExtension: ext)
        guard let type else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .svg) { return .svg }
        if type.conforms(to: .rawImage) { return .raw }
        if type.conforms(to: .image) { return .otherImage }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .otherVideo }
        if type.conforms(to: .audio) { return .otherAudio }
        return nil
    }

    /// All file extensions Morph accepts (used by open panels and folder scans).
    public static var supportedExtensions: Set<String> { Set(byExtension.keys) }

    public static var supportedContentTypes: [UTType] {
        [.image, .movie, .video, .audio, .pdf, .svg]
    }
}
