import Foundation
import MorphKit
import Observation

/// Destination presets ("Email", "Discord" …). The bundled list is refreshed from GitHub at most
/// once a day, so upload limits can change without a new release. Only a small JSON file is
/// downloaded; nothing about you or your files is sent.
@Observable
final class DestinationStore {
    static let shared = DestinationStore()
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/milescs/Morph/main/App/Resources/Destinations.json")!

    private(set) var catalog: DestinationCatalog

    var destinations: [Destination] { catalog.destinations }

    func destination(id: String) -> Destination? { catalog.destination(id: id) }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var refreshing = false

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Morph/Destinations.json")
    }

    private init() {
        let bundled = Bundle.main.url(forResource: "Destinations", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? DestinationCatalog.decode($0) }
            ?? DestinationCatalog(updated: "2026-01-01", destinations: [])
        let cached = (try? Data(contentsOf: Self.cacheURL)).flatMap { try? DestinationCatalog.decode($0) }
        catalog = Self.newer(cached, than: bundled)
    }

    /// Prefers the catalog whose limits were reviewed most recently.
    private static func newer(_ candidate: DestinationCatalog?, than current: DestinationCatalog) -> DestinationCatalog {
        guard let candidate, !candidate.destinations.isEmpty, candidate.updated >= current.updated else { return current }
        return candidate
    }

    func refreshIfNeeded() {
        guard SettingsStore.shared.updateDestinations, !refreshing else { return }
        let last = defaults.object(forKey: "destinationsCheckedAt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            var request = URLRequest(url: Self.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Morph", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let remote = try? DestinationCatalog.decode(data) else { return }
            defaults.set(Date(), forKey: "destinationsCheckedAt")
            let updated = Self.newer(remote, than: catalog)
            guard updated != catalog else { return }
            catalog = updated
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }
}
