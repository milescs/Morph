import MorphKit
import SwiftUI

/// Totals + Convert while editing, progress while converting, results when finished.
struct BottomBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            switch model.phase {
            case .editing:
                editing
            case .converting:
                converting
            case .finished:
                finished
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .animation(.smooth, value: model.phase)
    }

    // MARK: Editing

    @ViewBuilder
    private var editing: some View {
        let totals = model.totals()
        VStack(alignment: .leading, spacing: 2) {
            Text(model.outputCount == 1 ? "1 file to convert" : "\(model.outputCount) files to convert")
                .font(.headline)
            HStack(spacing: 6) {
                Text(Formatters.bytes(totals.originalBytes))
                Image(systemName: "arrow.right").font(.caption2)
                if totals.hasEstimate {
                    Text((totals.isApproximate ? "≈ " : "") + Formatters.bytes(totals.estimatedBytes))
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    ChangeText(original: totals.originalBytes, new: totals.estimatedBytes)
                } else {
                    Text("estimating…")
                }
                if totals.isPending {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .animation(.snappy, value: totals.estimatedBytes)
        }
        Spacer()
        Button {
            MainWindowController.shared.convert()
        } label: {
            Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canConvert)
        .help("Convert (⌘↩). You'll choose where to save next.")
    }

    // MARK: Converting

    @ViewBuilder
    private var converting: some View {
        if let batch = model.batch {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Converting \(min(batch.completedCount + 1, batch.jobCount)) of \(batch.jobCount)")
                        .font(.headline)
                    Spacer()
                    if let remaining = batch.remaining, remaining.isFinite, remaining > 1 {
                        Text("About \(Formatters.duration(remaining)) left")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: batch.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
            Button(role: .cancel) {
                model.cancelConversion()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
        }
    }

    // MARK: Finished

    @ViewBuilder
    private var finished: some View {
        if let summary = model.batch?.summary {
            Image(systemName: summary.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(summary.failed > 0 ? Color.orange : Color.green)
                .symbolEffect(.bounce, value: summary.converted)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(summary)).font(.headline)
                Text(detail(summary))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Convert Again") { model.prepareForNextBatch() }
                .buttonStyle(.glass)
            Button("Clear") { model.removeAll() }
                .buttonStyle(.glass)
            if !summary.outputs.isEmpty {
                Button {
                    model.revealOutputs()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func headline(_ summary: BatchSummary) -> String {
        var parts: [String] = []
        parts.append(summary.converted == 1 ? "1 file converted" : "\(summary.converted) files converted")
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.cancelled > 0 { parts.append("\(summary.cancelled) stopped") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ summary: BatchSummary) -> String {
        let time = summary.duration < 60 ? String(format: "%.1f s", summary.duration) : Formatters.duration(summary.duration)
        guard summary.converted > 0 else { return "in \(time)" }
        if summary.savedBytes > 0 {
            return "Saved \(Formatters.bytes(summary.savedBytes)) (\(Formatters.change(from: summary.originalBytes, to: summary.outputBytes))) in \(time)"
        }
        return "\(Formatters.bytes(summary.outputBytes)) in \(time)"
    }
}
