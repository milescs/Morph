import MorphKit
import SwiftUI

/// The first thing people see: a big, friendly drop target.
struct EmptyDropZone: View {
    @Environment(AppModel.self) private var model
    @State private var dashPhase: CGFloat = 0
    @State private var appeared = false
    @State private var floating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let chips = ["HEIC", "JPEG", "PNG", "WebP", "AVIF", "SVG", "GIF", "TIFF", "RAW",
                         "MP4", "MOV", "MKV", "WebM", "MP3", "WAV", "FLAC", "PDF"]

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(.tint.opacity(model.isDropTargeted ? 0.12 : 0.04))
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: model.isDropTargeted ? 3 : 2, lineCap: .round,
                                                     dash: [12, 10], dashPhase: dashPhase))
                    .foregroundStyle(model.isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(.tint.opacity(0.18))
                            .frame(width: 140, height: 140)
                            .blur(radius: model.isDropTargeted ? 4 : 18)
                        if model.isDropTargeted {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 64, weight: .light))
                                .foregroundStyle(.tint)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                                .resizable()
                                .frame(width: 112, height: 112)
                                .shadow(color: .accentColor.opacity(0.35), radius: 16, y: 6)
                                .offset(y: floating ? -4 : 4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.35), value: model.isDropTargeted)
                    VStack(spacing: 8) {
                        Text(model.isDropTargeted ? "Release to add" : "Drop files or folders")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text("Convert and compress images, videos, audio and PDFs.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Label("Everything happens on your Mac. Nothing is uploaded.", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    HStack(spacing: 12) {
                        Button {
                            MainWindowController.shared.chooseFiles()
                        } label: {
                            Label("Choose Files…", systemImage: "doc.badge.plus")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            MainWindowController.shared.chooseFolder()
                        } label: {
                            Label("Choose Folder…", systemImage: "folder.badge.plus")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                    }
                    .controlSize(.extraLarge)
                    .padding(.top, 6)
                }
                .padding(40)
            }
            .frame(maxWidth: 680, maxHeight: 420)
            .scaleEffect(model.isDropTargeted ? 1.015 : 1)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: model.isDropTargeted)

            FlowChips(items: chips)
                .frame(maxWidth: 560)
                .opacity(appeared ? 1 : 0)

            if let problem = model.ffmpegProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .capsule)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { dashPhase = -44 }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { floating = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop files or folders to convert")
    }
}

/// Wrapping row of small format chips.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }
        }
    }
}

/// Minimal flow layout (wraps subviews onto new lines, centered or leading-aligned).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = alignment == .leading ? bounds.minX : bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width && !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
