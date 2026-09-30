import MorphKit
import SwiftUI

extension AppModel {
    /// A binding into a group's settings.
    func binding<Value>(_ kind: MediaKind, _ keyPath: WritableKeyPath<ConversionSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings(for: kind)[keyPath: keyPath] },
                set: { value in self.update(kind) { $0[keyPath: keyPath] = value } })
    }
}

/// Advanced options for the selected group, adapted to its target.
struct ProOptionsView: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let target = model.settings(for: kind).target
        switch (kind, target.category) {
        case (.pdf, .original):
            PDFCompressProOptions(kind: kind)
        case (_, .video), (.video, .original):
            VideoProOptions(kind: kind)
        case (_, .animated):
            AnimationProOptions(kind: kind)
        case (_, .audio), (.audio, .original):
            AudioProOptions(kind: kind)
        case (_, .frame):
            FrameProOptions(kind: kind)
            ImageProOptions(kind: kind)
        default:
            ImageProOptions(kind: kind)
        }
    }
}

// MARK: - PDF compression

struct PDFCompressProOptions: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Picker("Image resolution", selection: model.binding(kind, \.image.pdfImageDPI)) {
                Text("Automatic (from quality)").tag(Int?.none)
                ForEach([300, 200, 150, 110, 72], id: \.self) { Text("\($0) dpi").tag(Int?.some($0)) }
            }
            Picker("Title and author", selection: Binding(
                get: { model.settings(for: kind).image.metadata == .removeAll },
                set: { remove in model.update(kind) { $0.image.metadata = remove ? .removeAll : .removeLocation } })) {
                Text("Keep").tag(false)
                Text("Remove").tag(true)
            }
        } header: {
            Text("PDF compression")
        } footer: {
            Text("150 dpi is sharp on screens; 300 dpi is print quality. Pages without images barely change, and Morph never makes a PDF bigger.")
        }
    }
}

// MARK: - Images

struct ImageProOptions: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    enum ResizeChoice: String, CaseIterable, Identifiable {
        case none, percent, longest, fit, fill
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "Original size"
            case .percent: "Percentage"
            case .longest: "Longest side"
            case .fit: "Fit inside"
            case .fill: "Fill exactly"
            }
        }
    }

    var body: some View {
        let settings = model.settings(for: kind)
        let options = settings.image
        let target = settings.target
        let format = target == .original ? nil : target.imageFormat
        let items = model.entries(of: kind).map(\.item)

        Section("Size") {
            Picker("Resize", selection: resizeChoice) {
                ForEach(ResizeChoice.allCases) { Text($0.title).tag($0) }
            }
            resizeFields(options.resize)
            if options.resize != .none {
                Toggle("Allow enlarging", isOn: model.binding(kind, \.image.allowUpscale))
            }
            if items.contains(where: { $0.format == .svg }) {
                Picker("SVG render scale", selection: model.binding(kind, \.image.svgScale)) {
                    ForEach([1.0, 2.0, 3.0, 4.0, 8.0], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
            }
        }

        if kind == .pdf {
            Section("PDF pages") {
                Picker("Resolution", selection: model.binding(kind, \.image.pdfDPI)) {
                    ForEach([72.0, 150.0, 300.0, 600.0], id: \.self) { Text("\(Int($0)) dpi").tag($0) }
                }
                Picker("Pages", selection: pageChoice) {
                    Text("All pages").tag(0)
                    Text("First page only").tag(1)
                    Text("Range").tag(2)
                }
                if case .range(let from, let to) = options.pdfPages {
                    HStack {
                        Stepper("From \(from)", value: Binding(get: { from }, set: { value in model.update(kind) { $0.image.pdfPages = .range(from: max(1, value), to: max(value, to)) } }), in: 1...9999)
                        Stepper("to \(to)", value: Binding(get: { to }, set: { value in model.update(kind) { $0.image.pdfPages = .range(from: from, to: max(from, value)) } }), in: 1...9999)
                    }
                }
            }
        }

        if target == .pdf || target == .pdfCombined {
            Section("PDF") {
                Picker("Page size", selection: model.binding(kind, \.image.pdfPageSize)) {
                    ForEach(PDFPageSize.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }

        Section("Color & metadata") {
            Picker("Color profile", selection: model.binding(kind, \.image.colorProfile)) {
                ForEach(ColorProfileOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Metadata", selection: model.binding(kind, \.image.metadata)) {
                ForEach(MetadataPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if format == .jpeg || format == .bmp || format == nil {
                ColorPicker("Background for transparency", selection: flattenColor, supportsOpacity: false)
            }
        }

        Section("Encoding") {
            if [.webp, .avif, .heic, .jp2].contains(format) {
                Toggle("Lossless", isOn: model.binding(kind, \.image.lossless))
            }
            if format == .jpeg || target == .auto {
                Toggle("Progressive (loads gradually on the web)", isOn: model.binding(kind, \.image.progressive))
            }
            if format == .png || target == .original || target == .auto {
                Picker("PNG compression effort", selection: model.binding(kind, \.image.pngOptimization)) {
                    ForEach(0...6, id: \.self) { Text($0 == 0 ? "Fastest" : $0 == 6 ? "Maximum (slow)" : "Level \($0)").tag($0) }
                }
                LabeledContent("PNG dithering") {
                    Slider(value: model.binding(kind, \.image.pngDithering), in: 0...1)
                        .frame(width: 140)
                }
            }
            if format == .webp {
                Picker("WebP effort", selection: model.binding(kind, \.image.webpMethod)) {
                    ForEach(0...6, id: \.self) { Text($0 == 0 ? "Fastest" : $0 == 6 ? "Smallest (slow)" : "\($0)").tag($0) }
                }
                Picker("Chroma", selection: model.binding(kind, \.image.chroma)) {
                    ForEach(ChromaSubsampling.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            if items.contains(where: \.isAnimatedImage) {
                Toggle("Keep animation (GIF, WebP, PNG)", isOn: model.binding(kind, \.image.keepAnimation))
            }
            LabeledContent("DPI") {
                TextField("Keep", value: model.binding(kind, \.image.dpi), format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
        }

        if format == .ico {
            Section("Icon sizes") {
                ForEach([16, 24, 32, 48, 64, 128, 256], id: \.self) { side in
                    Toggle("\(side) × \(side)", isOn: Binding(
                        get: { options.icoSizes.contains(side) },
                        set: { on in model.update(kind) { s in
                            if on { s.image.icoSizes = Array(Set(s.image.icoSizes + [side])).sorted() }
                            else if s.image.icoSizes.count > 1 { s.image.icoSizes.removeAll { $0 == side } }
                        } }))
                }
            }
        }

        if target == .svgTrace {
            TraceOptionsSection(kind: kind)
        }
    }

    private var resizeChoice: Binding<ResizeChoice> {
        Binding(get: {
            switch model.settings(for: kind).image.resize {
            case .none: .none
            case .percent: .percent
            case .longestSide: .longest
            case .fit: .fit
            case .fill: .fill
            }
        }, set: { choice in
            model.update(kind) { s in
                s.image.resize = switch choice {
                case .none: .none
                case .percent: .percent(50)
                case .longest: .longestSide(2048)
                case .fit: .fit(width: 1920, height: 1080)
                case .fill: .fill(width: 1080, height: 1080)
                }
            }
        })
    }

    @ViewBuilder
    private func resizeFields(_ mode: ResizeMode) -> some View {
        switch mode {
        case .none:
            EmptyView()
        case .percent(let percent):
            LabeledContent("Scale") {
                HStack {
                    Slider(value: Binding(get: { percent }, set: { v in model.update(kind) { $0.image.resize = .percent(v.rounded()) } }),
                           in: 5...200)
                        .frame(width: 140)
                    Text("\(Int(percent))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        case .longestSide(let side):
            LabeledContent("Longest side") {
                HStack {
                    TextField("px", value: Binding(get: { side }, set: { v in model.update(kind) { $0.image.resize = .longestSide(max(1, v)) } }),
                              format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("px").foregroundStyle(.secondary)
                }
            }
        case .fit(let w, let h), .fill(let w, let h):
            let isFit: Bool = if case .fit = mode { true } else { false }
            LabeledContent(isFit ? "Fit inside" : "Size") {
                HStack(spacing: 4) {
                    TextField("W", value: Binding(get: { w }, set: { v in model.update(kind) { $0.image.resize = isFit ? .fit(width: max(1, v), height: h) : .fill(width: max(1, v), height: h) } }),
                              format: .number)
                        .frame(width: 64)
                    Text("×")
                    TextField("H", value: Binding(get: { h }, set: { v in model.update(kind) { $0.image.resize = isFit ? .fit(width: w, height: max(1, v)) : .fill(width: w, height: max(1, v)) } }),
                              format: .number)
                        .frame(width: 64)
                    Text("px").foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.trailing)
            }
        }
    }

    private var pageChoice: Binding<Int> {
        Binding(get: {
            switch model.settings(for: kind).image.pdfPages {
            case .all: 0
            case .first: 1
            case .range: 2
            }
        }, set: { choice in
            model.update(kind) { s in
                s.image.pdfPages = choice == 0 ? .all : choice == 1 ? .first : .range(from: 1, to: 2)
            }
        })
    }

    private var flattenColor: Binding<Color> {
        Binding(get: {
            let c = model.settings(for: kind).image.flattenColor
            return Color(red: c.red, green: c.green, blue: c.blue)
        }, set: { color in
            let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
            model.update(kind) {
                $0.image.flattenColor = RGBColor(red: resolved.redComponent, green: resolved.greenComponent,
                                                 blue: resolved.blueComponent)
            }
        })
    }
}

struct TraceOptionsSection: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let trace = model.settings(for: kind).image.trace
        Section("Tracing") {
            Toggle("Color", isOn: model.binding(kind, \.image.trace.color))
            LabeledContent("Colors") {
                Slider(value: Binding(get: { Double(trace.colorPrecision) },
                                      set: { v in model.update(kind) { $0.image.trace.colorPrecision = Int(v) } }),
                       in: 1...8, step: 1)
                    .frame(width: 140)
            }
            .disabled(!trace.color)
            LabeledContent("Ignore specks smaller than") {
                Stepper("\(trace.filterSpeckle) px", value: model.binding(kind, \.image.trace.filterSpeckle), in: 0...64)
            }
            Picker("Curves", selection: model.binding(kind, \.image.trace.mode)) {
                Text("Smooth").tag(TraceOptions.Mode.spline)
                Text("Straight lines").tag(TraceOptions.Mode.polygon)
                Text("Pixels").tag(TraceOptions.Mode.pixel)
            }
            Toggle("Stack shapes (smaller file)", isOn: model.binding(kind, \.image.trace.stacked))
            Picker("Trace at most", selection: model.binding(kind, \.image.trace.maxSide)) {
                ForEach([800, 1200, 1600, 2400, 4000], id: \.self) { Text("\($0) px").tag($0) }
            }
        }
    }
}

// MARK: - Video

struct VideoProOptions: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model
    @State private var showCommand = false

    var body: some View {
        let settings = model.settings(for: kind)
        let v = settings.video
        let defaults = defaultEncoderAndContainer(settings.target)
        let container = v.container ?? defaults.container
        let encoder = v.encoder ?? defaults.encoder
        let caps = model.capabilities

        Section("Video") {
            Picker("Container", selection: model.binding(kind, \.video.container)) {
                Text("Automatic (\(defaults.container.displayName))").tag(VideoContainer?.none)
                ForEach(VideoContainer.allCases) { Text($0.displayName).tag(Optional($0)) }
            }
            Picker("Encoder", selection: model.binding(kind, \.video.encoder)) {
                Text("Automatic (\(defaults.encoder.displayName))").tag(VideoEncoder?.none)
                ForEach(VideoEncoder.allCases.filter { e in
                    e.isSupported(in: container) && (e == .copy || caps?.hasEncoder(e.ffmpegName) ?? true)
                }) { Text($0.displayName).tag(Optional($0)) }
            }
            if !encoder.isSupported(in: container) {
                Label("\(encoder.displayName) can't be stored in \(container.displayName).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if encoder == .proresVT {
                Picker("ProRes profile", selection: model.binding(kind, \.video.proresProfile)) {
                    Text("From quality slider").tag(ProResProfile?.none)
                    ForEach(ProResProfile.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
            } else if encoder != .copy {
                Picker("Rate control", selection: model.binding(kind, \.video.rateControl)) {
                    ForEach(RateControl.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                switch v.rateControl {
                case .automatic:
                    EmptyView()
                case .constantQuality:
                    LabeledContent("Constant quality") {
                        Slider(value: model.binding(kind, \.video.constantQuality), in: 0...1)
                            .frame(width: 150)
                    }
                case .averageBitrate:
                    LabeledContent("Video bitrate") {
                        HStack {
                            TextField("kbps", value: model.binding(kind, \.video.bitrateKbps), format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text("kbps").foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Encoder speed", selection: model.binding(kind, \.video.speed)) {
                    ForEach(EncoderSpeed.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }

        if encoder != .copy {
            Section("Picture") {
                Picker("Resolution", selection: resolutionChoice) {
                    ForEach(ResolutionPreset.presets) { Text($0.displayName).tag($0.id) }
                    Text("Custom…").tag("custom")
                }
                if case .custom(let w, let h) = v.resolution {
                    LabeledContent("Fit inside") {
                        HStack(spacing: 4) {
                            TextField("W", value: Binding(get: { w }, set: { nw in model.update(kind) { $0.video.resolution = .custom(width: max(2, nw), height: h) } }), format: .number)
                                .frame(width: 64)
                            Text("×")
                            TextField("H", value: Binding(get: { h }, set: { nh in model.update(kind) { $0.video.resolution = .custom(width: w, height: max(2, nh)) } }), format: .number)
                                .frame(width: 64)
                        }
                        .multilineTextAlignment(.trailing)
                    }
                }
                Toggle("Allow enlarging", isOn: model.binding(kind, \.video.allowUpscale))
                Picker("Frame rate", selection: frameRateChoice) {
                    ForEach(FrameRateOption.presets) { Text($0.displayName).tag($0.id) }
                }
                LabeledContent("Keyframe every") {
                    Stepper(String(format: "%.1f s", v.keyframeSeconds), value: model.binding(kind, \.video.keyframeSeconds),
                            in: 0.5...10, step: 0.5)
                }
                Picker("Bit depth", selection: model.binding(kind, \.video.bitDepth)) {
                    ForEach(BitDepthOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("HDR", selection: model.binding(kind, \.video.hdr)) {
                    ForEach(HDRMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Tone mapping", selection: model.binding(kind, \.video.toneMapper)) {
                    ForEach(ToneMapper.allCases.filter { $0 != .hable || (caps?.hasFilter("zscale") ?? false) }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
        }

        AudioTrackSection(kind: kind)

        Section("Edit") {
            TrimEditor(kind: kind, trim: model.binding(kind, \.video.trim))
            if encoder != .copy {
                Picker("Rotate", selection: model.binding(kind, \.video.rotation)) {
                    ForEach(RotationOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Flip horizontally", isOn: model.binding(kind, \.video.flipHorizontal))
                Toggle("Flip vertically", isOn: model.binding(kind, \.video.flipVertical))
            }
        }

        Section("Output") {
            Toggle("Remove location", isOn: model.binding(kind, \.video.removeLocation))
                .disabled(model.settings(for: kind).video.stripMetadata)
            Toggle("Remove all metadata (location, dates, camera)", isOn: model.binding(kind, \.video.stripMetadata))
            if [.mp4, .mov, .m4v].contains(container) {
                Toggle("Optimize for web streaming", isOn: model.binding(kind, \.video.fastStart))
            }
            CustomArgumentsField(text: model.binding(kind, \.video.customArguments))
            Button("Show FFmpeg Command…") { showCommand = true }
                .popover(isPresented: $showCommand) { CommandPreview(kind: kind) }
        }
    }

    private func defaultEncoderAndContainer(_ target: OutputFormat) -> (encoder: VideoEncoder, container: VideoContainer) {
        switch target {
        case .mp4HEVC: (.hevcVT, .mp4)
        case .mp4AV1: (.svtAV1, .mp4)
        case .movH264: (.h264VT, .mov)
        case .movHEVC: (.hevcVT, .mov)
        case .movProRes: (.proresVT, .mov)
        case .webmVP9: (.vp9, .webm)
        case .webmAV1: (.svtAV1, .webm)
        case .mkvHEVC: (.hevcVT, .mkv)
        case .original:
            if let item = model.entries(of: kind).first?.item, let info = item.info?.media,
               let resolved = MediaPlanner.videoDefaults(for: .original, item: item, info: info) {
                resolved
            } else {
                (.h264VT, .mp4)
            }
        default: (.h264VT, .mp4)
        }
    }

    private var resolutionChoice: Binding<String> {
        Binding(get: { model.settings(for: kind).video.resolution.id.hasPrefix("c") ? "custom" : model.settings(for: kind).video.resolution.id },
                set: { id in
                    model.update(kind) { s in
                        if id == "custom" {
                            s.video.resolution = .custom(width: 1280, height: 720)
                        } else if let preset = ResolutionPreset.presets.first(where: { $0.id == id }) {
                            s.video.resolution = preset
                        }
                    }
                })
    }

    private var frameRateChoice: Binding<String> {
        Binding(get: { model.settings(for: kind).video.frameRate.id },
                set: { id in
                    if let preset = FrameRateOption.presets.first(where: { $0.id == id }) {
                        model.update(kind) { $0.video.frameRate = preset }
                    }
                })
    }
}

struct AudioTrackSection: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let audio = model.settings(for: kind).video.audio
        Section("Audio") {
            Toggle("Include audio", isOn: model.binding(kind, \.video.audio.enabled))
            if audio.enabled {
                Picker("Encoder", selection: model.binding(kind, \.video.audio.encoder)) {
                    ForEach(AudioEncoder.allCases) { Text($0.displayName).tag($0) }
                }
                if !audio.encoder.isLossless && audio.encoder != .copy {
                    Picker("Bitrate", selection: model.binding(kind, \.video.audio.bitrateKbps)) {
                        Text("Automatic").tag(Int?.none)
                        ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag(Optional($0)) }
                    }
                }
                Picker("Sample rate", selection: model.binding(kind, \.video.audio.sampleRate)) {
                    Text("Original").tag(Int?.none)
                    ForEach([22050, 44100, 48000, 96000], id: \.self) { Text("\(Double($0) / 1000, specifier: "%g") kHz").tag(Optional($0)) }
                }
                Picker("Channels", selection: model.binding(kind, \.video.audio.channels)) {
                    ForEach(ChannelLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
    }
}

// MARK: - Animated (GIF / WebP)

struct AnimationProOptions: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let target = model.settings(for: kind).target
        let isGIF = target == .gifAnimated || target == .gif
        if target.isVideoTarget {
            VideoProOptions(kind: kind)
        } else {
            Section(isGIF ? "GIF" : "Animated WebP") {
                Picker("Frame rate", selection: model.binding(kind, \.video.gif.fps)) {
                    Text("From quality").tag(Double?.none)
                    ForEach([8.0, 10.0, 12.0, 15.0, 20.0, 24.0, 30.0], id: \.self) { Text("\(Int($0)) fps").tag(Optional($0)) }
                }
                Picker("Width", selection: model.binding(kind, \.video.gif.maxWidth)) {
                    Text("From quality").tag(Int?.none)
                    ForEach([240, 320, 480, 640, 800, 1080, 1280], id: \.self) { Text("\($0) px").tag(Optional($0)) }
                }
                if isGIF {
                    Picker("Colors", selection: model.binding(kind, \.video.gif.colors)) {
                        Text("From quality").tag(Int?.none)
                        ForEach([16, 32, 64, 128, 256], id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }
                    Picker("Dithering", selection: model.binding(kind, \.video.gif.dither)) {
                        ForEach(GIFDither.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
            Section("Edit") {
                TrimEditor(kind: kind, trim: model.binding(kind, \.video.trim))
            }
        }
    }
}

// MARK: - Audio

struct AudioProOptions: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings(for: kind)
        let a = settings.audio
        let target = settings.target
        let lossy = ![.wav, .aiff, .flac, .m4aALAC].contains(target)
        Section("Audio") {
            if lossy {
                Picker("Bitrate", selection: model.binding(kind, \.audio.bitrateKbps)) {
                    Text("From quality slider").tag(Int?.none)
                    ForEach([48, 64, 96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag(Optional($0)) }
                }
                if target == .mp3 || target == .original {
                    Toggle("Variable bitrate (VBR)", isOn: model.binding(kind, \.audio.variableBitrate))
                        .disabled(a.bitrateKbps != nil)
                }
            }
            Picker("Sample rate", selection: model.binding(kind, \.audio.sampleRate)) {
                Text("Original").tag(Int?.none)
                ForEach([22050, 32000, 44100, 48000, 96000], id: \.self) { Text("\(Double($0) / 1000, specifier: "%g") kHz").tag(Optional($0)) }
            }
            Picker("Channels", selection: model.binding(kind, \.audio.channels)) {
                ForEach(ChannelLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Normalize loudness (EBU R128)", isOn: model.binding(kind, \.audio.normalizeLoudness))
        }
        Section("Edit") {
            TrimEditor(kind: kind, trim: model.binding(kind, \.audio.trim))
        }
        Section("Output") {
            Toggle("Keep cover art", isOn: model.binding(kind, \.audio.keepCoverArt))
            Toggle("Remove metadata (tags)", isOn: model.binding(kind, \.audio.stripMetadata))
            CustomArgumentsField(text: model.binding(kind, \.audio.customArguments))
        }
    }
}

// MARK: - Frames

struct FrameProOptions: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let duration = model.entries(of: kind).compactMap { $0.item.info?.duration }.min() ?? 1
        let time = model.settings(for: kind).video.frameTime
        Section("Frame") {
            LabeledContent("Time") {
                HStack {
                    Slider(value: model.binding(kind, \.video.frameTime), in: 0...max(0.1, duration))
                        .frame(width: 150)
                    Text(Formatters.timestamp(time)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Shared controls

struct TrimEditor: View {
    let kind: MediaKind
    @Binding var trim: TrimRange?
    @Environment(AppModel.self) private var model

    var body: some View {
        let duration = model.entries(of: kind).compactMap { $0.item.info?.duration }.max() ?? 0
        Toggle("Trim", isOn: Binding(get: { trim != nil }, set: { trim = $0 ? TrimRange(start: 0, end: duration > 0 ? duration : nil) : nil }))
        if let current = trim {
            LabeledContent("Start") {
                TimeField(seconds: Binding(get: { current.start }, set: { trim?.start = max(0, $0) }))
            }
            LabeledContent("End") {
                TimeField(seconds: Binding(get: { current.end ?? duration }, set: { trim?.end = $0 > current.start ? $0 : nil }))
            }
            if duration > 0 {
                Text("Keeps \(Formatters.timestamp(current.duration(of: duration))) of \(Formatters.timestamp(duration)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Edits seconds as "m:ss.s".
struct TimeField: View {
    @Binding var seconds: Double
    @State private var text = ""

    var body: some View {
        TextField("0:00.0", text: $text)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .onAppear { text = Formatters.timestamp(seconds) }
            .onChange(of: seconds) { _, new in text = Formatters.timestamp(new) }
            .onSubmit {
                if let value = Self.parse(text) { seconds = value }
                text = Formatters.timestamp(seconds)
            }
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

struct CustomArgumentsField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Custom FFmpeg arguments", text: $text, prompt: Text("e.g. -tune film"))
                .font(.system(.body, design: .monospaced))
            Text("Added before the output file. Passed directly to FFmpeg — no shell.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct CommandPreview: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let command = makeCommand()
        VStack(alignment: .leading, spacing: 10) {
            Text("FFmpeg command").font(.headline)
            ScrollView {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 520, height: 160)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        .padding(16)
    }

    private func makeCommand() -> String {
        guard let engine = model.engine,
              let item = model.entries(of: kind).first(where: { $0.item.info?.media != nil })?.item,
              let info = item.info?.media else {
            return "Add a video or audio file to see its command."
        }
        do {
            return try engine.commandPreview(item: item, info: info, settings: model.settings(for: kind))
        } catch {
            return error.localizedDescription
        }
    }
}
