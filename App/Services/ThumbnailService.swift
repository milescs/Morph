import AppKit
import MorphKit
import QuickLookThumbnailing

/// Thumbnails via Quick Look, falling back to an FFmpeg frame for formats Quick Look can't read.
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    var ffmpeg: FFmpegEngine?

    init() {
        cache.countLimit = 800
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func thumbnail(for item: MediaItem, side: CGFloat = 96) async -> NSImage? {
        if let hit = cache.object(forKey: item.url as NSURL) { return hit }
        if let task = inFlight[item.url] { return await task.value }
        let ffmpeg = self.ffmpeg
        let task = Task<NSImage?, Never> {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: side, height: side),
                                                       scale: scale, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                return rep.nsImage
            }
            if item.kind == .video, let ffmpeg,
               let frame = try? await ffmpeg.frameImage(url: item.url, at: min(1, (item.info?.duration ?? 2) / 2),
                                                        maxSide: Int(side * scale)) {
                return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
            return nil
        }
        inFlight[item.url] = task
        let image = await task.value
        inFlight[item.url] = nil
        if let image { cache.setObject(image, forKey: item.url as NSURL) }
        return image
    }
}
