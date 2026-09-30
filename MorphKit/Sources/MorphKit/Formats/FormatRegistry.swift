import Foundation

/// Which outputs make sense for a group of inputs, given what this Mac's FFmpeg supports.
public enum FormatRegistry {
    /// The target new users start with, and the one shown first as "Recommended".
    public static func defaultTarget(for kind: MediaKind) -> OutputFormat {
        switch kind {
        case .image: .auto
        case .video: .mp4H264
        case .audio: .mp3
        case .pdf: .original
        }
    }

    /// The recommended tile for a group, if it's available for these files.
    public static func recommendedTarget(for kind: MediaKind, available: [OutputFormat]) -> OutputFormat? {
        let preferred = defaultTarget(for: kind)
        return available.contains(preferred) ? preferred : nil
    }

    /// One line explaining the recommended tile.
    public static func recommendationReason(for kind: MediaKind) -> String {
        switch kind {
        case .image: "JPEG for photos, PNG for graphics and transparency, GIF for animations."
        case .video: "MP4 with H.264 plays on every phone, computer and website."
        case .audio: "MP3 plays everywhere."
        case .pdf: "Shrinks the images inside. Text, links and forms stay as they are."
        }
    }

    /// Output tiles for `items` (all of the same kind), in display order.
    public static func targets(for kind: MediaKind, items: [MediaItem],
                               capabilities: FFmpegCapabilities?) -> [OutputFormat] {
        let hasFFmpeg = capabilities != nil
        func encoder(_ name: String) -> Bool { capabilities?.hasEncoder(name) ?? false }

        switch kind {
        case .image:
            var list: [OutputFormat] = []
            let canKeep = items.contains { ImageEngine.outputFormat(for: .original, source: $0.format) != nil }
            list.append(.auto)
            if canKeep { list.append(.original) }
            list += [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif, .bmp, .jp2, .ico, .icns, .pdf]
            if items.count > 1 { list.append(.pdfCombined) }
            if !items.allSatisfy({ $0.format == .svg }) { list.append(.svgTrace) }
            // Animated images (GIF/APNG/WebP) can become real videos.
            let allAnimated = !items.isEmpty && items.allSatisfy { $0.isAnimatedImage }
            if allAnimated && hasFFmpeg {
                let animatedWebPReadable = (capabilities?.majorVersion ?? 0) >= 9
                if items.allSatisfy({ $0.format != .webp }) || animatedWebPReadable {
                    list += [.mp4H264, .mp4HEVC]
                    if encoder("libvpx-vp9") { list.append(.webmVP9) }
                }
            }
            return list

        case .pdf:
            var list: [OutputFormat] = [.original, .png, .jpeg, .heic, .webp, .avif, .tiff]
            if items.count > 1 { list.append(.pdfCombined) }
            return list

        case .video:
            guard hasFFmpeg else { return [] }
            var list: [OutputFormat] = [.original, .mp4H264, .mp4HEVC]
            if encoder("libsvtav1") { list.append(.mp4AV1) }
            list += [.movH264, .movHEVC, .movProRes]
            if encoder("libvpx-vp9") { list.append(.webmVP9) }
            if encoder("libsvtav1") { list.append(.webmAV1) }
            list.append(.mkvHEVC)
            list.append(.gifAnimated)
            if encoder("libwebp_anim") { list.append(.webpAnimated) }
            let anyAudio = items.contains { $0.info?.media?.audio != nil } || items.contains { $0.info == nil }
            if anyAudio {
                if encoder("libmp3lame") { list.append(.mp3) }
                list += [.m4aAAC, .wav, .flac]
            }
            list += [.frameJPEG, .framePNG]
            return list

        case .audio:
            guard hasFFmpeg else { return [] }
            var list: [OutputFormat] = [.original]
            if encoder("libmp3lame") { list.append(.mp3) }
            list += [.m4aAAC, .m4aALAC, .wav, .aiff, .flac]
            if encoder("libopus") { list.append(.opus) }
            return list
        }
    }

    /// The file extension an item will get for `settings` (used for naming before conversion).
    public static func outputExtension(for item: MediaItem, settings: ConversionSettings,
                                       capabilities: FFmpegCapabilities?) -> String {
        switch ConversionPipeline.route(for: item, target: settings.target) {
        case .combinePDF:
            return "pdf"
        case .pdfCompress:
            return item.url.pathExtension.isEmpty ? "pdf" : item.url.pathExtension
        case .image:
            if settings.target == .original { return item.url.pathExtension.isEmpty ? item.format.preferredExtension : item.url.pathExtension }
            if settings.target == .auto {
                let format = ImageEngine.autoFormat(for: item)
                if format == item.format && !item.url.pathExtension.isEmpty { return item.url.pathExtension }
                return format.preferredExtension
            }
            return settings.target.fileExtension
        case .ffmpeg:
            if let info = item.info?.media,
               let plan = try? MediaPlanner.plan(item: item, info: info, settings: settings, capabilities: capabilities) {
                return plan.fileExtension
            }
            return settings.target == .original ? item.url.pathExtension : settings.target.fileExtension
        }
    }
}
