import Foundation
import MorphKit
import Observation

/// Runs one batch of conversions and tracks its progress (main window or a menu bar quick action).
@Observable
final class BatchRunner: Identifiable {
    struct PlannedJob {
        let job: ConversionJob
        let entries: [FileEntry]
    }

    let id = UUID()
    let title: String
    let entries: [FileEntry]
    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var remaining: TimeInterval?
    private(set) var summary: BatchSummary?
    private(set) var completedCount = 0
    let jobCount: Int

    @ObservationIgnored var onFinish: ((BatchSummary) -> Void)?
    @ObservationIgnored var onOutput: ((URL, Int64, Int64) -> Void)?
    @ObservationIgnored private let queue: ConversionQueue
    @ObservationIgnored private let planned: [UUID: PlannedJob]
    @ObservationIgnored private let orderedJobs: [ConversionJob]
    @ObservationIgnored private var pending: Set<UUID>
    @ObservationIgnored private var jobFraction: [UUID: Double] = [:]
    @ObservationIgnored private var jobWeight: [UUID: Double] = [:]
    @ObservationIgnored private var outputs: [URL] = []
    @ObservationIgnored private var outputBytes: Int64 = 0
    @ObservationIgnored private var convertedOriginalBytes: Int64 = 0
    @ObservationIgnored private var countedSources = Set<UUID>()
    @ObservationIgnored private var failed = 0
    @ObservationIgnored private var cancelled = 0
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(title: String, jobs: [PlannedJob], pipeline: ConversionPipeline, maxParallel: Int?) {
        self.title = title
        self.queue = ConversionQueue(pipeline: pipeline)
        var map: [UUID: PlannedJob] = [:]
        var seen = Set<UUID>()
        var list: [FileEntry] = []
        for planned in jobs {
            map[planned.job.id] = planned
            for entry in planned.entries where seen.insert(entry.id).inserted { list.append(entry) }
            let weight = Double(max(1, planned.job.items.reduce(0) { $0 + $1.fileSize }))
            jobWeight[planned.job.id] = weight
        }
        self.planned = map
        self.orderedJobs = jobs.map(\.job)
        self.pending = Set(map.keys)
        self.entries = list
        self.jobCount = jobs.count
        let maxParallel = maxParallel
        Task { [queue] in await queue.setMaxParallel(maxParallel) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        started = Date()
        // Keep full speed when Morph is in the background (no App Nap) and stop idle sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Converting files")
        for planned in planned.values {
            for entry in planned.entries { entry.job = .queued }
        }
        let events = queue.events
        listener = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
                if self.pending.isEmpty { break }
            }
        }
        // Jobs are enqueued in list order; the queue starts them in that order.
        let ordered = orderedJobs
        Task { [queue] in await queue.enqueue(ordered) }
    }

    func cancel() {
        Task { [queue] in await queue.cancelAll() }
    }

    private func handle(_ event: ConversionEvent) {
        switch event {
        case .started(let id):
            update(id) { $0.job = .running(fraction: 0, remaining: nil) }
        case .progress(let id, let fraction, let remaining):
            jobFraction[id] = fraction
            update(id) { $0.job = .running(fraction: fraction, remaining: remaining) }
            recomputeProgress()
        case .finished(let id, let outcome):
            finish(id)
            if let url = outcome.output {
                outputs.append(url)
                outputBytes += outcome.bytes
                let source = planned[id]?.job.items.reduce(Int64(0)) { $0 + $1.fileSize } ?? 0
                // PDF pages: attribute the source size once per file, not once per page.
                let sourceIDs = Set(planned[id]?.job.items.map(\.id) ?? [])
                if !sourceIDs.isSubset(of: countedSources) {
                    convertedOriginalBytes += source
                    countedSources.formUnion(sourceIDs)
                }
                onOutput?(url, outcome.bytes, source)
            }
            update(id) { $0.job = .done(url: outcome.output, bytes: outcome.bytes, note: outcome.note) }
        case .failed(let id, let message, let suggestion, let log):
            finish(id)
            failed += 1
            update(id) { $0.job = .failed(message: message, suggestion: suggestion, log: log) }
        case .cancelled(let id):
            finish(id)
            cancelled += 1
            update(id) { $0.job = .cancelled }
        }
        if pending.isEmpty && isRunning {
            isRunning = false
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            progress = 1
            remaining = 0
            let summary = BatchSummary(converted: outputs.count, failed: failed, cancelled: cancelled,
                                       originalBytes: convertedOriginalBytes, outputBytes: outputBytes, outputs: outputs,
                                       duration: Date().timeIntervalSince(started))
            self.summary = summary
            onFinish?(summary)
        }
    }

    private func finish(_ id: UUID) {
        pending.remove(id)
        jobFraction[id] = 1
        completedCount = jobCount - pending.count
        recomputeProgress()
    }

    private func update(_ jobID: UUID, _ change: (FileEntry) -> Void) {
        planned[jobID]?.entries.forEach(change)
    }

    private func recomputeProgress() {
        let total = jobWeight.values.reduce(0, +)
        guard total > 0 else { return }
        let done = jobWeight.reduce(0.0) { $0 + $1.value * (jobFraction[$1.key] ?? 0) }
        progress = min(1, done / total)
        let elapsed = Date().timeIntervalSince(started)
        remaining = progress > 0.02 ? elapsed * (1 - progress) / progress : nil
    }
}
