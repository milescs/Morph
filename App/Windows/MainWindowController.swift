import AppKit
import MorphKit
import SwiftUI
import UniformTypeIdentifiers

/// The converter window. AppKit owns it so the status item and Services can always show it,
/// and so the whole window can act as one drop target.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSDraggingDestination {
    static let shared = MainWindowController()

    private let model = AppModel.shared

    private init() {
        let hosting = NSHostingController(rootView: MainView().environment(AppModel.shared).environment(SettingsStore.shared))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "Morph"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("MorphMainWindow")
        super.init(window: window)
        window.delegate = self
        window.registerForDraggedTypes(DropSupport.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        if !SettingsStore.shared.showInDock {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    // MARK: Actions

    func convert() {
        show()
        model.convert(window: window)
    }

    func chooseFiles() {
        show()
        let panel = NSOpenPanel()
        panel.title = "Add Files"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = FileFormat.supportedContentTypes + [.folder]
        guard let window else { return }
        panel.beginSheetModal(for: window) { [model] response in
            if response == .OK { model.add(urls: panel.urls) }
        }
    }

    func chooseFolder() {
        show()
        let panel = NSOpenPanel()
        panel.title = "Add Folder"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [model] response in
            if response == .OK { model.add(urls: panel.urls) }
        }
    }

    // MARK: Drag & drop (the window delegate receives these for the registered window)

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard model.phase != .converting, DropSupport.canAccept(sender) else { return [] }
        model.isDropTargeted = true
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        model.phase != .converting && DropSupport.canAccept(sender) ? .copy : []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        model.isDropTargeted = false
    }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        model.isDropTargeted = false
        return DropSupport.receive(sender) { [model] urls in model.add(urls: urls) }
    }

    func draggingEnded(_ sender: any NSDraggingInfo) {
        model.isDropTargeted = false
    }
}

/// Reads file URLs, file promises (Photos, Mail) and raw image data from drags.
enum DropSupport {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                                                            NSPasteboard.PasteboardType(UTType.heic.identifier)]

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + imageTypes
    }

    static func canAccept(_ info: any NSDraggingInfo) -> Bool {
        let board = info.draggingPasteboard
        return board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || board.availableType(from: imageTypes) != nil
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Calls `handler` on the main actor with the received file URLs.
    @discardableResult
    static func receive(_ info: any NSDraggingInfo, handler: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let board = info.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            handler(urls)
            return true
        }
        if let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "Morph Dropped/\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
            let collector = PromiseCollector(expected: expected, handler: handler)
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { url, error in
                    collector.add(error == nil ? url : nil)
                }
            }
            return true
        }
        if let type = board.availableType(from: imageTypes), let data = board.data(forType: type) {
            let uti = UTType(type.rawValue) ?? .png
            handler([])
            AppModel.shared.add(imageData: data, type: uti == .tiff ? .png : uti)
            return true
        }
        return false
    }
}

/// Gathers asynchronously delivered promised files, then hands them over once.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let handler: @MainActor ([URL]) -> Void

    init(expected: Int, handler: @escaping @MainActor ([URL]) -> Void) {
        self.remaining = expected
        self.handler = handler
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let done = remaining <= 0
        let collected = urls
        lock.unlock()
        if done {
            let handler = self.handler
            Task { @MainActor in handler(collected) }
        }
    }
}
