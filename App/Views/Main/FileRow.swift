import MorphKit
import SwiftUI

struct FileRow: View {
    let entry: FileEntry
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var showLog = false

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(item: entry.item)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detailLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isReady {
                OutputBadge(text: outputLabel)
            }
            SizeColumn(entry: entry)
                .frame(minWidth: 118, alignment: .trailing)
            status
                .frame(width: 26, height: 26)
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var outputLabel: String {
        let settings = model.settings(for: entry.kind)
        let ext = FormatRegistry.outputExtension(for: entry.item, settings: settings, capabilities: model.capabilities)
        return ext.uppercased()
    }

    @ViewBuilder
    private var detailLine: some View {
        switch entry.probe {
        case .pending:
            Text("Reading…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
        case .ready:
            HStack(spacing: 6) {
                Text(entry.item.summary)
                if case .done(_, _, let note?) = entry.job {
                    Text("· \(note)").foregroundStyle(.orange)
                } else if let note = entry.estimate?.note {
                    Text("· \(note)").foregroundStyle(.orange)
                } else if case .failed(let message, _) = entry.job {
                    Text("· \(message)").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch entry.job {
        case .idle:
            if entry.probe == .pending {
                ProgressView().controlSize(.small)
            } else if entry.isFailed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .help(entry.failureMessage ?? "")
            } else if hovering && model.phase != .converting {
                Button {
                    model.remove([entry.id])
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            } else if entry.isRefining {
                ProgressView().controlSize(.mini)
            }
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
                .help("Waiting")
        case .running(let fraction, let remaining):
            ProgressRing(fraction: fraction)
                .help(remaining.map { "About \(Formatters.duration(max(1, $0))) left" } ?? "Converting")
        case .done(let url, _, _):
            Button {
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, options: .nonRepeating, value: true)
            }
            .buttonStyle(.plain)
            .help(url.map { "Show \($0.lastPathComponent) in Finder" } ?? "Skipped")
        case .failed(let message, let log):
            Button {
                showLog = true
            } label: {
                Image(systemName: "xmark.octagon.fill").font(.title3).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(message)
            .popover(isPresented: $showLog) {
                FailureDetails(message: message, log: log)
            }
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary).help("Stopped")
        }
    }
}

struct OutputBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.12), in: .capsule)
        }
    }
}

/// "3.1 MB → ≈ 640 KB −79%" or the final size after converting.
struct SizeColumn: View {
    let entry: FileEntry

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch entry.job {
            case .done(_, let bytes, _) where bytes > 0:
                Text(Formatters.bytes(bytes))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                ChangeText(original: entry.item.fileSize, new: bytes)
            default:
                if let estimate = entry.estimate, entry.isReady {
                    Text((estimate.isExact ? "" : "≈ ") + Formatters.bytes(estimate.bytes))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: estimate.bytes)
                    HStack(spacing: 4) {
                        Text(Formatters.bytes(entry.item.fileSize)).foregroundStyle(.tertiary)
                        ChangeText(original: entry.item.fileSize, new: estimate.bytes)
                    }
                    .font(.caption)
                } else {
                    Text(Formatters.bytes(entry.item.fileSize))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

struct ChangeText: View {
    let original: Int64
    let new: Int64

    var body: some View {
        Text(Formatters.change(from: original, to: new))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(new <= original ? Color.green : Color.orange)
    }
}

struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: fraction)
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel("\(Int(fraction * 100)) percent")
    }
}

struct ThumbnailView: View {
    let item: MediaItem
    var side: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary.opacity(0.7))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: 9, style: .continuous))
                    .transition(.opacity)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .task(id: item.url) {
            if let cached = ThumbnailService.shared.cached(item.url) {
                image = cached
                return
            }
            let loaded = await ThumbnailService.shared.thumbnail(for: item)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

struct FailureDetails: View {
    let message: String
    let log: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            if let log, !log.isEmpty {
                ScrollView {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 460, height: 180)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
            }
        }
        .padding(16)
    }
}
