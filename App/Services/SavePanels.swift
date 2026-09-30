import AppKit
import MorphKit
import UniformTypeIdentifiers

/// Where converted files should go.
enum DestinationChoice: Equatable {
    case nextToOriginals
    case folder(URL)
    /// A single output saved to an exact, user-confirmed location.
    case file(URL)
}

/// Finder panels for choosing where to save. They open in the original's folder by default.
enum SavePanels {
    /// Single output: a Save panel with the new name filled in.
    static func chooseFile(suggestedName: String, directory: URL, fileExtension: String,
                           window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Converted File"
        panel.prompt = "Convert"
        panel.message = "Choose where to save the converted file."
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.showsTagField = true
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        return await run(panel, window: window) ? panel.url : nil
    }

    /// Several outputs: pick a folder (defaults to the originals' folder).
    static func chooseFolder(directory: URL, sourcesSpanFolders: Bool, fileCount: Int,
                             window: NSWindow?) async -> DestinationChoice? {
        let panel = NSOpenPanel()
        panel.title = "Save Converted Files"
        panel.prompt = "Convert \(fileCount) Files"
        panel.message = "Choose a folder for the converted files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory

        let checkbox = NSButton(checkboxWithTitle: "Save each file next to its original", target: nil, action: nil)
        checkbox.state = sourcesSpanFolders ? .on : .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 36))
        checkbox.frame.origin = NSPoint(x: 16, y: 9)
        checkbox.sizeToFit()
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        guard await run(panel, window: window) else { return nil }
        if checkbox.state == .on { return .nextToOriginals }
        guard let url = panel.url else { return nil }
        return .folder(url)
    }

    private static func run(_ panel: NSSavePanel, window: NSWindow?) async -> Bool {
        NSApp.activate()
        if let window, window.isVisible {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK)
                }
            }
        }
        return panel.runModal() == .OK
    }
}
