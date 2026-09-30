import Foundation
import UniformTypeIdentifiers

/// Groups output tiles in the format picker.
public enum OutputCategory: String, Codable, Sendable, CaseIterable {
    case original, image, video, animated, audio, document, vector, frame

    public var displayName: String {
        switch self {
        case .original: "Keep format"
        case .image: "Image"
        case .animated: "Animated"
        case .video: "Video"
        case .audio: "Audio only"
        case .document: "Document"
        case .vector: "Vector"
        case .frame: "Still frame"
        }
    }
}

/// Hints shown on format tiles.
public enum FormatBadge: String, Codable, Sendable, Hashable {
    case smallest, compatible, lossless, transparency, animated, hdr, editing, web

    public var title: String {
        switch self {
        case .smallest: "Smallest"
        case .compatible: "Most compatible"
        case .lossless: "Lossless"
        case .transparency: "Transparency"
        case .animated: "Animated"
        case .hdr: "HDR"
        case .editing: "For editing"
        case .web: "Web"
        }
    }
}

/// Who can open a file in a given format without installing anything.
public enum Compatibility: String, Codable, Sendable, CaseIterable {
    case everywhere, modern, apple, editing, limited

    public var title: String {
        switch self {
        case .everywhere: "Opens everywhere"
        case .modern: "Newer devices"
        case .apple: "Best on Apple devices"
        case .editing: "For editing apps"
        case .limited: "Few apps"
        }
    }

    public var explanation: String {
        switch self {
        case .everywhere: "Opens on any computer, phone and website."
        case .modern: "Works in current browsers and recent devices. Some older apps can't open it."
        case .apple: "Plays everywhere on Apple devices. Windows and Android may need an extra app."
        case .editing: "Made for editing and print apps. Files are large."
        case .limited: "Only some apps can open it."
        }
    }

    public var symbolName: String {
        switch self {
        case .everywhere: "checkmark.seal.fill"
        case .modern: "sparkles"
        case .apple: "apple.logo"
        case .editing: "slider.horizontal.below.rectangle"
        case .limited: "exclamationmark.circle"
        }
    }
}

/// A conversion target the user can pick ("tile"). Video/audio targets imply sensible
/// container + codec defaults; Pro options may override the codec afterwards.
public enum OutputFormat: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// Same format as the input — compress only.
    case original
    /// Images: the most compatible format for each file (JPEG for photos, PNG for graphics
    /// with transparency, GIF for animations). JPEG, PNG and GIF files keep their format.
    case auto

    // Still images
    case jpeg, png, heic, avif, webp, tiff, gif, bmp, jp2, ico, icns
    // Documents
    case pdf, pdfCombined
    // Vector
    case svgTrace
    // Animated (from video)
    case gifAnimated, webpAnimated
    // Video
    case mp4H264, mp4HEVC, mp4AV1, movH264, movHEVC, movProRes, webmVP9, webmAV1, mkvHEVC
    // Audio
    case mp3, m4aAAC, m4aALAC, wav, aiff, flac, opus
    // Still frame from a video
    case frameJPEG, framePNG

    public var id: String { rawValue }

    public var category: OutputCategory {
        switch self {
        case .original: .original
        case .auto, .jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .bmp, .jp2, .ico, .icns: .image
        case .pdf, .pdfCombined: .document
        case .svgTrace: .vector
        case .gifAnimated, .webpAnimated: .animated
        case .mp4H264, .mp4HEVC, .mp4AV1, .movH264, .movHEVC, .movProRes, .webmVP9, .webmAV1, .mkvHEVC: .video
        case .mp3, .m4aAAC, .m4aALAC, .wav, .aiff, .flac, .opus: .audio
        case .frameJPEG, .framePNG: .frame
        }
    }

    public var displayName: String {
        switch self {
        case .original: "Original"
        case .auto: "Auto"
        case .jpeg, .frameJPEG: "JPEG"
        case .png, .framePNG: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp, .webpAnimated: "WebP"
        case .tiff: "TIFF"
        case .gif, .gifAnimated: "GIF"
        case .bmp: "BMP"
        case .jp2: "JPEG 2000"
        case .ico: "ICO"
        case .icns: "ICNS"
        case .pdf: "PDF"
        case .pdfCombined: "PDF"
        case .svgTrace: "SVG"
        case .mp4H264, .mp4HEVC, .mp4AV1: "MP4"
        case .movH264, .movHEVC, .movProRes: "MOV"
        case .webmVP9, .webmAV1: "WebM"
        case .mkvHEVC: "MKV"
        case .mp3: "MP3"
        case .m4aAAC, .m4aALAC: "M4A"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .opus: "Opus"
        }
    }

    /// Secondary line on the tile.
    public var detail: String {
        switch self {
        case .original: "Compress only"
        case .auto: "JPEG · PNG · GIF"
        case .jpeg: "Photos"
        case .png: "Lossless"
        case .heic: "Apple photos"
        case .avif: "Modern web"
        case .webp: "Web"
        case .tiff: "Print"
        case .gif: "Simple graphics"
        case .bmp: "Uncompressed"
        case .jp2: "Archival"
        case .ico: "Windows icon"
        case .icns: "macOS icon"
        case .pdf: "One per file"
        case .pdfCombined: "Combine all"
        case .svgTrace: "Traced vector"
        case .gifAnimated: "Animated"
        case .webpAnimated: "Animated"
        case .mp4H264, .movH264: "H.264"
        case .mp4HEVC, .movHEVC, .mkvHEVC: "HEVC"
        case .mp4AV1, .webmAV1: "AV1"
        case .movProRes: "ProRes"
        case .webmVP9: "VP9"
        case .mp3: "Universal"
        case .m4aAAC: "AAC"
        case .m4aALAC: "Apple Lossless"
        case .wav: "Uncompressed"
        case .aiff: "Uncompressed"
        case .flac: "Lossless"
        case .opus: "Efficient"
        case .frameJPEG, .framePNG: "Frame"
        }
    }

    public var badges: [FormatBadge] {
        switch self {
        case .auto, .jpeg, .mp4H264, .mp3: [.compatible]
        case .png: [.lossless, .transparency]
        case .heic: [.smallest, .hdr]
        case .avif: [.smallest, .transparency]
        case .webp: [.web, .transparency]
        case .webpAnimated: [.web, .animated]
        case .gifAnimated: [.animated]
        case .mp4HEVC, .movHEVC, .mkvHEVC: [.smallest, .hdr]
        case .mp4AV1, .webmAV1: [.smallest]
        case .movProRes: [.editing]
        case .webmVP9: [.web]
        case .m4aALAC, .flac, .wav, .aiff, .tiff: [.lossless]
        case .opus: [.smallest]
        case .svgTrace: [.transparency]
        default: []
        }
    }

    /// Extension of the file produced (for `.original` and `.auto` it depends on the input).
    public var fileExtension: String {
        switch self {
        case .original, .auto: ""
        case .jpeg, .frameJPEG: "jpg"
        case .png, .framePNG: "png"
        case .heic: "heic"
        case .avif: "avif"
        case .webp, .webpAnimated: "webp"
        case .tiff: "tiff"
        case .gif, .gifAnimated: "gif"
        case .bmp: "bmp"
        case .jp2: "jp2"
        case .ico: "ico"
        case .icns: "icns"
        case .pdf, .pdfCombined: "pdf"
        case .svgTrace: "svg"
        case .mp4H264, .mp4HEVC, .mp4AV1: "mp4"
        case .movH264, .movHEVC, .movProRes: "mov"
        case .webmVP9, .webmAV1: "webm"
        case .mkvHEVC: "mkv"
        case .mp3: "mp3"
        case .m4aAAC, .m4aALAC: "m4a"
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .opus: "opus"
        }
    }

    /// The still-image file format produced by image targets.
    public var imageFormat: FileFormat? {
        switch self {
        case .jpeg, .frameJPEG: .jpeg
        case .png, .framePNG: .png
        case .heic: .heic
        case .avif: .avif
        case .webp: .webp
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .jp2: .jp2
        case .ico: .ico
        case .icns: .icns
        case .pdf, .pdfCombined: .pdf
        case .svgTrace: .svg
        default: nil
        }
    }

    /// Whether the quality slider has an effect for this target.
    public var usesQualitySlider: Bool {
        switch self {
        case .bmp, .tiff, .wav, .aiff, .ico, .icns, .m4aALAC, .flac, .svgTrace: false
        default: true
        }
    }

    /// Explanation shown in place of the slider when it has no effect.
    public var qualityNote: String? {
        switch self {
        case .bmp: "BMP is uncompressed. Resize in Pro mode to reduce size."
        case .tiff: "TIFF is saved losslessly. Resize in Pro mode to reduce size."
        case .wav, .aiff: "Uncompressed audio. Lower the sample rate in Pro mode to reduce size."
        case .m4aALAC, .flac: "Lossless audio keeps every detail."
        case .ico, .icns: "Icons include several sizes of the image."
        case .svgTrace: "Use Pro mode to tune colors and detail."
        default: nil
        }
    }

    /// Who can open the result. nil when it depends on the input (`.original`) or doesn't apply (icons).
    public var compatibility: Compatibility? {
        switch self {
        case .original, .ico, .icns: nil
        case .auto, .jpeg, .png, .gif, .bmp, .pdf, .pdfCombined, .svgTrace, .gifAnimated, .mp4H264, .mp3, .m4aAAC,
             .wav, .frameJPEG, .framePNG: .everywhere
        case .webp, .avif, .webpAnimated, .mp4HEVC, .mp4AV1, .webmVP9, .webmAV1, .flac, .opus: .modern
        case .heic, .movH264, .movHEVC, .m4aALAC, .aiff: .apple
        case .tiff, .movProRes: .editing
        case .jp2, .mkvHEVC: .limited
        }
    }

    public var isVideoTarget: Bool { category == .video }
    public var isAudioTarget: Bool { category == .audio }
    public var isAnimatedTarget: Bool { category == .animated }
}
