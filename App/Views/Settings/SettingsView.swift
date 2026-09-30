import MorphKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Saving", systemImage: "square.and.arrow.down") { SavingSettings() }
            Tab("Performance", systemImage: "speedometer") { PerformanceSettings() }
            Tab("Quick Actions", systemImage: "bolt") { QuickActionSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 560, height: 470)
    }
}

private struct GeneralSettings: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Toggle("Show Morph in the Dock", isOn: $settings.showInDock)
                Toggle("Show Morph in the menu bar", isOn: $settings.showInMenuBar)
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
            Section("When conversions finish") {
                Toggle("Send a notification when Morph is in the background", isOn: $settings.notifyWhenDone)
                    .onChange(of: settings.notifyWhenDone) { _, on in if on { SystemFeedback.requestNotificationPermission() } }
                Toggle("Show converted files in Finder", isOn: $settings.revealWhenDone)
            }
            Section("Options") {
                Toggle("Show Pro options", isOn: $settings.proMode)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SavingSettings: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Where to save", selection: $settings.alwaysSaveNextToOriginals) {
                    Text("Ask each time (starts in the original's folder)").tag(false)
                    Text("Always next to the originals").tag(true)
                }
                Toggle("Quick actions save next to the originals", isOn: $settings.quickActionsSaveNextToOriginals)
            }
            Section {
                LabeledContent("New format") {
                    TextField("", text: $settings.filenameTemplate)
                        .frame(width: 200)
                }
                LabeledContent("Same format (compressed)") {
                    TextField("", text: $settings.sameFormatTemplate)
                        .frame(width: 200)
                }
                Picker("If a file already exists", selection: $settings.collisionPolicy) {
                    ForEach(CollisionPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Keep the original's creation and modification dates", isOn: $settings.preserveFileDates)
            } header: {
                Text("File names")
            } footer: {
                Text("“{name}” is replaced with the original file name. Originals are never overwritten.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PerformanceSettings: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let caps = SystemCapabilities.current
        Form {
            Section {
                Picker("Parallel conversions", selection: $settings.maxParallel) {
                    Text("Automatic (up to \(caps.performanceCores))").tag(0)
                    ForEach([1, 2, 4, 8, 12, 16].filter { $0 <= max(caps.performanceCores, 2) }, id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
            } footer: {
                Text("Files convert in list order. Morph runs several at once when your Mac has room, and slows down automatically when it's hot or in Low Power Mode.")
            }
            Section("This Mac") {
                LabeledContent("Chip", value: caps.chipName.isEmpty ? "Apple silicon" : caps.chipName)
                LabeledContent("Performance cores", value: "\(caps.performanceCores)")
                LabeledContent("Hardware video encoders", value: "\(caps.videoEncodeEngines)")
                LabeledContent("Memory", value: Formatters.bytes(Int64(caps.physicalMemory)))
            }
        }
        .formStyle(.grouped)
    }
}

private struct QuickActionSettings: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section {
                ForEach(QuickAction.allCases) { action in
                    Toggle(isOn: Binding(
                        get: { settings.quickActions.contains(action) },
                        set: { on in
                            if on {
                                settings.quickActions = QuickAction.allCases.filter { settings.quickActions.contains($0) || $0 == action }
                            } else if settings.quickActions.count > 1 {
                                settings.quickActions.removeAll { $0 == action }
                            }
                        })) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(action.title)
                                Text(action.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: action.symbol)
                        }
                    }
                }
            } header: {
                Text("Menu bar actions")
            } footer: {
                Text("Drag files onto the Morph icon in the menu bar, then drop them on an action.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model

    private let components: [(String, String, String)] = [
        ("FFmpeg", "GPL-3.0", "https://ffmpeg.org"),
        ("x264", "GPL-2.0+", "https://www.videolan.org/developers/x264.html"),
        ("x265", "GPL-2.0+", "https://www.videolan.org/developers/x265.html"),
        ("SVT-AV1", "BSD-3-Clause-Clear", "https://gitlab.com/AOMediaCodec/SVT-AV1"),
        ("libvpx", "BSD-3-Clause", "https://www.webmproject.org"),
        ("dav1d", "BSD-2-Clause", "https://code.videolan.org/videolan/dav1d"),
        ("Opus", "BSD-3-Clause", "https://opus-codec.org"),
        ("LAME", "LGPL-2.0", "https://lame.sourceforge.io"),
        ("libwebp", "BSD-3-Clause", "https://chromium.googlesource.com/webm/libwebp"),
        ("zimg", "WTFPL", "https://github.com/sekrit-twc/zimg"),
        ("resvg", "Apache-2.0 OR MIT", "https://github.com/linebender/resvg"),
        ("vtracer", "MIT", "https://github.com/visioncortex/vtracer"),
        ("oxipng", "MIT", "https://github.com/oxipng/oxipng"),
        ("quantizr", "MIT", "https://github.com/DarthSim/quantizr"),
        ("FFmpeg build script (Martin Riedl)", "Apache-2.0", "https://git.martin-riedl.de/ffmpeg/build-script"),
    ]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Morph").font(.title2.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .foregroundStyle(.secondary)
                        Text("Open source under the MIT License. The bundled FFmpeg is GPL-3.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("FFmpeg", value: model.capabilities.map { "\($0.version)\(model.tools?.isBundled == true ? " (bundled)" : " (development)")" } ?? "Not found")
                LabeledContent("Image codecs", value: RustCodecs.version)
                Button("Show Licenses") {
                    if let url = Bundle.main.resourceURL?.appending(path: "Licenses") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("Open-source components") {
                ForEach(components, id: \.0) { name, license, link in
                    LabeledContent {
                        Text(license).foregroundStyle(.secondary)
                    } label: {
                        Link(name, destination: URL(string: link)!)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
