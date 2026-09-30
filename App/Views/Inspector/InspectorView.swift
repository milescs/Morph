import MorphKit
import SwiftUI

/// Conversion settings for one kind of file (tabs when several kinds are in the list).
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var model = model
        let kind = model.kindsPresent.contains(model.selectedKind) ? model.selectedKind : (model.kindsPresent.first ?? .image)
        Form {
            DestinationSection()

            if model.kindsPresent.count > 1 {
                Section {
                    Picker("Settings for", selection: $model.selectedKind) {
                        ForEach(model.kindsPresent, id: \.self) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section {
                FormatGrid(kind: kind)
            } header: {
                HStack {
                    Text("Convert \(kind == .pdf ? "PDFs" : kind.displayName.lowercased()) to")
                    Spacer()
                    PresetsMenu(kind: kind)
                }
            }

            QualitySection(kind: kind)

            Section("Estimated size") {
                EstimateCard(kind: kind)
            }

            SizeLimitSection(kind: kind)

            PrivacySection(kind: kind)

            if settings.proMode {
                ProOptionsView(kind: kind)
            } else {
                Section {
                    Button {
                        withAnimation { settings.proMode = true }
                    } label: {
                        Label("Show Pro options", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.link)
                } footer: {
                    Text(proHint(for: kind))
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.phase == .converting)
        .animation(.smooth(duration: 0.25), value: settings.proMode)
        .animation(.smooth(duration: 0.25), value: model.settings(for: kind).target)
    }

    private func proHint(for kind: MediaKind) -> String {
        switch kind {
        case .image, .pdf: "Resize, color profile, metadata, lossless and more."
        case .video: "Container, encoder, resolution, frame rate, bitrate, audio, trim and more."
        case .audio: "Bitrate, sample rate, channels, loudness and more."
        }
    }
}

// MARK: - Format grid

struct FormatGrid: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model
    @Namespace private var glass

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: 8)]

    var body: some View {
        let targets = model.targets(for: kind)
        let selected = model.settings(for: kind).target
        let recommended = FormatRegistry.recommendedTarget(for: kind, available: targets)
        let groups = OutputCategory.allCases.compactMap { category -> (OutputCategory, [OutputFormat])? in
            let items = targets.filter { $0.category == category && $0 != recommended }
            return items.isEmpty ? nil : (category, items)
        }
        VStack(alignment: .leading, spacing: 12) {
            if targets.isEmpty {
                Label("Install FFmpeg to convert \(kind.displayName.lowercased()).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    if let recommended {
                        RecommendedTile(format: recommended, reason: FormatRegistry.recommendationReason(for: kind),
                                        isSelected: recommended == selected) {
                            withAnimation(.snappy(duration: 0.25)) {
                                model.update(kind) { $0.target = recommended }
                            }
                        }
                    }
                    ForEach(groups, id: \.0) { category, formats in
                        VStack(alignment: .leading, spacing: 6) {
                            if groups.count > 1 {
                                Text(category.displayName.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(0.6)
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                                ForEach(formats) { format in
                                    FormatTile(format: format, isSelected: format == selected) {
                                        withAnimation(.snappy(duration: 0.25)) {
                                            model.update(kind) { $0.target = format }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if let compatibility = selected.compatibility {
                Label {
                    Text("\(Text(compatibility.title).fontWeight(.semibold)). \(compatibility.explanation)")
                } icon: {
                    Image(systemName: compatibility.symbolName)
                        .foregroundStyle(compatibility == .everywhere ? Color.green : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let badges = Optional(selected.badges.filter { $0 != .compatible }), !badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Label(badge.title, systemImage: symbol(for: badge))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if selected == .auto {
                Label("JPEG, PNG and GIF files keep their format. Others become JPEG, or PNG when they have transparency.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(warnings(kind: kind, target: selected), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func symbol(for badge: FormatBadge) -> String {
        switch badge {
        case .smallest: "arrow.down.right.and.arrow.up.left"
        case .compatible: "checkmark.seal"
        case .lossless: "diamond"
        case .transparency: "checkerboard.rectangle"
        case .animated: "play.square.stack"
        case .hdr: "sun.max"
        case .editing: "scissors"
        case .web: "globe"
        }
    }

    private func warnings(kind: MediaKind, target: OutputFormat) -> [String] {
        let items = model.entries(of: kind).map(\.item)
        var result: [String] = []
        let noAlpha: Set<OutputFormat> = [.jpeg, .bmp]
        if noAlpha.contains(target), items.contains(where: { $0.info?.image?.hasAlpha == true }) {
            result.append("Transparency will be filled with the background color.")
        }
        let stillOnly: Set<OutputFormat> = [.jpeg, .heic, .avif, .tiff, .bmp, .jp2, .ico, .icns, .pdf, .svgTrace]
        if stillOnly.contains(target), items.contains(where: { $0.isAnimatedImage }) {
            result.append("Animated images keep only their first frame.")
        }
        let sdrTargets: Set<OutputFormat> = [.mp4H264, .movH264, .gifAnimated, .webpAnimated, .frameJPEG, .framePNG]
        if sdrTargets.contains(target), items.contains(where: { $0.info?.media?.isHDR == true }),
           model.settings(for: kind).video.hdr == .automatic {
            result.append("HDR video will be converted to SDR.")
        }
        if target == .svgTrace {
            result.append("Tracing works best on logos and illustrations, not photos.")
        }
        if target.isAnimatedTarget, model.settings(for: kind).video.trim == nil,
           items.contains(where: { ($0.info?.media?.duration ?? 0) > 30 }) {
            result.append("Animations of long videos are huge and slow to make. Trim the clip in Pro mode first.")
        }
        return result
    }
}

struct FormatTile: View {
    let format: OutputFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(format.displayName)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                Text(format.detail)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .shadow(color: .accentColor.opacity(0.35), radius: 6, y: 2)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let compatibility = format.compatibility, compatibility != .everywhere {
                    Image(systemName: compatibility.symbolName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                        .padding(5)
                }
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .identity : .regular.interactive(), in: .rect(cornerRadius: 12, style: .continuous))
        .help(format.compatibility.map { "\($0.title). \($0.explanation)" } ?? format.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(format.displayName), \(format.detail)\(format.compatibility.map { ", \($0.title)" } ?? "")")
    }
}

/// The one format Morph suggests for this kind of file, shown first and wide.
struct RecommendedTile: View {
    let format: OutputFormat
    let reason: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("RECOMMENDED")
                            .font(.caption2.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tint))
                        if let compatibility = format.compatibility {
                            Image(systemName: compatibility.symbolName)
                                .font(.caption2)
                                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.green))
                        }
                    }
                    Text(title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .shadow(color: .accentColor.opacity(0.35), radius: 6, y: 2)
                }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .identity : .regular.interactive(), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("Recommended: \(title). \(reason)")
    }

    private var title: String {
        switch format {
        case .original: "Compress PDF"
        case .auto: "Auto: best format for each file"
        default: "\(format.displayName)\(format.isVideoTarget ? " (\(format.detail))" : "")"
        }
    }
}

// MARK: - Destinations

/// "Fit for Email / Discord / …": one tap sets format, size limit and resolution for every kind.
struct DestinationSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let destinations = DestinationStore.shared.destinations
        let active = model.activeDestination
        if !destinations.isEmpty {
            Section {
                FlowLayout(spacing: 6, alignment: .leading) {
                    ForEach(destinations) { destination in
                        DestinationChip(destination: destination, isSelected: active?.id == destination.id) {
                            withAnimation(.snappy(duration: 0.25)) {
                                model.apply(destination: active?.id == destination.id ? nil : destination)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                Text(active?.summary ?? "Pick where the files are going. Morph sets the format, size and resolution that work there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Fit for")
            }
        }
    }
}

struct DestinationChip: View {
    let destination: Destination
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: destination.symbol)
                    .font(.caption)
                Text(destination.name)
                    .font(.callout.weight(.medium))
                if !destination.badge.isEmpty {
                    Text(destination.badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected { Capsule().fill(Color.accentColor.gradient) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .identity : .regular.interactive(), in: .capsule)
        .help(destination.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Privacy

/// "Remove location": on by default, visible without Pro mode.
struct PrivacySection: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.settings(for: kind)
        if kind == .image || kind == .video, current.target.category != .frame, !current.target.isAnimatedTarget {
            Section {
                Toggle(isOn: removesLocation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Remove location", systemImage: "location.slash")
                        Text("Photos and videos can reveal where they were taken. Other details, like the date, are kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var removesLocation: Binding<Bool> {
        Binding {
            let current = model.settings(for: kind)
            return switch model.sliderDomain(for: kind) {
            case .image: current.image.metadata != .keep
            case .video: current.video.removeLocation || current.video.stripMetadata
            case .audio: current.audio.removeLocation || current.audio.stripMetadata
            }
        } set: { on in
            let domain = model.sliderDomain(for: kind)
            model.update(kind) { settings in
                switch domain {
                case .image:
                    settings.image.metadata = on ? (settings.image.metadata == .removeAll ? .removeAll : .removeLocation) : .keep
                case .video:
                    settings.video.removeLocation = on
                    if !on { settings.video.stripMetadata = false }
                case .audio:
                    settings.audio.removeLocation = on
                    if !on { settings.audio.stripMetadata = false }
                }
            }
        }
    }
}

// MARK: - Presets

struct PresetsMenu: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let presets = PresetStore.shared.presets(for: kind)
        Menu {
            ForEach(presets) { preset in
                Button(preset.name, systemImage: preset.symbol) { model.apply(preset: preset) }
            }
            Divider()
            Button("Save Current Settings as Preset…") { naming = true }
            let custom = presets.filter { !$0.isBuiltIn }
            if !custom.isEmpty {
                Menu("Delete Preset") {
                    ForEach(custom) { preset in
                        Button(preset.name) { PresetStore.shared.delete(preset) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "star")
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    PresetStore.shared.save(name: trimmed, kind: kind, settings: model.settings(for: kind))
                }
                name = ""
            }
            Button("Cancel", role: .cancel) { name = "" }
        } message: {
            Text("Saves the current \(kind.singularName.lowercased()) settings so you can reuse them.")
        }
    }
}
