import MorphKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @State private var inspectorVisible = true

    var body: some View {
        ZStack {
            if model.isEmpty {
                EmptyDropZone()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                FileListView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.isEmpty)
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.isDropTargeted && !model.isEmpty {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isDropTargeted)
        .overlay(alignment: .top) { ToastView() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.isEmpty {
                BottomBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorView()
                .inspectorColumnWidth(min: 340, ideal: 380, max: 520)
        }
        .toolbar { toolbarContent }
        .navigationTitle("Morph")
        .navigationSubtitle(subtitle)
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { _ in model.paste() }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { inspectorVisible && !model.isEmpty }, set: { inspectorVisible = $0 })
    }

    private var subtitle: String {
        guard !model.isEmpty else { return "" }
        let count = model.entries.count
        return count == 1 ? "1 file" : "\(count) files"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                Button("Add Files…", systemImage: "doc.badge.plus") { MainWindowController.shared.chooseFiles() }
                Button("Add Folder…", systemImage: "folder.badge.plus") { MainWindowController.shared.chooseFolder() }
                Divider()
                Button("Add from Clipboard", systemImage: "doc.on.clipboard") { model.paste() }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                MainWindowController.shared.chooseFiles()
            }
            .help("Add files (⌘O)")
            .disabled(model.phase == .converting)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.isEmpty {
                Button("Clear", systemImage: "trash") { model.removeAll() }
                    .help("Remove all files from the list")
                    .disabled(model.phase == .converting)
            }
            Toggle(isOn: Binding(get: { settings.proMode }, set: { settings.proMode = $0 })) {
                Label("Pro", systemImage: "slider.horizontal.3")
            }
            .help("Show advanced options")
            if !model.isEmpty {
                Button("Inspector", systemImage: "sidebar.trailing") { inspectorVisible.toggle() }
                    .help("Show or hide conversion settings")
            }
        }
    }
}

/// Highlight shown over the list while files are dragged in.
struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 24, style: .continuous))
            .overlay {
                Label("Drop to add", systemImage: "plus.circle.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.3)), in: .capsule)
            }
            .padding(14)
            .allowsHitTesting(false)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast)
        }
    }
}
