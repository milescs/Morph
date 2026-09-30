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
                    Text("Convert \(kind.displayName.lowercased()) to")
                    Spacer()
                    PresetsMenu(kind: kind)
                }
            }

            QualitySection(kind: kind)

            Section("Estimated size") {
                EstimateCard(kind: kind)
            }

            SizeLimitSection(kind: kind)

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
        let groups = OutputCategory.allCases.compactMap { category -> (OutputCategory, [OutputFormat])? in
            let items = targets.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
        VStack(alignment: .leading, spacing: 12) {
            if targets.isEmpty {
                Label("Install FFmpeg to convert \(kind.displayName.lowercased()).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
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
            if let badges = Optional(selected.badges), !badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Label(badge.title, systemImage: symbol(for: badge))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .identity : .regular.interactive(), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(format.displayName), \(format.detail)")
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
