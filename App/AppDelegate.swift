import AppKit
import MorphKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private let settings = SettingsStore.shared
    private var statusItem: StatusItemController?
    private var launchedWithFiles = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        settings.onPresenceChange = { [weak self] in self?.applyPresence() }
        applyPresence()
        // Show the converter unless we were launched just to handle files (they show it) or as a menu bar app.
        if !launchedWithFiles && settings.showInDock {
            MainWindowController.shared.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithFiles = true
        model.add(urls: urls)
        MainWindowController.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = model.phase == .converting || model.quickBatches.contains { $0.isRunning }
        guard busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop converting and quit?"
        alert.informativeText = "Files that haven't finished will be discarded."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Converting")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            model.cancelConversion()
            for batch in model.quickBatches { batch.cancel() }
            return .terminateNow
        }
        return .terminateCancel
    }

    /// Shows or hides the menu bar item and the Dock icon.
    func applyPresence() {
        if settings.showInMenuBar {
            if statusItem == nil { statusItem = StatusItemController(model: model) }
        } else {
            statusItem?.remove()
            statusItem = nil
        }
        let windowVisible = MainWindowController.shared.window?.isVisible == true
        NSApp.setActivationPolicy(settings.showInDock || windowVisible ? .regular : .accessory)
    }

    // MARK: - Services ("Convert with Morph" in Finder)

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        model.add(urls: urls)
        MainWindowController.shared.show()
    }

    @objc func compressFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        model.add(urls: urls)
        for kind in MediaKind.allCases {
            model.update(kind) { $0.target = kind == .pdf ? $0.target : .original }
        }
        MainWindowController.shared.show()
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
