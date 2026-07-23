import Foundation
import Combine

/// App-side orchestrator for audio/video **file** transcription (MAK-36).
///
/// Owns the pure `FileTranscriptionQueue` (the state machine + chunk plan), a
/// dedicated `FileTranscriptionEngine` for batch work (so it never contends with
/// the live-dictation engine), the AVFoundation `MediaFileDecoder`, the
/// `WatchFolderMonitor`, and export. It runs one file at a time; each file is
/// decoded to 16 kHz mono chunk-WAVs, transcribed through the existing engine, and
/// (optionally) enhanced via the injected LLM refine closure.
///
/// All the *decision* logic (queue transitions, chunk planning, watch eligibility,
/// subtitle formatting, export naming) lives in `OpenWhispCore` and is unit-tested;
/// this class is the effectful glue (@MainActor, drives the engine/decoder/FS).
@MainActor
final class FileTranscriptionCoordinator: ObservableObject {

    /// The visible queue, mirrored for SwiftUI.
    @Published private(set) var queue = FileTranscriptionQueue()
    @Published private(set) var watchFolders: [WatchFolder] = []
    @Published var lastExportMessage: String?

    /// Engine wiring (supplied by AppState so it matches the user's model/backend).
    struct EngineConfig {
        var makeEngine: () -> FileTranscriptionEngine
        var binaryPath: String
        var modelPath: String
        var languageSetting: String
        var backend: WhisperBackend
        var prompt: String
        /// Optional LLM enhance pass: (rawText) async -> enhancedText. nil = disabled.
        var enhance: ((String) async -> String)?
    }

    private let engineConfig: () -> EngineConfig
    private var engine: FileTranscriptionEngine?
    private let monitor = WatchFolderMonitor()
    private var watchPolicy = WatchFolderPolicy(debounceSeconds: 2.0)
    /// User's "Enhance with the LLM" toggle. Effective enhance for a job is this
    /// AND an enhance closure actually being configured.
    private var enhanceRequested = false
    /// Pending debounce retry so a file observed mid-copy is re-checked once it
    /// settles (FSEvents won't necessarily fire again after the copy finishes).
    private var debounceRetryScheduled = false

    // Per-active-job working state.
    private var activeJobID: UUID?
    private var chunkWAVs: [Int: URL] = [:]           // chunkIndex -> decoded WAV
    private var requestToChunk: [UUID: Int] = [:]     // engine requestID -> chunkIndex
    private var workDir: URL?
    /// Last engine error seen for the active job (a chunk error yields empty
    /// text; if the whole job produced nothing, this becomes the failure).
    private var lastChunkError: String?

    private let store: URL

    init(
        engineConfig: @escaping () -> EngineConfig,
        storeURL: URL? = nil
    ) {
        self.engineConfig = engineConfig
        self.store = storeURL ?? FileTranscriptionCoordinator.defaultStoreURL()
        loadPersisted()
        // Resume restored work: loadPersisted resets mid-flight jobs back to
        // .queued precisely so they rerun after a crash/quit, but nothing else
        // ever pumps them (pump() only runs on add/remove events) — a batch
        // queued before a relaunch would sit at "Queued" forever. Deferred a
        // turn so the owner (AppState) finishes initializing before
        // engineConfig() is consulted.
        Task { @MainActor [weak self] in self?.pump() }
    }

    // MARK: - Public API (called by UI)

    /// Add manually-chosen files to the queue and kick the scheduler.
    func addFiles(_ urls: [URL]) {
        for url in urls {
            queue.add(FileTranscriptionJob(sourcePath: url.path))
        }
        persist()
        pump()
    }

    func removeJob(_ id: UUID) {
        queue.remove(id)
        if id == activeJobID {
            // Cancel the in-flight job: tear down its engine/work dir and clear
            // the active slot, otherwise the scheduler is stalled forever (its
            // chunk callbacks would no-op against the removed job and
            // `activeJobID` would never clear).
            engine?.stopServer()
            engine = nil
            cleanupWork()
            activeJobID = nil
            pump()
        }
        persist()
    }

    func clearFinished() {
        queue.clearFinished()
        persist()
    }

    /// Toggle the LLM enhance pass for future jobs. Takes effect when each job
    /// starts (combined with whether an enhance closure is actually configured).
    func setEnhanceEnabled(_ on: Bool) {
        enhanceRequested = on
        queue.enhanceEnabled = on
    }

    /// Export a finished job's transcript to `format` at its default sibling path.
    @discardableResult
    func export(_ id: UUID, format: SubtitleFormat, directory: String? = nil) -> Bool {
        guard let job = queue.job(id), job.stage == .done else { return false }
        let contents = SubtitleFormatter.render(format, chunks: job.chunks, chunkTexts: job.chunkTexts)
        let path = TranscriptExportNaming.exportPath(sourcePath: job.sourcePath, format: format, directory: directory)
        do {
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            lastExportMessage = "Saved \(format.fileExtension.uppercased()) → \((path as NSString).lastPathComponent)"
            return true
        } catch {
            lastExportMessage = "Export failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Watch folders

    func addWatchFolder(_ url: URL) {
        guard !watchFolders.contains(where: { $0.path == url.path }) else { return }
        watchFolders.append(WatchFolder(path: url.path))
        persist()
        restartWatching()
    }

    func removeWatchFolder(_ id: UUID) {
        watchFolders.removeAll { $0.id == id }
        persist()
        restartWatching()
    }

    func setWatchFolderEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = watchFolders.firstIndex(where: { $0.id == id }) else { return }
        watchFolders[i].enabled = enabled
        persist()
        restartWatching()
    }

    /// Start monitoring based on current enabled folders. Safe to call repeatedly.
    func restartWatching() {
        monitor.onFilesObserved = { [weak self] events in
            self?.handleWatchEvents(events)
        }
        let paths = watchFolders.filter(\.enabled).map(\.path)
        monitor.start(paths: paths)
    }

    private func handleWatchEvents(_ events: [WatchedFileEvent]) {
        var added = false
        for event in watchPolicy.eligible(from: events) {
            guard !queue.contains(path: event.path) else { watchPolicy.markSeen(event.path); continue }
            queue.add(FileTranscriptionJob(sourcePath: event.path, fromWatchFolder: true))
            watchPolicy.markSeen(event.path)
            added = true
        }
        if added {
            persist()
            pump()
        }
        scheduleDebounceRetryIfNeeded(events)
    }

    /// A file observed mid-copy fails the quiescence debounce, and FSEvents may
    /// not fire again once the copy finishes (the last write IS the last event).
    /// If any unseen supported file was skipped only because it wasn't quiet yet,
    /// re-check the watched folders once after the debounce window has passed.
    private func scheduleDebounceRetryIfNeeded(_ events: [WatchedFileEvent]) {
        guard !debounceRetryScheduled else { return }
        let pendingDebounce = events.contains { event in
            SupportedMediaExtensions.isSupported(path: event.path)
                && !watchPolicy.hasSeen(event.path)
                && !watchPolicy.isEligible(event)
        }
        guard pendingDebounce else { return }
        debounceRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.debounceRetryScheduled = false
            self.monitor.rescanNow()
        }
    }

    // MARK: - Scheduler

    /// Start the next queued job if idle.
    private func pump() {
        guard activeJobID == nil, let job = queue.next() else { return }
        activeJobID = job.id
        startJob(job)
    }

    private func startJob(_ job: FileTranscriptionJob) {
        let source = URL(fileURLWithPath: job.sourcePath)
        let cfg = engineConfig()
        // Enhance runs only when the user asked for it AND an LLM pass is wired.
        queue.enhanceEnabled = enhanceRequested && cfg.enhance != nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let duration = try await MediaFileDecoder.duration(of: source)
                await MainActor.run {
                    self.queue.beginLoading(job.id, duration: duration)
                    self.persist()
                }
                let plan = FileChunkPlanner.plan(duration: duration)
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("openwhisp-file-\(job.id.uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                await MainActor.run { self.workDir = dir; self.chunkWAVs = [:] }

                for chunk in plan {
                    // Stop decoding if the job was removed/cancelled meanwhile.
                    guard await MainActor.run(body: { self.activeJobID == job.id }) else {
                        try? FileManager.default.removeItem(at: dir)
                        return
                    }
                    let wav = dir.appendingPathComponent("chunk-\(chunk.index).wav")
                    try await MediaFileDecoder.decodeRange(
                        source: source, start: chunk.start,
                        end: chunk.index == plan.count - 1 ? nil : chunk.end,
                        outputURL: wav
                    )
                    await MainActor.run { self.chunkWAVs[chunk.index] = wav }
                }
                await MainActor.run { self.beginEngineWork(job.id, config: cfg, plan: plan) }
            } catch {
                await MainActor.run {
                    // Only fail if this job is still the active one (it may have
                    // been removed/cancelled while decoding).
                    guard self.activeJobID == job.id else { return }
                    self.failActive(error.localizedDescription)
                }
            }
        }
    }

    private func beginEngineWork(_ jobID: UUID, config: EngineConfig, plan: [FileChunkPlan]) {
        // The job may have been removed (cancelled) while decode was running.
        guard activeJobID == jobID, queue.job(jobID) != nil else { return }
        let engine = config.makeEngine()
        self.engine = engine
        requestToChunk = [:]

        engine.onTranscriptionComplete = { [weak self] requestID, text in
            Task { @MainActor in self?.handleChunkComplete(requestID: requestID, text: text, config: config) }
        }
        engine.onTranscriptionError = { [weak self] requestID, message in
            Task { @MainActor in self?.handleChunkComplete(requestID: requestID, text: "", config: config, error: message) }
        }

        queue.beginTranscribing(jobID)
        persist()

        // Dispatch every chunk (engine handles its own concurrency/serialization).
        for chunk in plan {
            guard let wav = chunkWAVs[chunk.index] else { continue }
            let requestID = UUID()
            requestToChunk[requestID] = chunk.index
            engine.transcribe(
                requestID: requestID,
                binaryPath: config.binaryPath,
                modelPath: config.modelPath,
                language: config.languageSetting,
                wavPath: wav.path,
                deleteWhenDone: true,
                backend: config.backend,
                prompt: config.prompt
            )
        }
    }

    private func handleChunkComplete(requestID: UUID, text: String, config: EngineConfig, error: String? = nil) {
        guard let jobID = activeJobID, let chunkIndex = requestToChunk.removeValue(forKey: requestID) else { return }
        if let error { lastChunkError = error }
        queue.completeChunk(jobID, chunkIndex: chunkIndex, text: text)

        guard let job = queue.job(jobID), job.allChunksComplete else {
            persist(); return
        }
        // If nothing transcribed and at least one chunk errored, the "transcript"
        // is really a failure — surface it instead of a silent empty Done.
        if job.fullText.isEmpty, let chunkError = lastChunkError {
            failActive(chunkError)
            return
        }
        // All chunks done → transcription finished.
        let needsEnhance = queue.finishTranscription(jobID)
        persist()
        if needsEnhance, let enhance = config.enhance {
            let raw = job.fullText
            Task { [weak self] in
                let enhanced = await enhance(raw)
                await MainActor.run {
                    // Bail if this job is no longer the active one (same guard as
                    // the decode loop): the user may have removed it mid-enhance,
                    // in which case pump() already started the NEXT job —
                    // finishActive() here would tear down that job's engine/work
                    // dir and wedge the queue at a non-terminal stage forever.
                    guard let self, self.activeJobID == jobID else { return }
                    self.queue.finishEnhancing(jobID, enhancedText: enhanced)
                    self.finishActive()
                }
            }
        } else {
            finishActive()
        }
    }

    private func failActive(_ message: String) {
        guard let jobID = activeJobID else { return }
        queue.fail(jobID, message: message)
        finishActive()
    }

    private func finishActive() {
        cleanupWork()
        activeJobID = nil
        engine?.stopServer()
        engine = nil
        persist()
        pump()
    }

    private func cleanupWork() {
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
        chunkWAVs = [:]
        requestToChunk = [:]
        lastChunkError = nil
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var jobs: [FileTranscriptionJob]
        var watchFolders: [WatchFolder]
        /// Watch-folder paths already enqueued once — survives restarts so a
        /// transcribed file still sitting in the folder isn't re-enqueued after
        /// its queue row was cleared.
        var seenWatchPaths: Set<String>?
    }

    private func loadPersisted() {
        let data = JSONStore.load(from: store, default: Persisted(jobs: [], watchFolders: []), label: "file-queue")
        // Reset any non-terminal jobs left mid-flight from a prior run back to queued.
        let restored = data.jobs.map { job -> FileTranscriptionJob in
            var j = job
            if !j.stage.isTerminal { j.stage = .queued; j.chunkTexts = [:] }
            return j
        }
        queue = FileTranscriptionQueue(jobs: restored, enhanceEnabled: queue.enhanceEnabled)
        watchFolders = data.watchFolders
        watchPolicy = WatchFolderPolicy(
            debounceSeconds: watchPolicy.debounceSeconds,
            seen: data.seenWatchPaths ?? []
        )
    }

    private func persist() {
        JSONStore.save(
            Persisted(jobs: queue.jobs, watchFolders: watchFolders, seenWatchPaths: watchPolicy.seenPaths),
            to: store, label: "file-queue"
        )
    }

    private static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisp", isDirectory: true)
        return base.appendingPathComponent("file-queue.json")
    }
}
