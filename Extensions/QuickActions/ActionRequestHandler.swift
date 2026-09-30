import AppKit
import UniformTypeIdentifiers

/// Finder Quick Action ("Compress with Morph" / "Convert with Morph"). The extension is sandboxed,
/// so it only hands the selected files to Morph, which does the work and shows progress in the menu bar.
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    static let groupIdentifier = "NWTRA7934U.com.milessmith.Morph"

    func beginRequest(with context: NSExtensionContext) {
        let action = Bundle.main.object(forInfoDictionaryKey: "MorphAction") as? String ?? "convert"
        // NSExtensionContext and NSItemProvider aren't Sendable, but each is only used by this one task.
        nonisolated(unsafe) let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        nonisolated(unsafe) let context = context
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            if !urls.isEmpty { Self.send(action: action, urls: urls) }
            context.completeRequest(returningItems: nil)
        }
    }

    static func fileURL(from provider: NSItemProvider) async -> URL? {
        let types = [UTType.fileURL.identifier] + provider.registeredTypeIdentifiers
        for type in types where provider.hasItemConformingToTypeIdentifier(type) {
            guard let item = try? await provider.loadItem(forTypeIdentifier: type) else { continue }
            if let url = item as? URL, url.isFileURL { return url }
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url
            }
        }
        return nil
    }

    static func send(action: String, urls: [URL]) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        else { return }
        let directory = container.appending(path: "Requests", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let payload: [String: Any] = ["action": action, "paths": urls.map(\.path)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              (try? data.write(to: directory.appending(path: "\(id).json"), options: .atomic)) != nil,
              let url = URL(string: "morph://request/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
