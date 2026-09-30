import Foundation
import MorphKit
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Called when Dock / menu bar visibility changes.
    @ObservationIgnored var onPresenceChange: (() -> Void)?

    var showInDock: Bool {
        didSet {
            if !showInDock && !showInMenuBar { showInMenuBar = true }
            defaults.set(showInDock, forKey: "showInDock")
            onPresenceChange?()
        }
    }

    var showInMenuBar: Bool {
        didSet {
            if !showInMenuBar && !showInDock { showInDock = true }
            defaults.set(showInMenuBar, forKey: "showInMenuBar")
            onPresenceChange?()
        }
    }

    var alwaysSaveNextToOriginals: Bool { didSet { defaults.set(alwaysSaveNextToOriginals, forKey: "alwaysSaveNextToOriginals") } }
    var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: "filenameTemplate") } }
    var sameFormatTemplate: String { didSet { defaults.set(sameFormatTemplate, forKey: "sameFormatTemplate") } }
    var collisionPolicy: CollisionPolicy { didSet { defaults.set(collisionPolicy.rawValue, forKey: "collisionPolicy") } }
    var preserveFileDates: Bool { didSet { defaults.set(preserveFileDates, forKey: "preserveFileDates") } }
    /// 0 = automatic.
    var maxParallel: Int { didSet { defaults.set(maxParallel, forKey: "maxParallel") } }
    var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone") } }
    var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: "revealWhenDone") } }
    var proMode: Bool { didSet { defaults.set(proMode, forKey: "proMode") } }
    var quickActions: [QuickAction] {
        didSet { defaults.set(quickActions.map(\.rawValue), forKey: "quickActions") }
    }
    /// Quick actions from the menu bar skip the save panel.
    var quickActionsSaveNextToOriginals: Bool {
        didSet { defaults.set(quickActionsSaveNextToOriginals, forKey: "quickActionsSaveNextToOriginals") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Morph: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            "showInDock": true, "showInMenuBar": true, "alwaysSaveNextToOriginals": false,
            "filenameTemplate": "{name}", "sameFormatTemplate": "{name}-compressed",
            "collisionPolicy": CollisionPolicy.keepBoth.rawValue, "preserveFileDates": false, "maxParallel": 0,
            "notifyWhenDone": true, "revealWhenDone": false, "proMode": false,
            "quickActions": QuickAction.defaults.map(\.rawValue), "quickActionsSaveNextToOriginals": false,
        ])
        showInDock = defaults.bool(forKey: "showInDock")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        alwaysSaveNextToOriginals = defaults.bool(forKey: "alwaysSaveNextToOriginals")
        filenameTemplate = defaults.string(forKey: "filenameTemplate") ?? "{name}"
        sameFormatTemplate = defaults.string(forKey: "sameFormatTemplate") ?? "{name}-compressed"
        collisionPolicy = CollisionPolicy(rawValue: defaults.string(forKey: "collisionPolicy") ?? "") ?? .keepBoth
        preserveFileDates = defaults.bool(forKey: "preserveFileDates")
        maxParallel = defaults.integer(forKey: "maxParallel")
        notifyWhenDone = defaults.bool(forKey: "notifyWhenDone")
        revealWhenDone = defaults.bool(forKey: "revealWhenDone")
        proMode = defaults.bool(forKey: "proMode")
        quickActions = (defaults.stringArray(forKey: "quickActions") ?? []).compactMap(QuickAction.init(rawValue:))
        quickActionsSaveNextToOriginals = defaults.bool(forKey: "quickActionsSaveNextToOriginals")
    }

    // MARK: Remembered conversion settings

    func conversionSettings(for kind: MediaKind) -> ConversionSettings {
        if let data = defaults.data(forKey: "settings.\(kind.rawValue)"),
           let settings = try? JSONDecoder().decode(ConversionSettings.self, from: data) {
            return settings
        }
        return ConversionSettings(target: FormatRegistry.defaultTarget(for: kind))
    }

    func remember(_ settings: ConversionSettings, for kind: MediaKind) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "settings.\(kind.rawValue)")
        }
    }

    func resetConversionSettings() {
        for kind in MediaKind.allCases { defaults.removeObject(forKey: "settings.\(kind.rawValue)") }
    }

    func outputPlanner(destination: DestinationMode) -> OutputPlanner {
        OutputPlanner(destination: destination,
                      template: filenameTemplate.contains("{name}") ? filenameTemplate : "{name}",
                      sameFormatTemplate: sameFormatTemplate.contains("{name}") ? sameFormatTemplate : "{name}-compressed")
    }
}
