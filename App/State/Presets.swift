import Foundation
import MorphKit

/// One-click conversions offered in the menu bar (and when dropping on its icon).
enum QuickAction: String, CaseIterable, Identifiable, Codable {
    case toJPEG, toPNG, toWebP, toHEIC, toMP4, toGIF, compress, toMP3

    static let defaults: [QuickAction] = [.toJPEG, .toWebP, .toMP4, .compress, .toMP3]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toJPEG: "JPEG"
        case .toPNG: "PNG"
        case .toWebP: "WebP"
        case .toHEIC: "HEIC"
        case .toMP4: "MP4"
        case .toGIF: "GIF"
        case .compress: "Compress"
        case .toMP3: "MP3"
        }
    }

    var symbol: String {
        switch self {
        case .toJPEG, .toPNG, .toHEIC: "photo"
        case .toWebP: "globe"
        case .toMP4: "film"
        case .toGIF: "sparkles.rectangle.stack"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .toMP3: "music.note"
        }
    }

    var subtitle: String {
        switch self {
        case .compress: "Same format"
        case .toMP3: "Audio only"
        case .toGIF: "From video"
        default: "Convert"
        }
    }

    /// Settings to use for files of `kind`, or nil if the action doesn't apply.
    func settings(for kind: MediaKind, base: ConversionSettings) -> ConversionSettings? {
        var settings = base
        switch (self, kind) {
        case (.toJPEG, .image), (.toJPEG, .pdf): settings.target = .jpeg
        case (.toPNG, .image), (.toPNG, .pdf): settings.target = .png
        case (.toWebP, .image), (.toWebP, .pdf): settings.target = .webp
        case (.toHEIC, .image), (.toHEIC, .pdf): settings.target = .heic
        case (.toJPEG, .video): settings.target = .frameJPEG
        case (.toMP4, .video): settings.target = .mp4H264
        case (.toGIF, .video): settings.target = .gifAnimated
        case (.toMP3, .video), (.toMP3, .audio): settings.target = .mp3
        case (.compress, .image), (.compress, .video), (.compress, .audio):
            settings.target = .original
            settings.image.quality = min(settings.image.quality, 0.7)
            settings.video.quality = min(settings.video.quality, 0.5)
            settings.audio.quality = min(settings.audio.quality, 0.5)
        default: return nil
        }
        return settings
    }
}

/// Saved or built-in conversion recipes.
struct Preset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var kind: MediaKind
    var settings: ConversionSettings
    var isBuiltIn: Bool

    static let builtIns: [Preset] = {
        var web = ConversionSettings(target: .webp)
        web.image.quality = 0.8
        web.image.resize = .longestSide(2048)
        web.image.colorProfile = .sRGB

        var email = ConversionSettings(target: .jpeg)
        email.image.quality = 0.8
        email.image.sizeLimit = 1_000_000
        email.image.resize = .longestSide(2560)

        var share = ConversionSettings(target: .mp4H264)
        share.video.quality = 0.6
        share.video.resolution = .shortSide(1080)

        var small = ConversionSettings(target: .mp4HEVC)
        small.video.quality = 0.4
        small.video.resolution = .shortSide(720)

        var edit = ConversionSettings(target: .movProRes)
        edit.video.proresProfile = .standard

        var gif = ConversionSettings(target: .gifAnimated)
        gif.video.quality = 0.5

        var podcast = ConversionSettings(target: .mp3)
        podcast.audio.bitrateKbps = 96
        podcast.audio.variableBitrate = false
        podcast.audio.channels = .mono
        podcast.audio.normalizeLoudness = true

        return [
            Preset(id: "web-image", name: "Web image", symbol: "globe", kind: .image, settings: web, isBuiltIn: true),
            Preset(id: "email-photo", name: "Email photo (≤ 1 MB)", symbol: "envelope", kind: .image, settings: email, isBuiltIn: true),
            Preset(id: "share-video", name: "Share video (1080p)", symbol: "square.and.arrow.up", kind: .video, settings: share, isBuiltIn: true),
            Preset(id: "small-video", name: "Small video (720p HEVC)", symbol: "arrow.down.circle", kind: .video, settings: small, isBuiltIn: true),
            Preset(id: "edit-ready", name: "Edit-ready (ProRes 422)", symbol: "scissors", kind: .video, settings: edit, isBuiltIn: true),
            Preset(id: "chat-gif", name: "Chat GIF", symbol: "bubble.left.and.bubble.right", kind: .video, settings: gif, isBuiltIn: true),
            Preset(id: "podcast-mp3", name: "Podcast MP3", symbol: "mic", kind: .audio, settings: podcast, isBuiltIn: true),
        ]
    }()
}

/// Built-in presets plus the user's own.
@Observable
final class PresetStore {
    static let shared = PresetStore()

    private(set) var custom: [Preset] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: "customPresets"),
           let presets = try? JSONDecoder().decode([Preset].self, from: data) {
            custom = presets
        }
    }

    func presets(for kind: MediaKind) -> [Preset] {
        (Preset.builtIns + custom).filter { $0.kind == kind }
    }

    func save(name: String, kind: MediaKind, settings: ConversionSettings) {
        let preset = Preset(id: UUID().uuidString, name: name, symbol: "star", kind: kind, settings: settings,
                            isBuiltIn: false)
        custom.append(preset)
        persist()
    }

    func delete(_ preset: Preset) {
        custom.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: "customPresets")
        }
    }
}
