import AppKit
import MorphKit
import SwiftUI

/// The menu bar item: click for the panel, right-click for a menu, drop files onto it.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private let panelState = MenuBarPanelState()
    private var dropView: StatusDropView?
    private var dragOpened = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = StatusIcon.idle
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Morph — drop files here to convert"

            let dropView = StatusDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.controller = self
            button.addSubview(dropView)
            self.dropView = dropView
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = MenuBarPanel(state: panelState, close: { [weak self] in self?.closePopover() })
            .environment(model)
            .environment(SettingsStore.shared)
        popover.contentViewController = NSHostingController(rootView: root)

        // Animate the icon while anything is converting (checked a few times a second).
        let watcher = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivity() }
        }
        RunLoop.main.add(watcher, forMode: .common)
        activityWatcher = watcher
    }

    // MARK: Icon

    private var activityWatcher: Timer?
    private var animationTimer: Timer?
    private var frameIndex = 0
    private var isDragHovering = false

    private var isBusy: Bool {
        model.phase == .converting || model.quickBatches.contains { $0.isRunning }
    }

    private func updateActivity() {
        if isBusy && animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 14.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !isBusy, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
            frameIndex = 0
            refreshIcon()
        }
    }

    private func advanceFrame() {
        frameIndex = (frameIndex + 1) % StatusIcon.workingFrames.count
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if isDragHovering {
            button.image = StatusIcon.dropTarget
        } else if animationTimer != nil {
            button.image = StatusIcon.workingFrames[frameIndex]
        } else {
            button.image = StatusIcon.idle
        }
    }

    func setDragHover(_ hovering: Bool) {
        isDragHovering = hovering
        refreshIcon()
    }

    func remove() {
        activityWatcher?.invalidate()
        animationTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            showPopover(forDrag: false)
        }
    }

    func showPopover(forDrag: Bool) {
        guard let button = statusItem.button, !popover.isShown || forDrag != dragOpened else { return }
        dragOpened = forDrag
        panelState.isDragging = forDrag
        popover.behavior = forDrag ? .applicationDefined : .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if !forDrag {
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
        dragOpened = false
        panelState.isDragging = false
    }

    /// Called when a drag session that touched the icon ends anywhere.
    func dragSessionEnded() {
        panelState.isDragging = false
        guard dragOpened else { return }
        // Give a drop inside the panel a moment to be handled first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.dragOpened else { return }
            self.closePopover()
        }
    }

    /// Files dropped straight onto the icon open in the converter.
    func openInConverter(_ urls: [URL]) {
        closePopover()
        model.add(urls: urls)
        MainWindowController.shared.show()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Morph", action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add Files…", action: #selector(addFiles), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if !model.recents.isEmpty {
            let recent = NSMenuItem(title: "Recent Conversions", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for output in model.recents.prefix(10) {
                let item = NSMenuItem(title: output.url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
                item.representedObject = output.url
                item.target = self
                item.image = NSWorkspace.shared.icon(forFile: output.url.path)
                item.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(item)
            }
            recent.submenu = submenu
            menu.addItem(recent)
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Morph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openMain() { MainWindowController.shared.show() }
    @objc private func addFiles() { MainWindowController.shared.chooseFiles() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func revealRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func popoverDidClose(_ notification: Notification) {
        dragOpened = false
        panelState.isDragging = false
    }
}

/// Transparent drop target laid over the status item button.
final class StatusDropView: NSView, NSSpringLoadingDestination {
    weak var controller: StatusItemController?
    private var hoverTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropSupport.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var button: NSStatusBarButton? { superview as? NSStatusBarButton }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard DropSupport.canAccept(sender) else { return [] }
        button?.highlight(true)
        controller?.setDragHover(true)
        // Fallback if the system's spring-loading doesn't fire. Drags run the event-tracking
        // run loop mode, so the timer must be scheduled in the common modes.
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.showPopover(forDrag: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DropSupport.canAccept(sender) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        hoverTimer?.invalidate()
        button?.highlight(false)
        controller?.setDragHover(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        hoverTimer?.invalidate()
        button?.highlight(false)
        controller?.setDragHover(false)
        return DropSupport.receive(sender) { [weak self] urls in
            guard !urls.isEmpty else { return }
            self?.controller?.openInConverter(urls)
        }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        hoverTimer?.invalidate()
        button?.highlight(false)
        controller?.setDragHover(false)
        controller?.dragSessionEnded()
    }

    // MARK: NSSpringLoadingDestination

    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        if activated {
            hoverTimer?.invalidate()
            controller?.showPopover(forDrag: true)
        }
    }

    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {
        button?.highlight(draggingInfo.springLoadingHighlight != .none)
    }

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions { .enabled }
    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions { .enabled }
}
