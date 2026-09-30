import Foundation
import PDFKit
import Quartz

/// Shrinks PDFs by downsampling and re-compressing the images inside them. Text, vector graphics,
/// links, form fields and the outline are kept. Uses the Quartz filter machinery behind Preview's
/// "Reduce File Size", with settings driven by the quality slider and size limit.
public enum PDFCompressor {
    /// JPEG quality and image resolution for a 0…1 quality slider.
    public static func parameters(quality: Double) -> (jpegQuality: Double, dpi: Int) {
        let q = max(0, min(1, quality))
        let dpi = switch q {
        case 0.9...: 300
        case 0.7...: 200
        case 0.45...: 150
        case 0.25...: 110
        default: 72
        }
        return (0.3 + 0.6 * q, dpi)
    }

    public static func compress(url: URL, options: ImageOptions) throws -> ImageEncodeResult {
        guard let document = PDFDocument(url: url) else { throw ImageEngineError("This PDF can't be opened.") }
        if document.isLocked { throw ImageEngineError("This PDF is password-protected.") }
        if options.metadata == .removeAll { document.documentAttributes = [:] }
        let originalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? .max
        var (jpegQuality, dpi) = parameters(quality: options.quality)
        if let fixed = options.pdfImageDPI { dpi = max(36, fixed) }
        let first = try encode(document, jpegQuality: jpegQuality, dpi: dpi)

        guard let limit = options.sizeLimit, limit > 0 else {
            // Re-encoding already-efficient images can make a PDF bigger; never do that.
            if Int64(first.count) >= originalSize {
                return result(try Data(contentsOf: url), note: "Already compact, so it was saved unchanged")
            }
            return result(first, note: nil)
        }
        if Int64(first.count) <= limit {
            return result(first, note: nil)
        }
        if originalSize <= limit {
            return result(try Data(contentsOf: url), note: nil)
        }

        // Find the highest resolution at which the lowest quality fits, then the best quality there.
        var smallest = first
        let floorQuality = 0.1
        let resolutions = [dpi, 150, 110, 96, 72, 50].filter { $0 <= dpi }.reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for candidate in resolutions {
            try Task.checkCancellation()
            let lowest = try encode(document, jpegQuality: floorQuality, dpi: candidate)
            if lowest.count < smallest.count { smallest = lowest }
            guard Int64(lowest.count) <= limit else { continue }
            var best = lowest
            var low = floorQuality, high = jpegQuality
            for _ in 0..<5 where high - low > 0.04 {
                let mid = (low + high) / 2
                let data = try encode(document, jpegQuality: mid, dpi: candidate)
                if Int64(data.count) <= limit {
                    best = data
                    low = mid
                } else {
                    high = mid
                }
            }
            let note = candidate < dpi
                ? "Images reduced to \(candidate) dpi to fit \(Formatters.bytes(limit))"
                : "Image quality lowered to fit \(Formatters.bytes(limit))"
            return result(best, note: note)
        }
        return result(smallest, note: "Couldn't reach \(Formatters.bytes(limit)); saved the smallest version")
    }

    static func result(_ data: Data, note: String?) -> ImageEncodeResult {
        ImageEncodeResult(data: data, fileExtension: "pdf", pixelSize: CGSizeInt(width: 0, height: 0), note: note)
    }

    static func encode(_ document: PDFDocument, jpegQuality: Double, dpi: Int) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appending(path: "morph-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let filter = QuartzFilter(properties: filterProperties(jpegQuality: jpegQuality, dpi: dpi)) {
            options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
        }
        guard document.write(to: temp, withOptions: options) else {
            throw ImageEngineError("Couldn't write the compressed PDF.")
        }
        return try Data(contentsOf: temp)
    }

    /// Same structure as /System/Library/Filters/Reduce File Size.qfilter.
    static func filterProperties(jpegQuality: Double, dpi: Int) -> [String: Any] {
        [
            "Domains": ["Applications": true],
            "FilterType": 1,
            "Name": "Morph",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": max(0.05, min(1, jpegQuality)),
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": dpi,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 0,
                            "ImageSizeMin": 0,
                        ],
                    ],
                ],
            ],
        ]
    }
}
