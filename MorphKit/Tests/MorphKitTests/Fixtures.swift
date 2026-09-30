import CoreGraphics
import Foundation
import ImageIO
@testable import MorphKit

/// Generates test media on the fly (no binary fixtures in the repo).
enum Fixtures {
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MorphKitTests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var repoRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Bundled static build if present, else Homebrew.
    static var tools: FFmpegTools? {
        FFmpegTools.locate(bundle: .main, extraDirectories: [repoRoot.appending(path: "Vendor/ffmpeg/bin")])
    }

    /// A colorful gradient with a soft transparent circle.
    static func gradientImage(width: Int = 640, height: Int = 480, alpha: Bool = true) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        let colors = [CGColor(red: 0.95, green: 0.3, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for i in 0..<40 {
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7, green: Double(i % 5) / 5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: (i * 37) % width, y: (i * 53) % height, width: 24, height: 24))
        }
        if alpha {
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
        return ctx.makeImage()!
    }

    static func writeImage(_ image: CGImage, name: String, type: String, properties: [CFString: Any] = [:]) -> URL {
        let url = directory.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func pngWithAlpha() -> URL {
        writeImage(gradientImage(), name: "alpha.png", type: "public.png")
    }

    static func jpegWithGPS() -> URL {
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:30 12:00:00"],
            kCGImagePropertyOrientation: 6,
        ]
        return writeImage(gradientImage(alpha: false), name: "photo.jpg", type: "public.jpeg", properties: props)
    }

    static func heic() -> URL {
        writeImage(gradientImage(width: 1200, height: 800, alpha: false), name: "photo.heic", type: "public.heic",
                   properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    static func animatedGIF(frames: Int = 6) -> URL {
        let url = directory.appending(path: "anim.gif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            let img = gradientImage(width: 120 + i, height: 90, alpha: false)
            CGImageDestinationAddImage(dest, cropped(img, width: 120, height: 90),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        return url
    }

    static func cropped(_ image: CGImage, width: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))!
    }

    static func svg() -> URL {
        let url = directory.appending(path: "logo.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
          <defs><linearGradient id="g"><stop offset="0" stop-color="#ff5f6d"/><stop offset="1" stop-color="#ffc371"/></linearGradient></defs>
          <rect width="200" height="100" rx="16" fill="url(#g)"/>
          <text x="100" y="62" font-family="Helvetica" font-size="36" text-anchor="middle" fill="#fff">Morph</text>
        </svg>
        """
        try? svg.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func twoPagePDF() -> URL {
        let url = directory.appending(path: "doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: page == 0 ? 0.9 : 0.2, green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 72, y: 72, width: 468, height: 648))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    static func item(_ url: URL) async throws -> MediaItem {
        var item = try #require(MediaProbe.item(for: url))
        item.info = try await MediaProbe.info(for: item, tools: tools)
        return item
    }

    /// Generates a test video with ffmpeg (lavfi testsrc2 + sine).
    static func video(name: String = "clip.mp4", seconds: Double = 3, size: String = "640x360", extra: [String] = [])
        async throws -> URL? {
        guard let tools else { return nil }
        let url = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var args = ["-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30:duration=\(seconds)",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"]
        args += extra
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path]
        let output = try await ChildProcess.run(tools.ffmpeg, arguments: args)
        return output.status == 0 ? url : nil
    }
}

import Testing

extension Fixtures {
    static func decodedSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }
}
