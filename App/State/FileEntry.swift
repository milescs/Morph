import Foundation
import MorphKit
import Observation

/// A file in the list, with its probe / estimate / job state.
@Observable
final class FileEntry: Identifiable {
    enum ProbeState: Equatable {
        case pending
        case ready
        case failed(String)
    }

    enum JobState: Equatable {
        case idle
        case queued
        case running(fraction: Double, remaining: Double?)
        case done(url: URL?, bytes: Int64, note: String?)
        case failed(message: String, log: String?)
        case cancelled

        var isActive: Bool {
            switch self {
            case .queued, .running: true
            default: false
            }
        }

        var fraction: Double {
            switch self {
            case .running(let f, _): f
            case .done, .failed, .cancelled: 1
            default: 0
            }
        }
    }

    let id: UUID
    var item: MediaItem
    var probe: ProbeState = .pending
    var quickEstimate: SizeEstimate?
    var refinedEstimate: SizeEstimate?
    var isRefining = false
    var estimateError: String?
    var job: JobState = .idle

    init(item: MediaItem) {
        self.id = item.id
        self.item = item
    }

    var kind: MediaKind { item.kind }
    var estimate: SizeEstimate? { refinedEstimate ?? quickEstimate }
    var isReady: Bool { probe == .ready }

    var isFailed: Bool {
        if case .failed = probe { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = probe { return message }
        return nil
    }
}

/// Output of a finished conversion (shown in the menu bar's Recents).
struct RecentOutput: Identifiable, Hashable, Codable {
    var id = UUID()
    let url: URL
    let bytes: Int64
    let originalBytes: Int64
    let date: Date
}

/// Summary of the last finished batch.
struct BatchSummary: Equatable {
    var converted: Int
    var failed: Int
    var cancelled: Int
    var originalBytes: Int64
    var outputBytes: Int64
    var outputs: [URL]
    var duration: TimeInterval

    var savedBytes: Int64 { originalBytes - outputBytes }
}
