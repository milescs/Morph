import CoreGraphics
import Foundation
import ImageIO

/// Core Graphics helpers: resizing, color conversion, flattening, PDF and SVG rasterization.
enum ImageRendering {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// The RGB color space to draw into for `image` (its own if RGB, else sRGB).
    static func workingSpace(for image: CGImage, option: ColorProfileOption) -> CGColorSpace {
        switch option {
        case .sRGB: return sRGB
        case .displayP3: return displayP3
        case .keep:
            if let space = image.colorSpace, space.model == .rgb { return space }
            return sRGB
        }
    }

    /// Draws `image` into a new bitmap.
    /// - Parameters:
    ///   - size: output pixel size; with `fill`, the image is scaled to cover it and center-cropped.
    ///   - background: when set, the result is opaque (transparency flattened onto this color).
    static func redraw(_ image: CGImage, size: CGSizeInt, colorSpace: CGColorSpace, background: RGBColor?,
                       fill: Bool = false, highBitDepth: Bool = false) throws -> CGImage {
        let deep = highBitDepth && image.bitsPerComponent > 8
        let bitsPerComponent = deep ? 16 : 8
        let alphaInfo: CGImageAlphaInfo = background != nil ? .noneSkipLast : .premultipliedLast
        let byteOrder: CGBitmapInfo = deep ? .byteOrder16Little : .byteOrder32Big
        let bitmapInfo = alphaInfo.rawValue | byteOrder.rawValue
        guard let context = CGContext(data: nil, width: size.width, height: size.height,
                                      bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            throw ImageEngineError("Not enough memory to process this image.")
        }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if let background {
            context.setFillColor(CGColor(colorSpace: sRGB, components: [background.red, background.green, background.blue, 1])!)
            context.fill(bounds)
        }
        var rect = bounds
        if fill {
            let scale = max(CGFloat(size.width) / CGFloat(image.width), CGFloat(size.height) / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            rect = CGRect(x: (CGFloat(size.width) - w) / 2, y: (CGFloat(size.height) - h) / 2, width: w, height: h)
        }
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ImageEngineError("Couldn't create the image.") }
        return result
    }

    static func resized(_ image: CGImage, to size: CGSizeInt, fill: Bool = false) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb || $0.model == .monochrome ? $0 : nil } ?? sRGB
        let rgbSpace = space.model == .rgb ? space : sRGB
        return try redraw(image, size: size, colorSpace: rgbSpace, background: nil, fill: fill,
                          highBitDepth: image.bitsPerComponent > 8)
    }

    /// Scales an image to fit in a square canvas (transparent padding), for icons.
    static func squareIcon(_ image: CGImage, side: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageEngineError("Not enough memory to create the icon.")
        }
        context.interpolationQuality = .high
        let scale = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        guard let result = context.makeImage() else { throw ImageEngineError("Couldn't create the icon.") }
        return result
    }

    // MARK: PDF

    /// Renders one PDF page (1-based) at `dpi`. Transparent pages get `background` unless nil.
    static func renderPDFPage(url: URL, page pageNumber: Int, dpi: Double, background: RGBColor?) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL) else { throw ImageEngineError("This PDF can't be opened.") }
        guard let page = document.page(at: pageNumber) else {
            throw ImageEngineError("Page \(pageNumber) doesn't exist.")
        }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pointSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let width = max(1, Int((pointSize.width * scale).rounded()))
        let height = max(1, Int((pointSize.height * scale).rounded()))
        guard width * height <= 400_000_000 else { throw ImageEngineError("The page is too large at this resolution.") }

        let alpha: CGImageAlphaInfo = background == nil ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: alpha.rawValue) else {
            throw ImageEngineError("Not enough memory to render this page.")
        }
        if let background {
            context.setFillColor(CGColor(colorSpace: sRGB, components: [background.red, background.green, background.blue, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.setRenderingIntent(.defaultIntent)
        context.scaleBy(x: scale, y: scale)
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pointSize), rotate: 0,
                                                 preserveAspectRatio: true)
        context.concatenate(transform)
        context.clip(to: box)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ImageEngineError("Couldn't render the page.") }
        return image
    }

    // MARK: SVG

    /// Renders SVG data at `size` (resvg; falls back to Apple's CoreSVG through ImageIO-free NSImage-less path).
    static func renderSVG(data: Data, size: CGSizeInt) throws -> CGImage {
        try RustCodecs.renderSVG(data: data, width: size.width, height: size.height)
    }
}
