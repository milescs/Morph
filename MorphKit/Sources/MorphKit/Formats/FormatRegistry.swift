import Foundation

/// Which outputs make sense for a group of inputs, given what this Mac's FFmpeg supports.
public enum FormatRegistry {
    public static func defaultTarget(for kind: MediaKind) -> OutputFormat {
        switch kind {
        case .image: .jpeg
        case .video: .mp4H264
        case .audio: .mp3
        case .pdf: .png
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
            var list: [OutputFormat] = [.png, .jpeg, .heic, .webp, .avif, .tiff]
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
        case .image:
            if settings.target == .original { return item.url.pathExtension.isEmpty ? item.format.preferredExtension : item.url.pathExtension }
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
