import AppKit
import MorphKit

/// Requests from the Finder Quick Actions ("Compress with Morph", "Convert with Morph").
///
/// The sandboxed extension writes the selected paths to the shared app-group container and opens
/// `morph://request/<id>`. Only requests found in that container are acted on, so a web page
/// opening a morph:// link can't make Morph do anything.
enum ExtensionRequests {
    static let groupIdentifier = "NWTRA7934U.com.milessmith.Morph"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "Requests", directoryHint: .isDirectory)
    }

    static func handle(_ url: URL) {
        guard url.scheme == "morph", url.host() == "request", let id = url.pathComponents.last,
              UUID(uuidString: id) != nil, let directory else { return }
        let file = directory.appending(path: "\(id).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = payload["action"] as? String,
              let paths = payload["paths"] as? [String], !paths.isEmpty else { return }
        let urls = paths.map { URL(filePath: $0) }
        AppDelegate.noteBackgroundRequest()
        switch action {
        case "compress":
            AppModel.shared.runQuickAction(.compress, urls: urls, forceNextToOriginals: true)
        default:
            AppModel.shared.add(urls: urls)
            MainWindowController.shared.show()
        }
        removeStaleRequests()
    }

    /// Requests Morph never received (e.g. it was quitting) are dropped after a day.
    static func removeStaleRequests() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > 24 * 3600 { try? FileManager.default.removeItem(at: file) }
        }
    }
}
