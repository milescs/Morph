import Foundation
import Observation
import Sparkle

/// Automatic updates with Sparkle. Each GitHub release publishes a signed appcast
/// (releases/latest/download/appcast.xml); Morph checks it about once a day.
@Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, change in
            let value = change.newValue ?? false
            Task { @MainActor in Updater.shared.canCheckForUpdates = value }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
