import AppIntents
import Foundation
import MorphKit
import UniformTypeIdentifiers

// Shortcuts actions. They also show up in Spotlight, and with a Shortcuts automation ("When a file
// is added to a folder") they turn any folder into a watch folder. Converted files are saved next
// to the originals and passed on to the next action.

/// Formats offered in Shortcuts. Each maps to a Morph target per kind of input.
enum IntentFormat: String, AppEnum {
    case jpeg, png, heic, webp, avif, gif, tiff, pdf, mp4, mov, webm, mp3, m4a, wav, flac

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] = [
        .jpeg: "JPEG", .png: "PNG", .heic: "HEIC", .webp: "WebP", .avif: "AVIF", .gif: "GIF", .tiff: "TIFF",
        .pdf: "PDF", .mp4: "MP4 (H.264)", .mov: "MOV (H.264)", .webm: "WebM (VP9)", .mp3: "MP3",
        .m4a: "M4A (AAC)", .wav: "WAV", .flac: "FLAC",
    ]

    /// The target for files of `kind`, or nil when this format doesn't apply to them.
    func target(for kind: MediaKind) -> OutputFormat? {
        switch (self, kind) {
        case (.jpeg, .image), (.jpeg, .pdf): .jpeg
        case (.png, .image), (.png, .pdf): .png
        case (.heic, .image), (.heic, .pdf): .heic
        case (.webp, .image), (.webp, .pdf): .webp
        case (.avif, .image), (.avif, .pdf): .avif
        case (.tiff, .image), (.tiff, .pdf): .tiff
        case (.gif, .image): .gif
        case (.pdf, .image): .pdf
        case (.pdf, .pdf): .original
        case (.jpeg, .video): .frameJPEG
        case (.png, .video): .framePNG
        case (.gif, .video): .gifAnimated
        case (.webp, .video): .webpAnimated
        case (.mp4, .video): .mp4H264
        case (.mov, .video): .movH264
        case (.webm, .video): .webmVP9
        case (.mp3, .video), (.mp3, .audio): .mp3
        case (.m4a, .video), (.m4a, .audio): .m4aAAC
        case (.wav, .video), (.wav, .audio): .wav
        case (.flac, .video), (.flac, .audio): .flac
        default: nil
        }
    }
}

struct ConvertFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Files"
    static let description = IntentDescription(
        "Converts images, videos, audio and PDFs to another format. Converted files are saved next to the originals and passed to the next action.")

    @Parameter(title: "Files", supportedContentTypes: [.image, .movie, .audio, .pdf])
    var files: [IntentFile]

    @Parameter(title: "Format", default: .jpeg)
    var format: IntentFormat

    @Parameter(title: "Quality", description: "0 (smallest) to 100 (best). Leave empty for Morph's default.",
               inclusiveRange: (0, 100))
    var quality: Int?

    @Parameter(title: "Maximum Size (MB)",
               description: "Morph lowers quality, then resolution, until each file fits.")
    var maximumMegabytes: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)") {
            \.$quality
            \.$maximumMegabytes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let format = format, quality = quality, limit = maximumMegabytes
        let outputs = try await IntentSupport.convert(files, title: "Convert to \(format.rawValue.uppercased())") { kind in
            format.target(for: kind).map { IntentSupport.settings(target: $0, kind: kind, quality: quality, megabytes: limit) }
        }
        return .result(value: outputs)
    }
}

struct CompressFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress Files"
    static let description = IntentDescription(
        "Makes images, videos, audio and PDFs smaller in the same format. Saved next to the originals as “name-compressed”.")

    @Parameter(title: "Files", supportedContentTypes: [.image, .movie, .audio, .pdf])
    var files: [IntentFile]

    @Parameter(title: "Maximum Size (MB)",
               description: "Morph lowers quality, then resolution, until each file fits.")
    var maximumMegabytes: Double?

    @Parameter(title: "Quality", description: "0 (smallest) to 100 (best). Leave empty for Morph's default.",
               inclusiveRange: (0, 100))
    var quality: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Compress \(\.$files)") {
            \.$maximumMegabytes
            \.$quality
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let quality = quality, limit = maximumMegabytes
        let outputs = try await IntentSupport.convert(files, title: "Compress") { kind in
            IntentSupport.settings(target: .original, kind: kind, quality: quality ?? 60, megabytes: limit)
        }
        return .result(value: outputs)
    }
}

struct FitFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Files Fit"
    static let description = IntentDescription(
        "Converts files so they fit where they're going, like Email (20 MB) or Discord (10 MB): the right format, size and resolution.")

    @Parameter(title: "Files", supportedContentTypes: [.image, .movie, .audio, .pdf])
    var files: [IntentFile]

    @Parameter(title: "Destination")
    var destination: DestinationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Make \(\.$files) fit for \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard let preset = DestinationStore.shared.destination(id: destination.id) else {
            throw IntentSupport.Failure("That destination is no longer available.")
        }
        let outputs = try await IntentSupport.convert(files, title: "Fit for \(preset.name)") { kind in
            preset.settings(for: kind, keepingPrivacyFrom: AppModel.shared.settings(for: kind))
        }
        return .result(value: outputs)
    }
}

struct DestinationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let defaultQuery = DestinationQuery()

    let id: String
    let name: String
    let summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }

    init(_ destination: Destination) {
        id = destination.id
        name = destination.name
        summary = destination.summary
    }
}

struct DestinationQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DestinationEntity] {
        DestinationStore.shared.destinations.filter { identifiers.contains($0.id) }.map(DestinationEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [DestinationEntity] {
        DestinationStore.shared.destinations.map(DestinationEntity.init)
    }
}

struct MorphShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CompressFilesIntent(), phrases: ["Compress files with \(.applicationName)"],
                    shortTitle: "Compress Files", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: FitFilesIntent(), phrases: ["Make files fit with \(.applicationName)"],
                    shortTitle: "Make Files Fit", systemImageName: "paperplane")
        AppShortcut(intent: ConvertFilesIntent(), phrases: ["Convert files with \(.applicationName)"],
                    shortTitle: "Convert Files", systemImageName: "arrow.triangle.2.circlepath")
    }
}

enum IntentSupport {
    struct Failure: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    /// Fresh settings for `target` (so leftover Pro options don't leak in), keeping privacy choices.
    static func settings(target: OutputFormat, kind: MediaKind, quality: Int?, megabytes: Double?) -> ConversionSettings {
        let base = AppModel.shared.settings(for: kind)
        var settings = ConversionSettings(target: target)
        settings.image.metadata = base.image.metadata
        settings.video.removeLocation = base.video.removeLocation
        settings.video.stripMetadata = base.video.stripMetadata
        settings.audio.removeLocation = base.audio.removeLocation
        settings.audio.stripMetadata = base.audio.stripMetadata
        let limit = megabytes.map { Int64(max(0.05, $0) * 1_000_000) }
        let q = quality.map { Double(max(0, min(100, $0))) / 100 }
        switch ConversionSettings.sliderDomain(target: target, kind: kind) {
        case .image:
            if let q { settings.image.quality = q }
            settings.image.sizeLimit = limit
        case .video:
            if let q { settings.video.quality = q }
            settings.video.sizeLimit = limit
        case .audio:
            if let q { settings.audio.quality = q }
            settings.audio.sizeLimit = limit
        }
        return settings
    }

    static func convert(_ files: [IntentFile], title: String,
                        settingsFor: @escaping (MediaKind) -> ConversionSettings?) async throws -> [IntentFile] {
        AppDelegate.noteBackgroundRequest()
        let urls = try files.map(localURL)
        do {
            let outputs = try await AppModel.shared.convertInBackground(urls: urls, title: title,
                                                                        forceNextToOriginals: true,
                                                                        settingsFor: settingsFor)
            return outputs.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent,
                                            type: UTType(filenameExtension: $0.pathExtension)) }
        } catch {
            throw Failure(FriendlyErrors.explain(error).message)
        }
    }

    /// Files passed as data (e.g. from Photos) are written to a temporary folder first.
    static func localURL(_ file: IntentFile) throws -> URL {
        if let url = file.fileURL {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Morph Shortcuts/\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: file.filename.isEmpty ? "File" : file.filename)
        try file.data.write(to: url)
        return url
    }
}
