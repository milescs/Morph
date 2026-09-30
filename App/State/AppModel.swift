import AppKit
import MorphKit
import Observation
import UniformTypeIdentifiers

/// Central state: the file list, per-kind settings, estimates and conversions.
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable { case editing, converting, finished }

    let settings = SettingsStore.shared
    private(set) var entries: [FileEntry] = []
    private(set) var conversionSettings: [MediaKind: ConversionSettings] = [:]
    /// The destination preset the current settings came from ("Fit for Discord"), until they're edited.
    private(set) var activeDestination: Destination?
    var selectedKind: MediaKind = .image
    var selection: Set<UUID> = []
    var isDropTargeted = false
    private(set) var phase: Phase = .editing
    private(set) var batch: BatchRunner?
    private(set) var quickBatches: [BatchRunner] = []
    private(set) var recents: [RecentOutput] = []
    /// Short-lived message shown at the top of the list (e.g. skipped files).
    var toast: String?
    private(set) var tools: FFmpegTools?
    private(set) var capabilities: FFmpegCapabilities?
    private(set) var ffmpegProblem: String?
    private(set) var isScanning = false

    @ObservationIgnored private(set) var engine: FFmpegEngine?
    @ObservationIgnored let cache = EstimateCache()
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private init() {
        for kind in MediaKind.allCases {
            conversionSettings[kind] = settings.conversionSettings(for: kind)
        }
        if let id = UserDefaults.standard.string(forKey: "activeDestination") {
            activeDestination = DestinationStore.shared.destination(id: id)
        }
        loadRecents()
        setupTask = Task { await setUpEngines() }
        Task.detached(priority: .background) { RustCodecs.warmUpFonts() }
    }

    private func setUpEngines() async {
        guard let tools = FFmpegTools.locate() else {
            ffmpegProblem = "FFmpeg wasn't found, so videos and audio can't be converted. Run “make deps” to build it."
            return
        }
        self.tools = tools
        do {
            let caps = try await FFmpegCapabilities.load(for: tools)
            capabilities = caps
            let engine = FFmpegEngine(tools: tools, capabilities: caps)
            self.engine = engine
            ThumbnailService.shared.ffmpeg = engine
        } catch {
            ffmpegProblem = "FFmpeg couldn't start: \(error.localizedDescription)"
        }
    }

    // MARK: - Files

    var isEmpty: Bool { entries.isEmpty }

    var kindsPresent: [MediaKind] {
        Array(Set(entries.map(\.kind))).sorted()
    }

    func entries(of kind: MediaKind) -> [FileEntry] {
        entries.filter { $0.kind == kind }
    }

    /// Adds files and folders (recursively), then reads their details.
    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if phase == .finished { prepareForNextBatch() }
        isScanning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { FileScanner.scan(urls) }.value
            isScanning = false
            let existing = Set(entries.map { $0.item.url.standardizedFileURL.path })
            let fresh = result.items.filter { !existing.contains($0.url.standardizedFileURL.path) }.map(FileEntry.init)
            if result.skipped > 0 {
                show(toast: result.skipped == 1 ? "Skipped 1 unsupported file" : "Skipped \(result.skipped) unsupported files")
            } else if fresh.isEmpty && !result.items.isEmpty {
                show(toast: "Those files are already in the list")
            }
            guard !fresh.isEmpty else { return }
            let wasEmpty = entries.isEmpty
            entries.append(contentsOf: fresh)
            if wasEmpty || !kindsPresent.contains(selectedKind) { selectedKind = fresh[0].kind }
            await probe(fresh)
        }
    }

    /// Adds image data (paste / drag from a browser) by saving it to a temporary file.
    func add(imageData data: Data, type: UTType) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Morph Pasted", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let url = dir.appending(path: "Pasted Image \(stamp)").appendingPathExtension(type.preferredFilenameExtension ?? "png")
        do {
            try data.write(to: url)
            add(urls: [url])
        } catch {
            show(toast: "Couldn't paste the image")
        }
    }

    func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls: urls)
            return
        }
        for type in [UTType.png, .tiff, .jpeg, .heic] {
            if let data = board.data(forType: NSPasteboard.PasteboardType(type.identifier)) {
                add(imageData: data, type: type == .tiff ? .png : type)
                return
            }
        }
        show(toast: "The clipboard has no files or images")
    }

    private func probe(_ list: [FileEntry]) async {
        await setupTask?.value
        let tools = self.tools
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        let results = await Self.forEachLimited(list.map(\.item), width: 8) { item in
            try await MediaProbe.info(for: item, tools: tools)
        } onResult: { id, result in
            guard let entry = byID[id] else { return }
            switch result {
            case .success(let info):
                entry.item.info = info
                entry.probe = .ready
            case .failure(let error):
                entry.probe = .failed(FriendlyErrors.explain(error).message)
            }
        }
        _ = results
        normalizeTargets()
        recomputeEstimates()
    }

    /// Runs `work` for each item with at most `width` in flight; results are delivered on the main actor.
    @discardableResult
    static func forEachLimited<T: Sendable>(
        _ items: [MediaItem], width: Int,
        work: @escaping @Sendable (MediaItem) async throws -> T,
        onResult: (UUID, Result<T, Error>) -> Void
    ) async -> Int {
        var index = 0
        var completed = 0
        await withTaskGroup(of: (UUID, Result<T, Error>).self) { group in
            func launch(_ item: MediaItem) {
                group.addTask {
                    do { return (item.id, .success(try await work(item))) } catch { return (item.id, .failure(error)) }
                }
            }
            while index < min(width, items.count) {
                launch(items[index])
                index += 1
            }
            while let (id, result) = await group.next() {
                onResult(id, result)
                completed += 1
                if Task.isCancelled { group.cancelAll(); continue }
                if index < items.count {
                    launch(items[index])
                    index += 1
                }
            }
        }
        return completed
    }

    func remove(_ ids: Set<UUID>) {
        guard phase != .converting else { return }
        entries.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if !kindsPresent.contains(selectedKind), let first = kindsPresent.first { selectedKind = first }
        if entries.isEmpty { phase = .editing; batch = nil }
        normalizeTargets()
        recomputeEstimates()
    }

    func removeAll() {
        guard phase != .converting else { return }
        entries.removeAll()
        selection.removeAll()
        phase = .editing
        batch = nil
        Task { await cache.removeAll() }
    }

    func move(kind: MediaKind, from source: IndexSet, to destination: Int) {
        guard phase != .converting else { return }
        var group = entries(of: kind)
        group.move(fromOffsets: source, toOffset: destination)
        var iterator = group.makeIterator()
        entries = entries.map { $0.kind == kind ? iterator.next()! : $0 }
    }

    func removeFailed() {
        remove(Set(entries.filter(\.isFailed).map(\.id)))
    }

    // MARK: - Settings

    func settings(for kind: MediaKind) -> ConversionSettings {
        conversionSettings[kind] ?? ConversionSettings(target: FormatRegistry.defaultTarget(for: kind))
    }

    func targets(for kind: MediaKind) -> [OutputFormat] {
        FormatRegistry.targets(for: kind, items: entries(of: kind).map(\.item), capabilities: capabilities)
    }

    func update(_ kind: MediaKind, _ change: (inout ConversionSettings) -> Void) {
        var value = settings(for: kind)
        change(&value)
        guard value != conversionSettings[kind] else { return }
        conversionSettings[kind] = value
        settings.remember(value, for: kind)
        setActiveDestination(nil)
        recomputeEstimates(kinds: [kind])
    }

    func apply(preset: Preset) {
        update(preset.kind) { $0 = preset.settings }
        selectedKind = preset.kind
    }

    /// Sets every kind the destination covers to what fits there; other kinds keep their settings.
    func apply(destination: Destination?) {
        guard let destination else {
            setActiveDestination(nil)
            return
        }
        for kind in MediaKind.allCases {
            guard let fitted = destination.settings(for: kind, keepingPrivacyFrom: settings(for: kind)) else { continue }
            conversionSettings[kind] = fitted
            settings.remember(fitted, for: kind)
        }
        setActiveDestination(destination)
        normalizeTargets()
        recomputeEstimates()
    }

    private func setActiveDestination(_ destination: Destination?) {
        guard activeDestination?.id != destination?.id else { return }
        activeDestination = destination
        UserDefaults.standard.set(destination?.id, forKey: "activeDestination")
    }

    /// "12 images → JPEG", one entry per kind in the list (for the bar above Convert).
    struct KindSummary: Identifiable {
        let kind: MediaKind
        let count: Int
        let target: String
        var id: MediaKind { kind }

        var noun: String {
            switch kind {
            case .image: count == 1 ? "1 image" : "\(count) images"
            case .video: count == 1 ? "1 video" : "\(count) videos"
            case .audio: count == 1 ? "1 audio file" : "\(count) audio files"
            case .pdf: count == 1 ? "1 PDF" : "\(count) PDFs"
            }
        }
    }

    var kindSummaries: [KindSummary] {
        kindsPresent.compactMap { kind in
            let count = entries(of: kind).filter(\.isReady).count
            return count == 0 ? nil : KindSummary(kind: kind, count: count, target: targetLabel(for: kind))
        }
    }

    func targetLabel(for kind: MediaKind) -> String {
        let current = settings(for: kind)
        var label: String = switch current.target {
        case .original: kind == .pdf ? "smaller PDF" : "smaller, same format"
        case .auto: "Auto"
        case .pdfCombined: "one PDF"
        case .mp4H264, .movH264: current.target.displayName
        case let target where target.isVideoTarget: "\(target.displayName) \(target.detail)"
        case .gifAnimated: "animated GIF"
        case .webpAnimated: "animated WebP"
        case .frameJPEG, .framePNG: "\(current.target.displayName) frame"
        case let target: target.displayName
        }
        // With a destination the limit is implied ("Fit for Discord").
        if activeDestination == nil, let limit = sizeLimit(for: kind) { label += " ≤ \(Formatters.bytes(limit))" }
        return label
    }

    /// Keeps each group's target valid for its current files.
    private func normalizeTargets() {
        for kind in kindsPresent {
            let available = targets(for: kind)
            guard !available.isEmpty else { continue }
            let current = settings(for: kind).target
            if !available.contains(current) {
                let fallback = available.contains(FormatRegistry.defaultTarget(for: kind))
                    ? FormatRegistry.defaultTarget(for: kind) : available.first { $0 != .original } ?? available[0]
                conversionSettings[kind]?.target = fallback
            }
        }
    }

    // MARK: - Estimates

    struct Totals {
        var count = 0
        var originalBytes: Int64 = 0
        var estimatedBytes: Int64 = 0
        var isApproximate = false
        var isPending = false
        var hasEstimate = false
    }

    func totals(for kind: MediaKind? = nil) -> Totals {
        var totals = Totals()
        let list = kind.map(entries(of:)) ?? entries
        for entry in list where !entry.isFailed {
            totals.count += 1
            totals.originalBytes += entry.item.fileSize
            if let estimate = entry.estimate {
                totals.estimatedBytes += estimate.bytes
                totals.hasEstimate = true
                if !estimate.isExact { totals.isApproximate = true }
            } else {
                totals.isPending = true
            }
            if entry.isRefining { totals.isPending = true }
        }
        // Combined PDF: one output for the whole group.
        if let kind, settings(for: kind).target == .pdfCombined { totals.isApproximate = true }
        return totals
    }

    func recomputeEstimates(kinds: [MediaKind]? = nil) {
        let kinds = kinds ?? kindsPresent
        for kind in kinds {
            let current = settings(for: kind)
            for entry in entries(of: kind) where entry.isReady {
                let quick = SizeEstimator.quickEstimate(item: entry.item, settings: current, capabilities: capabilities)
                // Keep the previous refined number (scaled) while the new one is computed, to avoid jumps.
                if let old = entry.refinedEstimate, let oldQuick = entry.quickEstimate, oldQuick.bytes > 0,
                   let quick {
                    let scaled = Double(old.bytes) * Double(quick.bytes) / Double(oldQuick.bytes)
                    entry.refinedEstimate = SizeEstimate(bytes: Int64(scaled), isExact: false)
                }
                entry.quickEstimate = quick
                entry.estimateError = nil
            }
        }
        scheduleRefinement()
    }

    private func scheduleRefinement() {
        refineTask?.cancel()
        refineTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await refineEstimates()
        }
    }

    /// Replaces heuristics with real encodes (images) or samples (media), then extrapolates.
    private func refineEstimates() async {
        guard phase != .converting else { return }
        // The user is waiting for these numbers: don't let App Nap throttle the work.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Estimating output sizes")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let estimator = SizeEstimator(cache: cache, ffmpeg: engine)
        for kind in kindsPresent {
            guard !Task.isCancelled else { return }
            let current = settings(for: kind)
            let candidates = entries(of: kind).filter {
                $0.isReady && SizeEstimator.needsRefinement(item: $0.item, settings: current, capabilities: capabilities)
            }
            guard !candidates.isEmpty else { continue }
            // Selected rows first, then list order; big batches refine a sample and extrapolate.
            let prioritized = candidates.filter { selection.contains($0.id) } + candidates.filter { !selection.contains($0.id) }
            let isStill = kind == .image || kind == .pdf
            let budget = isStill ? 40 : 4
            let chosen = Array(prioritized.prefix(budget))
            let width = isStill ? max(2, SystemCapabilities.current.performanceCores / 2) : 2
            for entry in chosen { entry.isRefining = true }

            let byID = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0) })
            await Self.forEachLimited(chosen.map(\.item), width: width) { item in
                try await estimator.refined(item: item, settings: current)
            } onResult: { id, result in
                guard let entry = byID[id] else { return }
                entry.isRefining = false
                // Discard results for settings that changed meanwhile.
                guard settings(for: kind) == current else { return }
                switch result {
                case .success(let estimate):
                    entry.refinedEstimate = estimate
                case .failure(let error) where !(error is CancellationError):
                    entry.estimateError = FriendlyErrors.explain(error).message
                default:
                    break
                }
            }
            for entry in chosen { entry.isRefining = false }
            guard settings(for: kind) == current, !Task.isCancelled else { return }

            // Extrapolate refined/quick ratio to the rest of the group.
            let measured = chosen.compactMap { e -> (Double, Double)? in
                guard let r = e.refinedEstimate, let q = e.quickEstimate, q.bytes > 0 else { return nil }
                return (Double(r.bytes), Double(q.bytes))
            }
            let ratio = measured.isEmpty ? 1 : measured.reduce(0) { $0 + $1.0 } / max(1, measured.reduce(0) { $0 + $1.1 })
            for entry in candidates.dropFirst(budget) {
                if let quick = entry.quickEstimate {
                    entry.refinedEstimate = SizeEstimate(bytes: Int64(Double(quick.bytes) * ratio), isExact: false)
                }
            }
        }
    }

    // MARK: - Conversion

    var canConvert: Bool {
        phase != .converting && entries.contains { $0.isReady } && entries.allSatisfy { $0.probe != .pending }
    }

    var outputCount: Int {
        var count = 0
        for kind in kindsPresent {
            let current = settings(for: kind)
            let ready = entries(of: kind).filter(\.isReady)
            if current.target == .pdfCombined {
                count += ready.isEmpty ? 0 : 1
            } else {
                for entry in ready {
                    count += outputCount(for: entry, settings: current)
                }
            }
        }
        return count
    }

    /// Asks where to save (defaulting to the originals' folder), then starts converting.
    func convert(window: NSWindow?) {
        guard canConvert else { return }
        Task {
            guard let destination = await chooseDestination(for: entries.filter(\.isReady), settingsFor: settings(for:),
                                                            window: window) else { return }
            startMainBatch(destination: destination)
        }
    }

    func chooseDestination(for list: [FileEntry], settingsFor: (MediaKind) -> ConversionSettings,
                           forceAsk: Bool = false, window: NSWindow?) async -> DestinationChoice? {
        guard let first = list.first else { return nil }
        if settings.alwaysSaveNextToOriginals && !forceAsk { return .nextToOriginals }
        let folders = Set(list.map { $0.item.url.deletingLastPathComponent().standardizedFileURL })
        var outputs = 0
        var combinedKinds = Set<MediaKind>()
        for entry in list {
            let current = settingsFor(entry.kind)
            if current.target == .pdfCombined {
                if combinedKinds.insert(entry.kind).inserted { outputs += 1 }
            } else {
                outputs += outputCount(for: entry, settings: current)
            }
        }
        if outputs == 1 {
            let current = settingsFor(first.kind)
            let ext = FormatRegistry.outputExtension(for: first.item, settings: current, capabilities: capabilities)
            let planner = settings.outputPlanner(destination: .nextToOriginal)
            let suggested = current.target == .pdfCombined
                ? first.item.baseName + ".pdf" : planner.url(for: first.item, fileExtension: ext).lastPathComponent
            guard let url = await SavePanels.chooseFile(suggestedName: suggested,
                                                        directory: first.item.url.deletingLastPathComponent(),
                                                        fileExtension: ext, window: window) else { return nil }
            return .file(url)
        }
        return await SavePanels.chooseFolder(directory: first.item.url.deletingLastPathComponent(),
                                             sourcesSpanFolders: folders.count > 1, fileCount: outputs, window: window)
    }

    private func outputCount(for entry: FileEntry, settings current: ConversionSettings) -> Int {
        if current.target != .pdfCombined, let pdf = entry.item.info?.pdf,
           ConversionPipeline.route(for: entry.item, target: current.target) == .image {
            return current.image.pdfPages.pages(count: pdf.pageCount).count
        }
        return 1
    }

    /// Builds jobs in list order.
    func planJobs(for list: [FileEntry], settingsFor: (MediaKind) -> ConversionSettings?,
                  destination: DestinationChoice) -> [BatchRunner.PlannedJob] {
        let mode: DestinationMode = switch destination {
        case .nextToOriginals: .nextToOriginal
        case .folder(let url): .folder(url)
        case .file(let url): .folder(url.deletingLastPathComponent())
        }
        let planner = settings.outputPlanner(destination: mode)
        var jobs: [BatchRunner.PlannedJob] = []
        var combined: [MediaKind: [FileEntry]] = [:]

        for entry in list where entry.isReady {
            guard let current = settingsFor(entry.kind) else { continue }
            if current.target == .pdfCombined {
                combined[entry.kind, default: []].append(entry)
                continue
            }
            let ext = FormatRegistry.outputExtension(for: entry.item, settings: current, capabilities: capabilities)
            if case .file(let url) = destination {
                if let pdf = entry.item.info?.pdf, outputCount(for: entry, settings: current) == 1 {
                    let page = current.image.pdfPages.pages(count: pdf.pageCount).first ?? 1
                    jobs.append(.init(job: ConversionJob(items: [entry.item], settings: current, destination: url,
                                                         page: page), entries: [entry]))
                } else {
                    jobs.append(.init(job: ConversionJob(items: [entry.item], settings: current, destination: url),
                                      entries: [entry]))
                }
                continue
            }
            if let pdf = entry.item.info?.pdf, ConversionPipeline.route(for: entry.item, target: current.target) == .image {
                let pages = current.image.pdfPages.pages(count: pdf.pageCount)
                for page in pages {
                    let suffix = pages.count > 1 ? "-\(page)" : nil
                    jobs.append(.init(job: ConversionJob(items: [entry.item], settings: current,
                                                         destination: planner.url(for: entry.item, fileExtension: ext, suffix: suffix),
                                                         page: page), entries: [entry]))
                }
            } else {
                jobs.append(.init(job: ConversionJob(items: [entry.item], settings: current,
                                                     destination: planner.url(for: entry.item, fileExtension: ext)),
                                  entries: [entry]))
            }
        }
        for (kind, group) in combined.sorted(by: { $0.key < $1.key }) {
            guard let current = settingsFor(kind) else { continue }
            let url: URL
            if case .file(let exact) = destination {
                url = exact
            } else {
                let name = group.count == 1 ? group[0].item.baseName : "\(group[0].item.baseName) and \(group.count - 1) more"
                url = planner.combinedURL(items: group.map(\.item), fileExtension: "pdf", name: name)
            }
            jobs.append(.init(job: ConversionJob(items: group.map(\.item), settings: current, destination: url),
                              entries: group))
        }
        return jobs
    }

    private func pipeline(for destination: DestinationChoice) -> ConversionPipeline {
        // A file the user confirmed in the Save panel may replace an existing one.
        let policy: CollisionPolicy = if case .file = destination { .replace } else { settings.collisionPolicy }
        return ConversionPipeline(ffmpeg: engine, cache: cache, collisionPolicy: policy,
                                  preserveFileDates: settings.preserveFileDates)
    }

    private func startMainBatch(destination: DestinationChoice) {
        refineTask?.cancel()
        let jobs = planJobs(for: entries.filter(\.isReady), settingsFor: { self.settings(for: $0) },
                            destination: destination)
        guard !jobs.isEmpty else { return }
        let runner = BatchRunner(title: "Converting", jobs: jobs, pipeline: pipeline(for: destination),
                                 maxParallel: settings.maxParallel > 0 ? settings.maxParallel : nil)
        runner.onOutput = { [weak self] url, bytes, original in self?.addRecent(url: url, bytes: bytes, original: original) }
        runner.onFinish = { [weak self] summary in self?.mainBatchFinished(summary) }
        batch = runner
        phase = .converting
        SystemFeedback.showDockProgress(0)
        runner.start()
        observeDockProgress(runner)
    }

    private func observeDockProgress(_ runner: BatchRunner) {
        withObservationTracking {
            _ = runner.progress
        } onChange: { [weak self, weak runner] in
            Task { @MainActor in
                guard let self, let runner, runner.isRunning else { return }
                SystemFeedback.showDockProgress(runner.progress)
                self.observeDockProgress(runner)
            }
        }
    }

    private func mainBatchFinished(_ summary: BatchSummary) {
        phase = .finished
        SystemFeedback.showDockProgress(nil)
        if !NSApp.isActive && settings.notifyWhenDone { SystemFeedback.notifyFinished(summary) }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        if settings.revealWhenDone && !summary.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(summary.outputs)
        }
    }

    func cancelConversion() {
        batch?.cancel()
    }

    /// After a batch: keep the files, reset their status so they can be converted again.
    func prepareForNextBatch() {
        for entry in entries { entry.job = .idle }
        phase = .editing
        batch = nil
    }

    func revealOutputs() {
        guard let outputs = batch?.summary?.outputs, !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    // MARK: - Quick actions (menu bar, Finder, Shortcuts)

    func runQuickAction(_ action: QuickAction, urls: [URL], forceNextToOriginals: Bool = false) {
        Task {
            do {
                _ = try await convertInBackground(urls: urls, title: action.title, forceNextToOriginals: forceNextToOriginals) {
                    action.settings(for: $0, base: self.settings(for: $0))
                }
            } catch let error as BackgroundConversionError {
                show(toast: error.message)
            } catch {
                show(toast: FriendlyErrors.explain(error).message)
            }
        }
    }

    struct BackgroundConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Converts files outside the main window (menu bar, Finder Quick Actions, Shortcuts) and waits for
    /// the result. Progress shows in the menu bar. Returns the converted files.
    func convertInBackground(urls: [URL], title: String, forceNextToOriginals: Bool = false,
                             settingsFor: @escaping (MediaKind) -> ConversionSettings?) async throws -> [URL] {
        let scanned = await Task.detached(priority: .userInitiated) { FileScanner.scan(urls) }.value
        let list = scanned.items.map(FileEntry.init)
        guard !list.isEmpty else {
            throw BackgroundConversionError(message: "Nothing Morph can convert was found")
        }
        await setupTask?.value
        await probe(quick: list)
        let applicable = list.filter { $0.isReady && settingsFor($0.kind) != nil }
        guard !applicable.isEmpty else {
            if let failure = list.compactMap(\.failureMessage).first {
                throw BackgroundConversionError(message: failure)
            }
            throw BackgroundConversionError(message: "“\(title)” doesn't apply to those files")
        }
        let destination: DestinationChoice
        if forceNextToOriginals || settings.quickActionsSaveNextToOriginals {
            destination = .nextToOriginals
        } else {
            guard let choice = await chooseDestination(
                for: applicable, settingsFor: { settingsFor($0) ?? self.settings(for: $0) }, window: nil)
            else { return [] }
            destination = choice
        }
        let jobs = planJobs(for: applicable, settingsFor: settingsFor, destination: destination)
        let runner = BatchRunner(title: "\(title) · \(applicable.count) file\(applicable.count == 1 ? "" : "s")",
                                 jobs: jobs, pipeline: pipeline(for: destination),
                                 maxParallel: settings.maxParallel > 0 ? settings.maxParallel : nil)
        // AppModel is an app-lifetime singleton, so capturing it strongly is fine.
        runner.onOutput = { url, bytes, original in self.addRecent(url: url, bytes: bytes, original: original) }
        quickBatches.append(runner)
        let summary = await withCheckedContinuation { (continuation: CheckedContinuation<BatchSummary, Never>) in
            runner.onFinish = { [weak runner] summary in
                if self.settings.notifyWhenDone { SystemFeedback.notifyFinished(summary) }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(8))
                    self.quickBatches.removeAll { $0 === runner }
                }
                continuation.resume(returning: summary)
            }
            runner.start()
        }
        if summary.converted == 0, let failure = runner.entries.lazy.compactMap({ entry -> String? in
            if case .failed(let message, _, _) = entry.job { message } else { nil }
        }).first {
            throw BackgroundConversionError(message: failure)
        }
        return summary.outputs
    }

    private func probe(quick list: [FileEntry]) async {
        let tools = self.tools
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        await Self.forEachLimited(list.map(\.item), width: 8) { item in
            try await MediaProbe.info(for: item, tools: tools)
        } onResult: { id, result in
            guard let entry = byID[id] else { return }
            switch result {
            case .success(let info):
                entry.item.info = info
                entry.probe = .ready
            case .failure(let error):
                entry.probe = .failed(FriendlyErrors.explain(error).message)
            }
        }
    }

    /// Converts the clipboard image with a quick action and puts the result back on the clipboard.
    func convertClipboardImage(to format: OutputFormat) {
        let board = NSPasteboard.general
        guard let data = [UTType.png, .tiff, .jpeg, .heic].lazy.compactMap({ board.data(forType: NSPasteboard.PasteboardType($0.identifier)) }).first,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let fileFormat = format.imageFormat else {
            show(toast: "The clipboard has no image")
            return
        }
        var options = settings(for: .image).image
        options.sizeLimit = nil
        options.resize = .none
        let finalOptions = options
        Task {
            do {
                let result = try await BlockingWork.run { try ImageEngine.convert(image: image, to: fileFormat, options: finalOptions) }
                let dir = FileManager.default.temporaryDirectory.appending(path: "Morph Clipboard", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appending(path: "Clipboard Image").appendingPathExtension(result.fileExtension)
                try? FileManager.default.removeItem(at: url)
                try result.data.write(to: url)
                board.clearContents()
                board.writeObjects([url as NSURL])
                if let type = UTType(filenameExtension: result.fileExtension) {
                    board.setData(result.data, forType: NSPasteboard.PasteboardType(type.identifier))
                }
                show(toast: "Copied as \(format.displayName) (\(Formatters.bytes(result.byteCount)))")
            } catch {
                show(toast: "Couldn't convert the clipboard image")
            }
        }
    }

    // MARK: - Recents

    private func addRecent(url: URL, bytes: Int64, original: Int64) {
        recents.insert(RecentOutput(url: url, bytes: bytes, originalBytes: original, date: Date()), at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        saveRecents()
    }

    func clearRecents() {
        recents.removeAll()
        saveRecents()
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: "recents"),
              let list = try? JSONDecoder().decode([RecentOutput].self, from: data) else { return }
        recents = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: "recents") }
    }

    // MARK: - Toasts

    func show(toast message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
