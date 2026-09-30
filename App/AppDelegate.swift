import AppKit
import MorphKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private let settings = SettingsStore.shared
    private var statusItem: StatusItemController?
    private var launchedWithFiles = false
    /// Set when Shortcuts or a Finder Quick Action launched Morph to do work in the background.
    private static var handlingBackgroundRequest = false

    /// Keeps the converter window from popping up when Morph was launched just to run an action.
    static func noteBackgroundRequest() {
        handlingBackgroundRequest = true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        settings.onPresenceChange = { [weak self] in self?.applyPresence() }
        applyPresence()
        _ = Updater.shared
        DestinationStore.shared.refreshIfNeeded()
        // Show the converter unless we were launched to handle files (they show it), to run a Shortcut
        // or Finder Quick Action in the background, or as a menu bar app. Those requests arrive just
        // after launch, so wait a moment before deciding.
        if !launchedWithFiles && settings.showInDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.launchedWithFiles, !Self.handlingBackgroundRequest else { return }
                MainWindowController.shared.show()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DestinationStore.shared.refreshIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let requests = urls.filter { $0.scheme == "morph" }
        for url in requests { ExtensionRequests.handle(url) }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        launchedWithFiles = true
        model.add(urls: files)
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
            model.update(kind) { $0.target = .original }
        }
        MainWindowController.shared.show()
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
