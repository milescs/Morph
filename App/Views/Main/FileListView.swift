import MorphKit
import QuickLook
import SwiftUI

struct FileListView: View {
    @Environment(AppModel.self) private var model
    @State private var quickLookURL: URL?
    @State private var comparing: FileEntry?

    var body: some View {
        listWithMenus
            .quickLookPreview($quickLookURL, in: model.entries.map(outputOrSource))
            .sheet(item: $comparing) { entry in
                CompareView(entry: entry, settings: model.settings(for: entry.kind))
                    .environment(model)
            }
            .onReceive(NotificationCenter.default.publisher(for: .morphCompare)) { note in
                openCompare(note.object as? UUID)
            }
            .onChange(of: model.selection) { _, _ in syncSelectedKind() }
    }

    private var listWithMenus: some View {
        list
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                if let entry = entry(for: ids.first) { quickLookURL = outputOrSource(entry) }
            }
            .onDeleteCommand { model.remove(model.selection) }
            .onKeyPress(.space) { toggleQuickLook() }
    }

    private var list: some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
            if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for files…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.kindsPresent, id: \.self) { kind in
                section(for: kind)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
    }

    private func section(for kind: MediaKind) -> some View {
        Section {
            ForEach(model.entries(of: kind)) { entry in
                FileRow(entry: entry)
                    .tag(entry.id)
            }
            .onMove { source, destination in
                model.move(kind: kind, from: source, to: destination)
            }
        } header: {
            SectionHeader(kind: kind)
        }
    }

    private func entry(for id: UUID?) -> FileEntry? {
        guard let id else { return nil }
        return model.entries.first { $0.id == id }
    }

    private func toggleQuickLook() -> KeyPress.Result {
        guard let entry = entry(for: model.selection.first) else { return .ignored }
        quickLookURL = quickLookURL == nil ? outputOrSource(entry) : nil
        return .handled
    }

    private func openCompare(_ id: UUID?) {
        if let entry = entry(for: id) { comparing = entry }
    }

    private func syncSelectedKind() {
        if let entry = entry(for: model.selection.first) { model.selectedKind = entry.kind }
    }

    static func canCompare(_ entry: FileEntry, model: AppModel) -> Bool {
        let settings = model.settings(for: entry.kind)
        guard ConversionPipeline.route(for: entry.item, target: settings.target) == .image,
              let format = settings.target == .original ? entry.item.format : settings.target.imageFormat else { return false }
        return ![.pdf, .svg, .ico, .icns].contains(format) && settings.target != .pdfCombined
    }

    private func outputOrSource(_ entry: FileEntry) -> URL {
        if case .done(let url?, _, _) = entry.job { return url }
        return entry.item.url
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let selected = model.entries.filter { ids.contains($0.id) }
        Button("Quick Look", systemImage: "eye") {
            if let first = selected.first { quickLookURL = outputOrSource(first) }
        }
        .disabled(selected.isEmpty)
        if selected.count == 1, let entry = selected.first, entry.isReady, Self.canCompare(entry, model: model) {
            Button("Compare Before & After…", systemImage: "square.split.2x1") { comparing = entry }
        }
        Button("Show Original in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.item.url))
        }
        let outputs = selected.compactMap { entry -> URL? in
            if case .done(let url?, _, _) = entry.job { return url }
            return nil
        }
        if !outputs.isEmpty {
            Button("Show Converted File in Finder", systemImage: "checkmark.circle") {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        Divider()
        Button("Remove", systemImage: "minus.circle", role: .destructive) { model.remove(ids) }
            .disabled(model.phase == .converting)
    }
}

struct SectionHeader: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.totals(for: kind)
        HStack(spacing: 8) {
            Image(systemName: kind.symbolName)
            Text(kind.displayName)
            Text("\(totals.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
            Spacer()
            Text(Formatters.bytes(totals.originalBytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.headline)
    }
}
