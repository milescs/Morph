import Foundation
import Synchronization

/// One unit of work: usually one input file → one output file.
public struct ConversionJob: Sendable, Identifiable {
    public let id: UUID
    /// Inputs (several only when combining images into one PDF).
    public let items: [MediaItem]
    public let settings: ConversionSettings
    /// Desired output URL; collisions are resolved when committing.
    public let destination: URL
    /// 1-based page for PDF → image jobs.
    public let page: Int?

    public init(id: UUID = UUID(), items: [MediaItem], settings: ConversionSettings, destination: URL,
                page: Int? = nil) {
        self.id = id
        self.items = items
        self.settings = settings
        self.destination = destination
        self.page = page
    }

    public var item: MediaItem { items[0] }
}

public struct JobOutcome: Sendable {
    /// nil when skipped because the destination existed (collision policy "skip").
    public let output: URL?
    public let bytes: Int64
    public let note: String?
}

public enum ConversionEvent: Sendable {
    case started(jobID: UUID)
    case progress(jobID: UUID, fraction: Double, remaining: Double?)
    case finished(jobID: UUID, outcome: JobOutcome)
    case failed(jobID: UUID, message: String, suggestion: String?, log: String?)
    case cancelled(jobID: UUID)
}

/// How many jobs may run at once, based on the Mac's cores, media engines, memory and thermals.
public struct ConcurrencyPolicy: Sendable, Equatable {
    /// Weighted CPU budget (≈ performance cores).
    public var cpuBudget: Int
    /// Concurrent VideoToolbox encodes.
    public var mediaEngines: Int
    /// Bytes of working memory image jobs may use together.
    public var memoryBudget: Int

    public init(cpuBudget: Int, mediaEngines: Int, memoryBudget: Int) {
        self.cpuBudget = max(1, cpuBudget)
        self.mediaEngines = max(1, mediaEngines)
        self.memoryBudget = max(256 << 20, memoryBudget)
    }

    /// Detects this Mac's capabilities. `maxParallel` caps the CPU budget (user setting).
    public static func automatic(maxParallel: Int? = nil) -> ConcurrencyPolicy {
        let caps = SystemCapabilities.current
        var budget = caps.performanceCores
        if let maxParallel, maxParallel > 0 { budget = min(budget, maxParallel) }
        let info = ProcessInfo.processInfo
        let constrained = info.thermalState == .serious || info.thermalState == .critical || info.isLowPowerModeEnabled
        if constrained { budget = max(1, budget / 2) }
        return ConcurrencyPolicy(cpuBudget: budget,
                                 mediaEngines: constrained ? 1 : caps.videoEncodeEngines,
                                 memoryBudget: Int(caps.physicalMemory / 4))
    }

    struct Requirement {
        var cpu: Int
        var engine: Bool
        var memory: Int
    }

    func requirement(for job: ConversionJob, capabilities: FFmpegCapabilities?) -> Requirement {
        let item = job.item
        let target = job.settings.target
        if target == .pdfCombined {
            return Requirement(cpu: min(cpuBudget, 2), engine: false, memory: 512 << 20)
        }
        let isStillImageJob = (item.kind == .image || item.kind == .pdf)
            && !target.isVideoTarget && !target.isAnimatedTarget
        if isStillImageJob {
            let pixels: Int = {
                switch item.info {
                case .image(let info)?: return info.pixelCount * max(1, info.isAnimated ? min(info.frameCount, 50) : 1)
                case .pdf(let info)?: return Int(info.pageWidth * info.pageHeight * pow(job.settings.image.pdfDPI / 72, 2))
                default: return 24_000_000
                }
            }()
            // Decode + transform + encode buffers.
            let memory = min(memoryBudget, max(64 << 20, pixels * 4 * 3))
            return Requirement(cpu: 1, engine: false, memory: memory)
        }
        guard let info = item.info?.media,
              let plan = try? MediaPlanner.plan(item: item, info: info, settings: job.settings,
                                                capabilities: capabilities) else {
            return Requirement(cpu: 2, engine: false, memory: 0)
        }
        switch plan.mode {
        case .audioOnly, .frame:
            return Requirement(cpu: 1, engine: false, memory: 0)
        case .gif, .animatedWebP:
            return Requirement(cpu: min(cpuBudget, 4), engine: false, memory: 256 << 20)
        case .video:
            guard let encoder = plan.videoEncoder, encoder != .copy else {
                return Requirement(cpu: 1, engine: false, memory: 0)
            }
            if encoder.isHardware {
                // Decode is on the media engine; scaling / tone mapping use the CPU.
                return Requirement(cpu: min(cpuBudget, 2), engine: true, memory: 0)
            }
            return Requirement(cpu: cpuBudget, engine: false, memory: 0)
        }
    }
}

public struct SystemCapabilities: Sendable {
    public let performanceCores: Int
    public let physicalMemory: UInt64
    public let chipName: String
    public let videoEncodeEngines: Int

    public static let current: SystemCapabilities = {
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
        func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let chip = sysctlString("machdep.cpu.brand_string")
        let engines = chip.contains("Ultra") ? 4 : chip.contains("Max") ? 2 : 1
        return SystemCapabilities(performanceCores: max(1, pCores), physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                  chipName: chip, videoEncodeEngines: engines)
    }()
}

/// Runs jobs in list order, as many at once as the policy allows.
public actor ConversionQueue {
    private struct Running {
        let task: Task<Void, Never>
        let requirement: ConcurrencyPolicy.Requirement
    }

    private var pending: [ConversionJob] = []
    private var running: [UUID: Running] = [:]
    private var usedCPU = 0
    private var usedEngines = 0
    private var usedMemory = 0
    private var policyOverride: ConcurrencyPolicy?
    private var maxParallel: Int?
    private let pipeline: ConversionPipeline
    private let continuation: AsyncStream<ConversionEvent>.Continuation
    public nonisolated let events: AsyncStream<ConversionEvent>

    public init(pipeline: ConversionPipeline, policy: ConcurrencyPolicy? = nil) {
        self.pipeline = pipeline
        self.policyOverride = policy
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public var isIdle: Bool { pending.isEmpty && running.isEmpty }

    public func setMaxParallel(_ value: Int?) {
        maxParallel = value
        pump()
    }

    private var policy: ConcurrencyPolicy {
        policyOverride ?? .automatic(maxParallel: maxParallel)
    }

    public func enqueue(_ jobs: [ConversionJob]) {
        pending.append(contentsOf: jobs)
        pump()
    }

    public func cancel(jobID: UUID) {
        if let index = pending.firstIndex(where: { $0.id == jobID }) {
            pending.remove(at: index)
            continuation.yield(.cancelled(jobID: jobID))
        } else {
            running[jobID]?.task.cancel()
        }
    }

    public func cancelAll() {
        for job in pending { continuation.yield(.cancelled(jobID: job.id)) }
        pending.removeAll()
        for (_, run) in running { run.task.cancel() }
    }

    private func pump() {
        let policy = self.policy
        while let job = pending.first {
            var need = policy.requirement(for: job, capabilities: pipeline.ffmpeg?.capabilities)
            need.cpu = min(need.cpu, policy.cpuBudget)
            let idle = running.isEmpty
            let fitsCPU = usedCPU + need.cpu <= policy.cpuBudget
            let fitsEngine = !need.engine || usedEngines < policy.mediaEngines
            let fitsMemory = usedMemory + need.memory <= policy.memoryBudget
            // Strict order: the head waits for capacity (an idle queue always starts it).
            guard idle || (fitsCPU && fitsEngine && fitsMemory) else { break }
            pending.removeFirst()
            usedCPU += need.cpu
            usedEngines += need.engine ? 1 : 0
            usedMemory += need.memory
            start(job, need: need)
        }
    }

    private func start(_ job: ConversionJob, need: ConcurrencyPolicy.Requirement) {
        let continuation = self.continuation
        let pipeline = self.pipeline
        let id = job.id
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            continuation.yield(.started(jobID: id))
            let throttle = Mutex(Date.distantPast)
            do {
                let outcome = try await pipeline.run(job) { fraction, remaining in
                    let now = Date()
                    let emit = throttle.withLock { last -> Bool in
                        guard now.timeIntervalSince(last) >= 0.1 || fraction >= 1 else { return false }
                        last = now
                        return true
                    }
                    if emit { continuation.yield(.progress(jobID: id, fraction: fraction, remaining: remaining)) }
                }
                continuation.yield(.finished(jobID: id, outcome: outcome))
            } catch is CancellationError {
                continuation.yield(.cancelled(jobID: id))
            } catch let error as FFmpegError {
                if Task.isCancelled {
                    continuation.yield(.cancelled(jobID: id))
                } else {
                    continuation.yield(.failed(jobID: id, message: error.message, suggestion: error.suggestion,
                                               log: error.log))
                }
            } catch {
                if Task.isCancelled {
                    continuation.yield(.cancelled(jobID: id))
                } else {
                    let explanation = FriendlyErrors.explain(error)
                    continuation.yield(.failed(jobID: id, message: explanation.message,
                                               suggestion: explanation.suggestion, log: nil))
                }
            }
            await self?.jobDidFinish(id, need: need)
        }
        running[id] = Running(task: task, requirement: need)
    }

    private func jobDidFinish(_ id: UUID, need: ConcurrencyPolicy.Requirement) {
        guard running.removeValue(forKey: id) != nil else { return }
        usedCPU -= need.cpu
        usedEngines -= need.engine ? 1 : 0
        usedMemory -= need.memory
        pump()
    }
}
