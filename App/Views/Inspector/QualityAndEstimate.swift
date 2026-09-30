import MorphKit
import SwiftUI

/// Which option struct a group's quality slider / size limit edits.
extension AppModel {
    func sliderDomain(for kind: MediaKind) -> ConversionSettings.SliderDomain {
        ConversionSettings.sliderDomain(target: settings(for: kind).target, kind: kind)
    }

    func quality(for kind: MediaKind) -> Double {
        let current = settings(for: kind)
        return switch sliderDomain(for: kind) {
        case .image: current.image.quality
        case .video: current.video.quality
        case .audio: current.audio.quality
        }
    }

    func setQuality(_ value: Double, for kind: MediaKind) {
        let domain = sliderDomain(for: kind)
        update(kind) { settings in
            switch domain {
            case .image: settings.image.quality = value
            case .video: settings.video.quality = value
            case .audio: settings.audio.quality = value
            }
        }
    }

    func sizeLimit(for kind: MediaKind) -> Int64? {
        let current = settings(for: kind)
        return switch sliderDomain(for: kind) {
        case .image: current.image.sizeLimit
        case .video: current.video.sizeLimit
        case .audio: current.audio.sizeLimit
        }
    }

    func setSizeLimit(_ value: Int64?, for kind: MediaKind) {
        let domain = sliderDomain(for: kind)
        update(kind) { settings in
            switch domain {
            case .image: settings.image.sizeLimit = value
            case .video: settings.video.sizeLimit = value
            case .audio: settings.audio.sizeLimit = value
            }
        }
    }
}

struct QualitySection: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.settings(for: kind)
        let target = current.target
        let effectiveTarget = target == .original ? originalEquivalent : target
        Section {
            if effectiveTarget.usesQualitySlider {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text(qualityLabel(current: current, target: effectiveTarget))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Slider(value: Binding(get: { model.quality(for: kind) },
                                          set: { model.setQuality($0, for: kind) }),
                           in: 0...1) {
                        Text("Quality")
                    } minimumValueLabel: {
                        Text("Smallest").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Best").font(.caption).foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                    if let hint = hint(current: current, target: effectiveTarget) {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let note = effectiveTarget.qualityNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// For "Original format", show the slider as long as any file can use it.
    private var originalEquivalent: OutputFormat {
        switch kind {
        case .video:
            return .mp4H264
        case .audio:
            return .mp3
        default:
            let formats = model.entries(of: kind).map(\.item.format)
            if formats.allSatisfy({ [.tiff, .bmp].contains($0) }) { return .tiff }
            return .jpeg
        }
    }

    private func qualityLabel(current: ConversionSettings, target: OutputFormat) -> String {
        let q = model.quality(for: kind)
        if target == .movProRes {
            return (current.video.proresProfile ?? ProResProfile.forQuality(q)).displayName
        }
        if target == .png && q >= 0.98 { return "Lossless" }
        return "\(Int((q * 100).rounded()))"
    }

    private func hint(current: ConversionSettings, target: OutputFormat) -> String? {
        let q = model.quality(for: kind)
        if kind == .pdf && current.target == .original {
            var (jpeg, dpi) = PDFCompressor.parameters(quality: q)
            if let fixed = current.image.pdfImageDPI { dpi = fixed }
            return "Images inside are saved at \(dpi) dpi, JPEG quality \(Int((jpeg * 100).rounded())). Text and drawings stay sharp."
        }
        switch target {
        case .png:
            return q >= 0.98 ? "Lossless, with maximum compression." : "Fewer colors for a much smaller file (lossy palette)."
        case .gif, .gifAnimated:
            return "Lower quality uses fewer colors, frames and pixels."
        case .webpAnimated:
            return "Lower quality uses fewer frames and pixels."
        case _ where target.isVideoTarget && current.video.rateControl != .automatic:
            return "Pro rate control is active — this slider sets audio quality and fallbacks."
        default:
            return nil
        }
    }
}

// MARK: - Estimate

struct EstimateCard: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.totals(for: kind)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now").font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.bytes(totals.originalBytes))
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(totals.isApproximate ? "Estimated" : "Exact").font(.caption).foregroundStyle(.secondary)
                    Text(totals.hasEstimate ? (totals.isApproximate ? "≈ " : "") + Formatters.bytes(totals.estimatedBytes) : "—")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                if totals.hasEstimate {
                    ChangeBadge(original: totals.originalBytes, new: totals.estimatedBytes)
                }
            }
            .animation(.snappy, value: totals.estimatedBytes)

            SizeBar(original: totals.originalBytes, estimate: totals.hasEstimate ? totals.estimatedBytes : nil)

            HStack {
                if totals.isPending {
                    ProgressView().controlSize(.small)
                    Text("Calculating…").font(.caption).foregroundStyle(.secondary)
                } else if totals.count > 1 {
                    Text("For \(totals.count) \(kind.displayName.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let entry = previewCandidate {
                    Button {
                        NotificationCenter.default.post(name: .morphCompare, object: entry.id)
                    } label: {
                        Label("Compare", systemImage: "square.split.2x1")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Compare the original and the converted image side by side")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension Notification.Name {
    static let morphCompare = Notification.Name("MorphCompare")
}

extension EstimateCard {
    /// The selected (or first) image that can be previewed.
    var previewCandidate: FileEntry? {
        let list = model.entries(of: kind).filter { $0.isReady && FileListView.canCompare($0, model: model) }
        return list.first { model.selection.contains($0.id) } ?? list.first
    }
}

struct ChangeBadge: View {
    let original: Int64
    let new: Int64

    var body: some View {
        let smaller = new <= original
        Text(Formatters.change(from: original, to: new))
            .font(.callout.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(smaller ? Color.green : Color.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint((smaller ? Color.green : Color.orange).opacity(0.18)), in: .capsule)
    }
}

/// Two bars comparing the original and the estimated size.
struct SizeBar: View {
    let original: Int64
    let estimate: Int64?

    var body: some View {
        GeometryReader { proxy in
            let maximum = Double(max(original, estimate ?? 0, 1))
            VStack(alignment: .leading, spacing: 4) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: proxy.size.width * Double(original) / maximum, height: 6)
                Capsule()
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, proxy.size.width * Double(estimate ?? 0) / maximum), height: 6)
                    .opacity(estimate == nil ? 0 : 1)
            }
            .animation(.spring(duration: 0.4), value: estimate)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Size limit

struct SizeLimitSection: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model
    @State private var text = ""

    private let presets: [Int64] = [1, 2, 5, 10, 25, 50].map { $0 * 1_000_000 }

    var body: some View {
        let limit = model.sizeLimit(for: kind)
        let target = model.settings(for: kind).target
        if target != .pdfCombined && target.category != .frame {
            Section {
                Toggle(isOn: Binding(get: { limit != nil },
                                     set: { model.setSizeLimit($0 ? (limit ?? defaultLimit) : nil, for: kind) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Limit file size")
                        Text("For upload limits. Quality, then resolution, is lowered until each file fits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let limit {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { value in
                            Button(Formatters.bytes(value)) { model.setSizeLimit(value, for: kind) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .tint(value == limit ? .accentColor : nil)
                        }
                    }
                    HStack {
                        Text("Maximum per file")
                        Spacer()
                        // In a Form a TextField's title shows as a label, so hide it (it read "MB 10 MB").
                        TextField("Maximum size in megabytes", text: $text, prompt: Text("MB"))
                            .labelsHidden()
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { commit() }
                        Text("MB").foregroundStyle(.secondary)
                    }
                    .onAppear { text = format(limit) }
                    .onChange(of: limit) { _, new in text = format(new) }
                }
            }
        }
    }

    private var defaultLimit: Int64 {
        kind == .video ? 25_000_000 : kind == .audio ? 10_000_000 : 2_000_000
    }

    private func format(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb == mb.rounded() ? String(Int(mb)) : String(format: "%.2f", mb)
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let mb = Double(normalized), mb > 0.01 {
            model.setSizeLimit(Int64(mb * 1_000_000), for: kind)
        }
    }
}
