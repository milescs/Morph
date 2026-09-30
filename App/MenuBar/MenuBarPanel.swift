import MorphKit
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class MenuBarPanelState {
    var isDragging = false
}

/// The popover under the menu bar icon.
struct MenuBarPanel: View {
    let state: MenuBarPanelState
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @State private var openTargeted = false
    @State private var targetedAction: QuickAction?
    @State private var targetedDestination: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            dropZone
            quickActions
            destinations
            if !model.quickBatches.isEmpty || model.phase == .converting {
                activity
            }
            if !state.isDragging {
                recents
                footer
            }
        }
        .padding(16)
        .frame(width: 360)
        .animation(.smooth(duration: 0.25), value: state.isDragging)
        .animation(.smooth(duration: 0.25), value: model.quickBatches.count)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("Morph").font(.headline)
                Text(state.isDragging ? "Drop on an action" : "Convert anything")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !state.isDragging {
                Button {
                    close()
                    MainWindowController.shared.show()
                } label: {
                    Label("Open Morph", systemImage: "macwindow")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: openTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: openTargeted)
            Text("Open in Morph").font(.callout.weight(.semibold))
            Text("Choose formats and quality").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(openTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(.tint.opacity(openTargeted ? 0.12 : 0.03), in: .rect(cornerRadius: 16, style: .continuous))
        }
        .contentShape(.rect(cornerRadius: 16))
        .onTapGesture {
            close()
            MainWindowController.shared.chooseFiles()
        }
        .dropDestination(for: URL.self) { urls, _ in
            close()
            model.add(urls: urls)
            MainWindowController.shared.show()
            return true
        } isTargeted: { openTargeted = $0 }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK CONVERT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(settings.quickActions.filter { $0.isAvailable && $0.destination == nil }) { action in
                        QuickActionTile(action: action, isTargeted: targetedAction == action)
                            .onTapGesture { choose(for: action) }
                            .dropDestination(for: URL.self) { urls, _ in
                                close()
                                model.runQuickAction(action, urls: urls)
                                return true
                            } isTargeted: { targeted in
                                if targeted { targetedAction = action } else if targetedAction == action { targetedAction = nil }
                            }
                    }
                }
            }
            Text(settings.quickActionsSaveNextToOriginals
                 ? "Saved next to the originals." : "You'll choose where to save.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Fit for" chips: drop files on Email, Discord … to get the right format and size for it.
    @ViewBuilder
    private var destinations: some View {
        let shown = DestinationStore.shared.destinations.filter { !settings.hiddenMenuBarDestinations.contains($0.id) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("FIT FOR").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                FlowLayout(spacing: 6, alignment: .leading) {
                    ForEach(shown) { destination in
                        DestinationChip(destination: destination, isSelected: targetedDestination == destination.id) {
                            choose(for: .destination(destination.id))
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            close()
                            model.runQuickAction(.destination(destination.id), urls: urls)
                            return true
                        } isTargeted: { targeted in
                            if targeted {
                                targetedDestination = destination.id
                            } else if targetedDestination == destination.id {
                                targetedDestination = nil
                            }
                        }
                        .scaleEffect(targetedDestination == destination.id ? 1.06 : 1)
                        .animation(.spring(duration: 0.25, bounce: 0.4), value: targetedDestination)
                    }
                }
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            if model.phase == .converting, let batch = model.batch {
                BatchProgressRow(batch: batch)
            }
            ForEach(model.quickBatches) { batch in
                BatchProgressRow(batch: batch)
            }
        }
    }

    @ViewBuilder
    private var recents: some View {
        if !model.recents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("RECENT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                    Spacer()
                    Button("Clear") { model.clearRecents() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recents.prefix(5)) { recent in
                    RecentRow(recent: recent)
                }
                Text("Drag a file into another app or website to upload it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                ForEach([OutputFormat.png, .jpeg, .webp, .heic], id: \.self) { format in
                    Button("Copy as \(format.displayName)") { model.convertClipboardImage(to: format) }
                }
            } label: {
                Label("Clipboard Image", systemImage: "doc.on.clipboard")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button {
                close()
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit Morph")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func choose(for action: QuickAction) {
        close()
        let panel = NSOpenPanel()
        panel.title = "\(action.title) — choose files"
        panel.prompt = action.title
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = FileFormat.supportedContentTypes + [.folder]
        NSApp.activate()
        if panel.runModal() == .OK {
            model.runQuickAction(action, urls: panel.urls)
        }
    }
}

struct QuickActionTile: View {
    let action: QuickAction
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: action.symbol)
                .font(.system(size: 18))
                .symbolEffect(.bounce, value: isTargeted)
            Text(action.title).font(.callout.weight(.semibold))
            Text(action.subtitle).font(.caption2).foregroundStyle(isTargeted ? .white.opacity(0.85) : .secondary)
                .lineLimit(1)
        }
        .foregroundStyle(isTargeted ? .white : .primary)
        .frame(maxWidth: .infinity, minHeight: 70)
        .contentShape(.rect(cornerRadius: 14))
        .glassEffect(isTargeted ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 14, style: .continuous))
        .scaleEffect(isTargeted ? 1.05 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.4), value: isTargeted)
    }
}

struct BatchProgressRow: View {
    let batch: BatchRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(batch.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if let summary = batch.summary {
                    Label(summary.failed > 0 ? "\(summary.failed) failed" : "Done",
                          systemImage: summary.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(summary.failed > 0 ? .orange : .green)
                } else {
                    Text("\(batch.completedCount)/\(batch.jobCount)").font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: batch.progress)
                .progressViewStyle(.linear)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

struct RecentRow: View {
    let recent: RecentOutput
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: recent.url.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(Formatters.bytes(recent.bytes))
                    if recent.originalBytes > 0 {
                        ChangeText(original: recent.originalBytes, new: recent.bytes)
                    }
                    Text("·")
                    Text(recent.date, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if hovering {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([recent.url])
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(recent.url) }
        .draggable(recent.url) {
            Label(recent.url.lastPathComponent, systemImage: "doc")
                .padding(8)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(recent.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recent.url]) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([recent.url as NSURL])
            }
        }
    }
}
