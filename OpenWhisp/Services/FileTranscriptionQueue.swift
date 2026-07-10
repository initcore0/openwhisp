import Foundation

/// Pure, testable state machine for the audio/video **file** transcription queue
/// (MAK-36).
///
/// This is the batch-queue analogue of `LiveChunkPipeline`: it owns the *visible*
/// per-file lifecycle (Queued → Loading model → Transcribing → Enhancing →
/// Done/Failed), the chunk plan for a long file, and the single-active-job
/// scheduling policy. It performs **no** side effects — no AVFoundation decode, no
/// engine calls, no file IO. The app-side driver reads `next()` to learn which job
/// to run and calls the mutating transitions as work progresses; SwiftUI renders
/// `jobs` directly. Being Foundation-only, it compiles into `OpenWhispCore` and is
/// unit-tested by `swift test`.
///
/// Timestamps for SRT/VTT export are produced downstream by `SubtitleFormatter`
/// from the chunk plan this type computes (chunk-level timing), since the local
/// engines surface only plain text per chunk.

// MARK: - Job stage

/// The user-visible lifecycle stage of one file in the queue. Persisted in the
/// queue snapshot, so the raw values are a stored contract — pin them.
enum FileJobStage: String, Codable, Equatable {
    case queued
    case loadingModel
    case transcribing
    case enhancing
    case done
    case failed

    /// Terminal stages don't get rescheduled.
    var isTerminal: Bool { self == .done || self == .failed }

    /// Short human label for the queue row.
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .loadingModel: return "Loading model"
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Chunk plan

/// One planned slice of a (possibly long) source file, in seconds. The queue plans
/// these deterministically so long files transcribe in bounded pieces and so
/// subtitle timing has a stable per-chunk offset.
struct FileChunkPlan: Equatable {
    /// 0-based index of the chunk within its file.
    let index: Int
    /// Start offset from the beginning of the file, in seconds.
    let start: Double
    /// End offset from the beginning of the file, in seconds.
    let end: Double

    var duration: Double { end - start }
}

/// Compute a chunk plan for a file of `duration` seconds. A file at or under
/// `chunkSeconds` is a single chunk `[0, duration]`; longer files are split into
/// equal `chunkSeconds` windows with the remainder as a final shorter chunk. A
/// non-positive duration yields a single empty chunk so a zero-length/decoding-
/// still-pending file still has a slot.
enum FileChunkPlanner {
    static func plan(duration: Double, chunkSeconds: Double = 30.0) -> [FileChunkPlan] {
        guard duration > 0, chunkSeconds > 0 else {
            return [FileChunkPlan(index: 0, start: 0, end: max(0, duration))]
        }
        if duration <= chunkSeconds {
            return [FileChunkPlan(index: 0, start: 0, end: duration)]
        }
        var plans: [FileChunkPlan] = []
        var start = 0.0
        var index = 0
        while start < duration - 0.0005 {
            let end = min(start + chunkSeconds, duration)
            plans.append(FileChunkPlan(index: index, start: start, end: end))
            start = end
            index += 1
        }
        return plans
    }
}

// MARK: - Job

/// One file in the batch queue, with its computed chunk plan and per-chunk text as
/// it fills in. `Identifiable`/`Codable` so SwiftUI can render it and the queue can
/// be persisted across launches.
struct FileTranscriptionJob: Identifiable, Codable, Equatable {
    let id: UUID
    /// Absolute path to the source media file.
    var sourcePath: String
    /// Display name (usually the last path component).
    var displayName: String
    /// Total decoded duration in seconds (0 until decode determines it).
    var durationSeconds: Double
    /// Planned chunk windows (see `FileChunkPlanner`).
    var chunks: [FileChunkPlan]
    /// Transcribed text per chunk index, filled in as chunks complete. Missing
    /// entries are chunks not yet done.
    var chunkTexts: [Int: String]
    var stage: FileJobStage
    /// Failure detail when `stage == .failed`.
    var errorMessage: String?
    /// Whether this job came from a watch folder (vs. a manual add).
    var fromWatchFolder: Bool
    /// When the job was enqueued (for stable ordering / display).
    var addedAt: Date

    init(
        id: UUID = UUID(),
        sourcePath: String,
        displayName: String? = nil,
        durationSeconds: Double = 0,
        chunks: [FileChunkPlan] = [],
        chunkTexts: [Int: String] = [:],
        stage: FileJobStage = .queued,
        errorMessage: String? = nil,
        fromWatchFolder: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.displayName = displayName ?? (sourcePath as NSString).lastPathComponent
        self.durationSeconds = durationSeconds
        self.chunks = chunks
        self.chunkTexts = chunkTexts
        self.stage = stage
        self.errorMessage = errorMessage
        self.fromWatchFolder = fromWatchFolder
        self.addedAt = addedAt
    }

    // FileChunkPlan isn't Codable by itself (no keys); encode as flat arrays.
    private enum CodingKeys: String, CodingKey {
        case id, sourcePath, displayName, durationSeconds
        case chunkStarts, chunkEnds, chunkTexts, stage, errorMessage, fromWatchFolder, addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        displayName = try c.decode(String.self, forKey: .displayName)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        let starts = try c.decodeIfPresent([Double].self, forKey: .chunkStarts) ?? []
        let ends = try c.decodeIfPresent([Double].self, forKey: .chunkEnds) ?? []
        chunks = zip(starts, ends).enumerated().map { FileChunkPlan(index: $0.offset, start: $0.element.0, end: $0.element.1) }
        let texts = try c.decodeIfPresent([String: String].self, forKey: .chunkTexts) ?? [:]
        chunkTexts = Dictionary(uniqueKeysWithValues: texts.compactMap { k, v in Int(k).map { ($0, v) } })
        stage = try c.decode(FileJobStage.self, forKey: .stage)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        fromWatchFolder = try c.decodeIfPresent(Bool.self, forKey: .fromWatchFolder) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourcePath, forKey: .sourcePath)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(chunks.map(\.start), forKey: .chunkStarts)
        try c.encode(chunks.map(\.end), forKey: .chunkEnds)
        try c.encode(Dictionary(uniqueKeysWithValues: chunkTexts.map { (String($0.key), $0.value) }), forKey: .chunkTexts)
        try c.encode(stage, forKey: .stage)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(fromWatchFolder, forKey: .fromWatchFolder)
        try c.encode(addedAt, forKey: .addedAt)
    }

    /// Concatenated transcript across all chunks, in chunk order, joined by spaces.
    var fullText: String {
        chunks
            .compactMap { chunkTexts[$0.index]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when every planned chunk has produced text.
    var allChunksComplete: Bool {
        !chunks.isEmpty && chunks.allSatisfy { chunkTexts[$0.index] != nil }
    }
}

// MARK: - Queue

/// The batch queue: an ordered list of jobs and a single-active-job scheduler. The
/// scheduler runs one file at a time; the queue just decides *which* file is next
/// and tracks each file's stage.
struct FileTranscriptionQueue: Equatable {
    private(set) var jobs: [FileTranscriptionJob] = []

    /// Whether an LLM "Enhancing" pass runs after transcription. When false, jobs
    /// skip `.enhancing` and go straight to `.done`.
    var enhanceEnabled: Bool

    init(jobs: [FileTranscriptionJob] = [], enhanceEnabled: Bool = false) {
        self.jobs = jobs
        self.enhanceEnabled = enhanceEnabled
    }

    // MARK: Introspection

    func index(of id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
    func job(_ id: UUID) -> FileTranscriptionJob? { jobs.first { $0.id == id } }

    /// A job is "active" once it's past `.queued` and not terminal.
    var hasActiveJob: Bool {
        jobs.contains { $0.stage != .queued && !$0.stage.isTerminal }
    }

    /// Whether this path is already tracked (any stage) — used to dedupe watch-
    /// folder re-drops and manual re-adds of the same file.
    func contains(path: String) -> Bool {
        jobs.contains { $0.sourcePath == path }
    }

    var pendingCount: Int { jobs.filter { !$0.stage.isTerminal }.count }
    var doneCount: Int { jobs.filter { $0.stage == .done }.count }
    var failedCount: Int { jobs.filter { $0.stage == .failed }.count }

    // MARK: Mutations

    /// Add a job to the end of the queue. No-op (returns nil) if the path is already
    /// tracked. Returns the new job's id on success.
    @discardableResult
    mutating func add(_ job: FileTranscriptionJob) -> UUID? {
        guard !contains(path: job.sourcePath) else { return nil }
        jobs.append(job)
        return job.id
    }

    /// Remove a job (e.g. user dismisses a row). Allowed in any stage; the driver is
    /// responsible for cancelling any in-flight work first.
    mutating func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    /// Drop all terminal (done/failed) jobs — the "Clear finished" action.
    mutating func clearFinished() {
        jobs.removeAll { $0.stage.isTerminal }
    }

    /// The next job the scheduler should start, or nil if one is already active or
    /// there's nothing queued. Single-active-job policy: never returns a job while
    /// another is mid-flight.
    func next() -> FileTranscriptionJob? {
        guard !hasActiveJob else { return nil }
        return jobs.first { $0.stage == .queued }
    }

    /// Record the decoded duration and (re)compute the chunk plan for a job as it
    /// starts. Advances stage `.queued → .loadingModel`.
    mutating func beginLoading(_ id: UUID, duration: Double, chunkSeconds: Double = 30.0) {
        guard let i = index(of: id) else { return }
        jobs[i].durationSeconds = duration
        jobs[i].chunks = FileChunkPlanner.plan(duration: duration, chunkSeconds: chunkSeconds)
        jobs[i].stage = .loadingModel
    }

    /// Advance to `.transcribing` (model warmed, first chunk dispatched).
    mutating func beginTranscribing(_ id: UUID) {
        guard let i = index(of: id), jobs[i].stage == .loadingModel else { return }
        jobs[i].stage = .transcribing
    }

    /// Record the text for one completed chunk. Does not change stage.
    mutating func completeChunk(_ id: UUID, chunkIndex: Int, text: String) {
        guard let i = index(of: id) else { return }
        jobs[i].chunkTexts[chunkIndex] = text
    }

    /// Called when all chunks are done. Advances to `.enhancing` (if enabled) else
    /// `.done`. Returns true when an enhance pass should run.
    @discardableResult
    mutating func finishTranscription(_ id: UUID) -> Bool {
        guard let i = index(of: id) else { return false }
        if enhanceEnabled {
            jobs[i].stage = .enhancing
            return true
        }
        jobs[i].stage = .done
        return false
    }

    /// Replace the transcript with an enhanced version and mark done. The enhanced
    /// text is stored as chunk 0's text (clearing the rest) so `fullText` reflects
    /// it while keeping per-chunk timing available via `chunks` for subtitle export.
    mutating func finishEnhancing(_ id: UUID, enhancedText: String) {
        guard let i = index(of: id) else { return }
        if let first = jobs[i].chunks.first {
            jobs[i].chunkTexts = [first.index: enhancedText]
        } else {
            jobs[i].chunkTexts = [0: enhancedText]
        }
        jobs[i].stage = .done
    }

    /// Mark a job failed with a message. Terminal.
    mutating func fail(_ id: UUID, message: String) {
        guard let i = index(of: id) else { return }
        jobs[i].stage = .failed
        jobs[i].errorMessage = message
    }
}
