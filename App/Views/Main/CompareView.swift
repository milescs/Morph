import ImageIO
import MorphKit
import SwiftUI

/// Side-by-side (split slider) preview of an image before and after conversion.
struct CompareView: View {
    let entry: FileEntry
    let settings: ConversionSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var original: CGImage?
    @State private var converted: CGImage?
    @State private var convertedBytes: Int64?
    @State private var note: String?
    @State private var error: String?
    @State private var split: CGFloat = 0.5
    @State private var zoomed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black.opacity(0.85)
                if let original, let converted {
                    GeometryReader { proxy in
                        let size = fittedSize(for: original, in: proxy.size)
                        ZStack {
                            image(original, size: size)
                            image(converted, size: size)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: size.width * (1 - split))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            divider(height: size.height)
                                .offset(x: size.width * (split - 0.5))
                        }
                        .frame(width: size.width, height: size.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let originX = (proxy.size.width - size.width) / 2
                            split = min(1, max(0, (value.location.x - originX) / size.width))
                        })
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    ProgressView("Encoding preview…").controlSize(.large).tint(.white)
                }
            }
            .overlay(alignment: .topLeading) { label("Original · \(Formatters.bytes(entry.item.fileSize))") }
            .overlay(alignment: .topTrailing) {
                if let convertedBytes {
                    label("\(outputName) · \(Formatters.bytes(convertedBytes))")
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 600, idealHeight: 760)
        .task { await load() }
    }

    private var outputName: String {
        FormatRegistry.outputExtension(for: entry.item, settings: settings, capabilities: model.capabilities).uppercased()
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.name).font(.headline)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Drag across the image to compare. Shown at 100% when zoomed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let convertedBytes {
                ChangeBadge(original: entry.item.fileSize, new: convertedBytes)
            }
            Toggle(isOn: $zoomed) { Label("Actual Size", systemImage: "1.magnifyingglass") }
                .toggleStyle(.button)
                .help("Show pixels at 100%")
            Button("Done") { dismiss() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func image(_ cgImage: CGImage, size: CGSize) -> some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .interpolation(zoomed ? .none : .high)
            .frame(width: size.width, height: size.height)
    }

    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2, height: height)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(.white, in: .circle)
                .shadow(radius: 4)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
    }

    private func fittedSize(for image: CGImage, in container: CGSize) -> CGSize {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        if zoomed {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return CGSize(width: min(container.width, w / scale), height: min(container.height, h / scale))
        }
        let scale = min(container.width / w, container.height / h, 1)
        return CGSize(width: w * scale, height: h * scale)
    }

    private func load() async {
        let item = entry.item
        let settings = self.settings
        let cache = model.cache
        let key = SizeEstimator.cacheKey(item: item, settings: settings)
        do {
            let result: ImageEncodeResult
            if let cached = await cache.image(for: key) {
                result = cached
            } else {
                result = try await BlockingWork.run {
                    try ImageEngine.convert(item: item, target: settings.target, options: settings.image)
                }
                await cache.store(result, for: key)
            }
            let decoded = try await BlockingWork.run { () -> (CGImage, CGImage) in
                let before = try Self.decode(url: item.url, item: item, options: settings.image)
                guard let source = CGImageSourceCreateWithData(result.data as CFData, nil),
                      let after = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: max(before.width, before.height),
                      ] as CFDictionary) else {
                    throw ImageEngineError("This format can't be previewed.")
                }
                return (before, after)
            }
            original = decoded.0
            converted = decoded.1
            convertedBytes = result.byteCount
            note = result.note
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The original, decoded at the output's pixel size so both halves line up.
    nonisolated static func decode(url: URL, item: MediaItem, options: ImageOptions) throws -> CGImage {
        if item.format == .svg || item.format == .pdf {
            // Rendered formats: show the converted pixels' source at the same size via ImageEngine's PNG.
            var lossless = options
            lossless.quality = 1
            lossless.sizeLimit = nil
            let png = try ImageEngine.convert(item: item, target: .png, options: lossless)
            guard let source = CGImageSourceCreateWithData(png.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ImageEngineError("Couldn't render the original.")
            }
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageEngineError("Couldn't read the original.")
        }
        let info = try ImageProbe.probe(source: source)
        let size = options.resize.apply(to: CGSizeInt(width: info.width, height: info.height),
                                        allowUpscale: options.allowUpscale)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size.longestSide,
        ] as CFDictionary) else {
            throw ImageEngineError("Couldn't read the original.")
        }
        return image
    }
}
