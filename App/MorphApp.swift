import MorphKit
import SwiftUI

@main
struct MorphApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Windows are owned by AppKit (see MainWindowController); SwiftUI supplies the menus.
        Settings { EmptyView() }
            .commands { MorphCommands() }
    }
}

struct MorphCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { MainWindowController.shared.chooseFiles() }
                .keyboardShortcut("o")
            Button("Add Folder…") { MainWindowController.shared.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Converter Window") { MainWindowController.shared.show() }
                .keyboardShortcut("1")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Add from Clipboard") { AppModel.shared.paste() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandMenu("Convert") {
            Button("Convert") { MainWindowController.shared.convert() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Stop Converting") { AppModel.shared.cancelConversion() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Remove Selected") {
                AppModel.shared.remove(AppModel.shared.selection)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Clear List") { AppModel.shared.removeAll() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            Divider()
            Button(SettingsStore.shared.proMode ? "Hide Pro Options" : "Show Pro Options") {
                SettingsStore.shared.proMode.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}
