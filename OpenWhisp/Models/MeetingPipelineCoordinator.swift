import Foundation
import Combine

/// Errors surfaced by the meeting summarize path.
enum MeetingSummarizeError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The app is unavailable to summarize right now."
        }
    }
}

/// App-side orchestrator for "Meeting mode" (MAK-50): turn a captured
/// `MeetingRecording` into a `Meeting`, transcribe it through the existing MAK-36
/// file-transcription seam, optionally summarize it locally, and persist each step.
///
/// Owns the `MeetingSessionStore` (metadata + WAV directory), a **dedicated**
/// `FileTranscriptionEngine` per transcription job (so meeting work never contends
/// with live dictation — same guarantee `FileTranscriptionCoordinator` gives), the
/// AVFoundation `MediaFileDecoder` (reused, not re-implemented), and the summarize
/// map/reduce driven by the pure `MeetingSummarizer`.
///
/// All decision logic lives in `OpenWhispCore` and is unit-tested: `Meeting` /
/// `MeetingStatus` transitions, `MeetingSessionStore` persistence, and
/// `MeetingSummarizer` planning/prompts. This class is the effectful glue
/// (`@MainActor`, drives the engine/decoder/LLM/FS).
@MainActor
final class MeetingPipelineCoordinator: ObservableObject {

    /// The visible list, newest first, mirrored for SwiftUI.
    @Published private(set) var meetings: [Meeting] = []
    /// Non-nil when a recording is currently in progress (driven by the capture
    /// integrator via `beginRecording`/`endRecording`). Rendered as a live row.
    @Published private(set) var recordingInProgress: Meeting?
    /// MAK-52 live "who's talking" indicator, driven by the capture integrator while
    /// a meeting records (`updateTalkState`). Reset to `.silence` at begin/end.
    @Published private(set) var talkState: MeetingTalkState.Speaker = .silence
    @Published var lastMessage: String?

    // MARK: - Injected effects (all replaceable in tests)

    /// Config for a transcription job. Supplied by AppState so it matches the user's
    /// model/backend (mirrors `FileTranscriptionCoordinator.EngineConfig`).
    struct TranscriptionConfig {
        var makeEngine: () -> FileTranscriptionEngine
        var binaryPath: String
        var modelPath: String
        var languageSetting: String
        var backend: WhisperBackend
        var prompt: String
    }

    /// One LLM round-trip: (systemInstruction, userText, resolvedSummaryModel) →
    /// output. Fail by throwing; the caller decides the fallback. The app wires
    /// this to the refine service using the RESOLVED provider/model/endpoint
    /// (MAK-53), not the global cleanup LLM.
    typealias SummarizeCall = (_ instruction: String, _ input: String, _ resolved: SummaryModelResolver.Resolved) async throws -> String

    private let store: MeetingSessionStore
    private let transcriptionConfig: () -> TranscriptionConfig
    /// The LLM call, or nil when no LLM is configured (summarize disabled).
    private let summarizeCall: SummarizeCall?
    /// Resolve the summarization provider/model/endpoint (MAK-53): the separate
    /// summary model, or the cleanup globals when the user left it on "same as
    /// cleanup". Its `.isLocal` drives the privacy gate (auto vs. consent), and
    /// its provider name drives the consent dialog. Built per call so a mid-app
    /// settings change is reflected.
    private let resolveSummaryModel: () -> SummaryModelResolver.Resolved

    // Per-active-transcription working state.
    private var activeTranscribeID: UUID?
    /// Meetings that asked to transcribe while another transcription was active
    /// (FIFO). Drained by `kickPendingTranscription()` whenever the active job
    /// finishes or fails, so an ingest during a long transcription is queued —
    /// never dropped.
    private var pendingTranscribeIDs: [UUID] = []
    private var engine: FileTranscriptionEngine?
    private var workDir: URL?
    private var chunkWAVs: [Int: URL] = [:]
    private var requestToChunk: [UUID: Int] = [:]
    private var chunkPlan: [FileChunkPlan] = []
    private var lastChunkError: String?

    init(
        store: MeetingSessionStore = MeetingSessionStore(),
        transcriptionConfig: @escaping () -> TranscriptionConfig,
        summarizeCall: SummarizeCall? = nil,
        resolveSummaryModel: @escaping () -> SummaryModelResolver.Resolved = { .init(provider: "", model: "", endpoint: "") }
    ) {
        self.store = store
        self.transcriptionConfig = transcriptionConfig
        self.summarizeCall = summarizeCall
        self.resolveSummaryModel = resolveSummaryModel
        // Launch recovery: a persisted `transcribing`/`summarizing` means the app
        // died mid-work — nobody is doing that work now, so showing it verbatim is
        // a permanent spinner. Roll each back to its resting predecessor
        // (`MeetingStatus.normalizedForLaunch`, unit-tested in core) and persist.
        var loaded = store.load()
        for i in loaded.indices {
            let normalized = loaded[i].status.normalizedForLaunch
            guard normalized != loaded[i].status else { continue }
            NSLog("[Meeting] launch recovery: meeting %@ was persisted mid-work as \"%@\" — resetting to \"%@\"",
                  loaded[i].id.uuidString, loaded[i].status.label, normalized.label)
            loaded[i].status = normalized
            store.upsert(loaded[i])
        }
        self.meetings = loaded
    }

    /// Whether summarization can run automatically (resolved provider is local)
    /// vs. needs an explicit "text leaves this Mac" confirmation. Exposed for the
    /// UI to decide which affordance to show.
    var canAutoSummarize: Bool { summarizeCall != nil && resolveSummaryModel().isLocal }
    /// Whether summarization is available at all (an LLM is configured).
    var summarizeAvailable: Bool { summarizeCall != nil }
    /// A human-readable name for the resolved summary provider, for the consent
    /// dialog copy ("… will be sent to <provider>").
    var summaryProviderDisplayName: String {
        Self.providerDisplayName(resolveSummaryModel().provider)
    }

    static func providerDisplayName(_ id: String) -> String {
        switch id {
        case "bundled":  return "the on-device model"
        case "local":    return "your self-hosted server"
        case "openai":   return "OpenAI"
        case "agentCLI": return "your agent CLI"
        default:         return "your configured provider"
        }
    }

    // MARK: - Live-recording hooks (driven by the capture integrator)

    /// Called by the integrator when a recording starts, so the pane can show a live
    /// row. The id should match the eventual `MeetingRecording.id`.
    func beginRecording(id: UUID, startedAt: Date = Date()) {
        recordingInProgress = Meeting(id: id, startedAt: startedAt, status: .recorded)
        talkState = .silence
        liveTalk = MeetingTalkState()
    }

    /// Clear the live-recording row (the finished recording arrives via `ingest`).
    func endRecording() {
        recordingInProgress = nil
        talkState = .silence
    }

    /// Retained Schmitt-trigger state for the live talking indicator.
    private var liveTalk = MeetingTalkState()

    /// MAK-52: fold the latest per-leg live levels (mic = "You", system = "Them")
    /// into the talking indicator. Called by the capture integrator on a light UI
    /// cadence while recording. No-op once the live row is gone.
    func updateTalkState(micLevel: Float, systemLevel: Float) {
        guard recordingInProgress != nil else { return }
        let speaker = liveTalk.update(micLevel: micLevel, systemLevel: systemLevel)
        if speaker != talkState { talkState = speaker }
    }

    // MARK: - Ingest

    /// **Primary integration point.** Consume a finished recording: copy its WAV into
    /// the meetings audio directory under a leaf-guarded name, create the `Meeting`
    /// record, persist it, and kick off transcription. Returns the meeting id.
    @discardableResult
    func ingest(_ recording: MeetingRecording) -> UUID {
        recordingInProgress = nil
        let fileName = MeetingWAVName.fileName(for: recording.id)
        var meeting = Meeting(
            id: recording.id,
            startedAt: recording.startedAt,
            duration: recording.duration,
            wavFileName: fileName,
            status: .recorded
        )
        // MOVE the WAV into our audio dir under the canonical leaf name (copy +
        // delete-source fallback across volumes). Moving — not copying — matters:
        // the capture side writes into the same directory, so a leftover source
        // would double every meeting's disk footprint and look like a crash
        // orphan to the launch recovery sweep.
        do {
            try FileManager.default.createDirectory(at: store.audioDirectory, withIntermediateDirectories: true)
            let dest = store.audioDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: recording.wavURL, to: dest)
            } catch {
                try FileManager.default.copyItem(at: recording.wavURL, to: dest)
                try? FileManager.default.removeItem(at: recording.wavURL)
            }
        } catch {
            meeting.status = .failed(reason: "Couldn't store recording: \(error.localizedDescription)")
            persist(meeting)
            return meeting.id
        }
        // MAK-52: move the two leg WAVs alongside the mixed one under canonical leaf
        // names, when they exist. Best-effort — a leg-move failure degrades to
        // mixed-only attribution; it never fails the meeting.
        if let micURL = recording.micWavURL {
            let leaf = MeetingWAVName.micFileName(for: recording.id)
            if Self.moveLeg(micURL, toLeaf: leaf, in: store.audioDirectory) { meeting.micWavFileName = leaf }
        }
        if let sysURL = recording.systemWavURL {
            let leaf = MeetingWAVName.systemFileName(for: recording.id)
            if Self.moveLeg(sysURL, toLeaf: leaf, in: store.audioDirectory) { meeting.systemWavFileName = leaf }
        }
        persist(meeting)
        transcribe(meeting.id)
        return meeting.id
    }

    /// Move a leg WAV into `audioDir` under `leaf` (copy + delete-source fallback
    /// across volumes). Returns true on success; on failure the leg is skipped and
    /// attribution degrades to mixed-only.
    private static func moveLeg(_ src: URL, toLeaf leaf: String, in audioDir: URL) -> Bool {
        let dest = audioDir.appendingPathComponent(leaf)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: src, to: dest)
            return true
        } catch {
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                try? FileManager.default.removeItem(at: src)
                return true
            } catch { return false }
        }
    }

    // MARK: - Transcription

    /// Transcribe (or re-transcribe) a meeting's stored WAV through the file-
    /// transcription engine. One transcription runs at a time; a request that
    /// arrives while another is active is QUEUED (FIFO) and started automatically
    /// when the active one finishes — an ingest mid-transcription is never dropped.
    ///
    /// MAK-52 perf: when both leg WAVs exist, the two legs are the ONLY
    /// transcription work — the attributed transcript comes from interleaving them
    /// and the plain `transcript` is derived from the same chunks
    /// (`TranscriptInterleaver.mergePlain`), so the mixed WAV is not decoded a
    /// third time. The mixed WAV remains the fallback when a leg is missing or leg
    /// transcription fails.
    func transcribe(_ id: UUID) {
        guard activeTranscribeID == nil else {
            guard id != activeTranscribeID, !pendingTranscribeIDs.contains(id) else { return }
            pendingTranscribeIDs.append(id)
            lastMessage = "Another meeting is transcribing; this one is queued and will start automatically."
            return
        }
        pendingTranscribeIDs.removeAll { $0 == id }
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        guard let wav = store.wavURL(for: meeting), FileManager.default.fileExists(atPath: wav.path) else {
            meeting.status = .failed(reason: "The recording file is missing.")
            persist(meeting)
            return
        }
        activeTranscribeID = id
        meeting.status = .transcribing
        persist(meeting)

        let cfg = transcriptionConfig()
        if let mic = store.micWavURL(for: meeting), let sys = store.systemWavURL(for: meeting),
           FileManager.default.fileExists(atPath: mic.path),
           FileManager.default.fileExists(atPath: sys.path) {
            startLegTranscription(id, micWAV: mic, systemWAV: sys, mixedFallback: wav, config: cfg)
        } else {
            startMixedTranscription(id, wav: wav, config: cfg)
        }
    }

    /// Start the next queued transcription, if any (skipping ids that were deleted
    /// or are mid-work). Called whenever the active transcription slot frees up.
    ///
    /// The guard is `canStartTranscription`, NOT `== .recorded`: the queue also
    /// holds re-transcribes of `.transcribed`/`.done` meetings and retries of
    /// `.failed` ones (`transcribe()` itself has no status precondition), and
    /// those were being silently discarded after the UI said "queued and will
    /// start automatically".
    private func kickPendingTranscription() {
        guard activeTranscribeID == nil else { return }
        while !pendingTranscribeIDs.isEmpty {
            let next = pendingTranscribeIDs.removeFirst()
            guard let m = meetings.first(where: { $0.id == next }), m.status.canStartTranscription else { continue }
            transcribe(next)
            return
        }
    }

    /// The pre-MAK-52 mixed-WAV path: decode → chunk → callback engine. Used when a
    /// leg WAV is missing, or as the fallback when leg transcription fails.
    /// `activeTranscribeID` must already be set to `id`.
    private func startMixedTranscription(_ id: UUID, wav: URL, config cfg: TranscriptionConfig) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let duration = try await MediaFileDecoder.duration(of: wav)
                let plan = FileChunkPlanner.plan(duration: duration)
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("openwhisp-meeting-\(id.uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var wavs: [Int: URL] = [:]
                for chunk in plan {
                    guard await MainActor.run(body: { self.activeTranscribeID == id }) else {
                        try? FileManager.default.removeItem(at: dir)
                        return
                    }
                    let out = dir.appendingPathComponent("chunk-\(chunk.index).wav")
                    try await MediaFileDecoder.decodeRange(
                        source: wav, start: chunk.start,
                        end: chunk.index == plan.count - 1 ? nil : chunk.end,
                        outputURL: out
                    )
                    wavs[chunk.index] = out
                }
                await MainActor.run { self.beginEngineWork(id, config: cfg, plan: plan, workDir: dir, wavs: wavs) }
            } catch {
                await MainActor.run { self.failTranscription(id, error.localizedDescription) }
            }
        }
    }

    /// MAK-52 leg-first path: transcribe the mic ("Me") and system ("Them") legs
    /// sequentially, interleave them into the attributed transcript, and derive the
    /// plain transcript from the same chunks — skipping the mixed-WAV decode
    /// entirely (it would be superseded anyway). If leg transcription throws or
    /// produces no meaningful text, fall back to the mixed WAV so behavior degrades
    /// to the pre-MAK-52 pipeline instead of failing the meeting.
    private func startLegTranscription(_ id: UUID, micWAV: URL, systemWAV: URL, mixedFallback: URL, config cfg: TranscriptionConfig) {
        Task { [weak self] in
            guard let self else { return }
            do {
                var chunks: [TranscriptInterleaver.Chunk] = []
                chunks += try await self.transcribeLeg(speaker: "Me", wav: micWAV, config: cfg)
                chunks += try await self.transcribeLeg(speaker: "Them", wav: systemWAV, config: cfg)
                await MainActor.run {
                    guard self.activeTranscribeID == id else { return }
                    guard TranscriptInterleaver.hasMeaningfulText(chunks) else {
                        // Nothing usable came out of the legs — try the mixed WAV.
                        NSLog("[Meeting] leg transcription produced no text — falling back to the mixed WAV")
                        self.startMixedTranscription(id, wav: mixedFallback, config: cfg)
                        return
                    }
                    self.finishLegTranscription(id, chunks: chunks)
                }
            } catch {
                await MainActor.run {
                    guard self.activeTranscribeID == id else { return }
                    NSLog("[Meeting] leg transcription failed (%@) — falling back to the mixed WAV",
                          error.localizedDescription)
                    self.startMixedTranscription(id, wav: mixedFallback, config: cfg)
                }
            }
        }
    }

    /// Persist both transcripts from the leg chunks (attributed for display /
    /// summarizer input, plain derived from the same chunks for everything that
    /// reads `Meeting.transcript`), release the transcription slot, kick the queue,
    /// and continue to the summarize gate.
    private func finishLegTranscription(_ id: UUID, chunks: [TranscriptInterleaver.Chunk]) {
        guard var meeting = meetings.first(where: { $0.id == id }) else {
            activeTranscribeID = nil
            kickPendingTranscription()
            return
        }
        meeting.transcript = TranscriptInterleaver.mergePlain(chunks)
        meeting.attributedTranscript = TranscriptInterleaver.merge(chunks)
        meeting.status = .transcribed
        persist(meeting)
        activeTranscribeID = nil
        if chunks.contains(where: { $0.text == TranscriptInterleaver.failedSegmentPlaceholder }) {
            lastMessage = "Some audio segments couldn't be transcribed — the transcript has marked gaps."
        }
        kickPendingTranscription()
        if canAutoSummarize {
            summarize(id, confirmedCloud: false)
        }
    }

    private func beginEngineWork(_ id: UUID, config: TranscriptionConfig, plan: [FileChunkPlan], workDir: URL, wavs: [Int: URL]) {
        guard activeTranscribeID == id else { return }
        self.workDir = workDir
        self.chunkWAVs = wavs
        self.chunkPlan = plan
        self.requestToChunk = [:]
        self.lastChunkError = nil

        let engine = config.makeEngine()
        self.engine = engine
        engine.onTranscriptionComplete = { [weak self] req, text in
            Task { @MainActor in self?.handleChunk(req, text: text) }
        }
        engine.onTranscriptionError = { [weak self] req, msg in
            Task { @MainActor in self?.handleChunk(req, text: "", error: msg) }
        }

        for chunk in plan {
            guard let wav = wavs[chunk.index] else { continue }
            let req = UUID()
            requestToChunk[req] = chunk.index
            engine.transcribe(
                requestID: req,
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

    private var chunkTexts: [Int: String] = [:]
    /// Chunk indexes whose transcription errored (mixed path). Used to fail the
    /// meeting when EVERY chunk failed, and to surface a warning otherwise.
    private var failedChunks: Set<Int> = []

    private func handleChunk(_ req: UUID, text: String, error: String? = nil) {
        guard let id = activeTranscribeID, let chunkIndex = requestToChunk.removeValue(forKey: req) else { return }
        if let error {
            lastChunkError = error
            failedChunks.insert(chunkIndex)
            // Honest hole: a failed chunk is marked in place, not silently dropped —
            // otherwise the meeting lands as .transcribed with an invisible gap.
            chunkTexts[chunkIndex] = TranscriptInterleaver.failedSegmentPlaceholder
        } else {
            chunkTexts[chunkIndex] = text
        }
        // All chunks in?
        guard chunkPlan.allSatisfy({ chunkTexts[$0.index] != nil }) else { return }

        if failedChunks.count == chunkPlan.count, let err = lastChunkError {
            failTranscription(id, err)
            return
        }
        let hadFailures = !failedChunks.isEmpty
        let full = chunkPlan
            .compactMap { chunkTexts[$0.index]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if full.isEmpty, let err = lastChunkError {
            failTranscription(id, err)
            return
        }
        finishTranscription(id, transcript: full, partialFailure: hadFailures)
    }

    private func finishTranscription(_ id: UUID, transcript: String, partialFailure: Bool = false) {
        teardownEngine()
        guard var meeting = meetings.first(where: { $0.id == id }) else {
            activeTranscribeID = nil
            kickPendingTranscription()
            return
        }
        meeting.transcript = transcript
        // The mixed path produces no attribution, so drop any attributed
        // transcript from a PREVIOUS run: the detail view, export, and the
        // summarizer all prefer the attributed text when present, and a stale
        // one (e.g. a re-transcribe that degraded to the mixed fallback) would
        // silently shadow the transcript we just produced.
        meeting.attributedTranscript = nil
        meeting.status = .transcribed
        persist(meeting)
        activeTranscribeID = nil
        if partialFailure {
            lastMessage = "Some audio segments couldn't be transcribed — the transcript has marked gaps."
        }
        kickPendingTranscription()

        // Auto-summarize only when the provider is local (privacy rule). Cloud/agent
        // providers require an explicit per-meeting confirmation from the UI.
        // (MAK-52 attribution no longer runs from here: when both legs exist,
        // `transcribe` takes the leg-first path and this mixed path is only the
        // missing-leg / leg-failure fallback — re-attempting attribution here would
        // just repeat the failed work.)
        if canAutoSummarize {
            summarize(id, confirmedCloud: false)
        }
    }

    // MARK: - MAK-52 leg transcription

    /// Transcribe ONE leg WAV: decode → chunk (with time offsets) → transcribe each
    /// chunk sequentially → return `[Chunk]` labeled with `speaker` and each chunk's
    /// start offset. A dedicated engine is spun up and torn down per leg. Throws on
    /// decode failure; empty chunks are dropped by the interleaver.
    private func transcribeLeg(speaker: String, wav: URL, config: TranscriptionConfig) async throws -> [TranscriptInterleaver.Chunk] {
        let duration = try await MediaFileDecoder.duration(of: wav)
        let plan = FileChunkPlanner.plan(duration: duration)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhisp-meeting-leg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = config.makeEngine()
        defer { engine.stopServer() }

        var out: [TranscriptInterleaver.Chunk] = []
        for chunk in plan {
            let chunkWAV = dir.appendingPathComponent("leg-chunk-\(chunk.index).wav")
            try await MediaFileDecoder.decodeRange(
                source: wav, start: chunk.start,
                end: chunk.index == plan.count - 1 ? nil : chunk.end,
                outputURL: chunkWAV
            )
            let text = try await Self.transcribeOne(engine: engine, wav: chunkWAV, config: config)
            out.append(TranscriptInterleaver.Chunk(speaker: speaker, start: chunk.start, text: text))
        }
        return out
    }

    /// One chunk through the callback engine, bridged to async. Resolves with the
    /// text on completion; a per-chunk error resolves with the visible
    /// failed-segment placeholder so one bad chunk doesn't abort the whole leg but
    /// also doesn't leave a silent hole in the (now primary) leg transcript.
    private static func transcribeOne(engine: FileTranscriptionEngine, wav: URL, config: TranscriptionConfig) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let req = UUID()
            engine.onTranscriptionComplete = { r, text in guard r == req else { return }; cont.resume(returning: text) }
            engine.onTranscriptionError = { r, _ in
                guard r == req else { return }
                cont.resume(returning: TranscriptInterleaver.failedSegmentPlaceholder)
            }
            engine.transcribe(
                requestID: req,
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

    private func failTranscription(_ id: UUID, _ message: String) {
        teardownEngine()
        activeTranscribeID = nil
        defer { kickPendingTranscription() }
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        meeting.status = .failed(reason: message)
        persist(meeting)
    }

    private func teardownEngine() {
        engine?.stopServer()
        engine = nil
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
        chunkWAVs = [:]
        requestToChunk = [:]
        chunkPlan = []
        chunkTexts = [:]
        failedChunks = []
        lastChunkError = nil
    }

    // MARK: - Summarization

    /// Summarize a transcribed meeting. For a non-local provider the caller MUST pass
    /// `confirmedCloud: true` (the "transcript leaves this Mac" consent); otherwise
    /// the request is refused. Runs the `MeetingSummarizer` map/reduce, then guards
    /// the result against a silent translation (RefineOutputGuard) — on rejection the
    /// summary is dropped and a note surfaced, leaving the transcript intact.
    func summarize(_ id: UUID, confirmedCloud: Bool) {
        guard let summarize = summarizeCall else {
            lastMessage = "No LLM is configured for summaries."
            return
        }
        guard let meeting = meetings.first(where: { $0.id == id }),
              let plainTranscript = meeting.transcript, !plainTranscript.isEmpty else { return }
        // Resolve the summary model ONCE for this run (MAK-53). Its locality drives
        // the privacy gate; the whole run then uses this resolved provider/model.
        // This gate runs on EVERY entry to summarize — including the calls
        // attribution triggers (attributeAndThenSummarize) — so the resolved
        // privacy rule applies uniformly.
        let resolved = resolveSummaryModel()
        // The agent-CLI provider has no OpenAI-shape endpoint, so the summarize
        // seam can't call it (and must NEVER silently fall through to a cloud
        // endpoint the user didn't pick). Fail closed with an actionable message.
        if resolved.provider == "agentCLI" {
            lastMessage = "The agent CLI provider can't summarize meetings — pick a summarization model in Settings → Meetings."
            return
        }
        if !resolved.isLocal && !confirmedCloud {
            lastMessage = "Summarizing with a cloud provider needs your confirmation."
            return
        }
        // MAK-52: prefer the attributed transcript (Me/Them labels) as the summarizer
        // input — the labels help the model attribute action items to a speaker. The
        // language guard still runs against the plain transcript below.
        let summarizerInput = (meeting.attributedTranscript?.isEmpty == false)
            ? meeting.attributedTranscript! : plainTranscript

        var working = meeting
        working.status = .summarizing
        persist(working)

        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await MeetingSummarizer.run(transcript: summarizerInput) { instruction, input in
                    try await summarize(instruction, input, resolved)
                }
                await MainActor.run { self.finishSummary(id, transcript: plainTranscript, summary: summary) }
            } catch {
                await MainActor.run {
                    // Summary failure is non-destructive: fall back to the transcribed
                    // resting state with a note, not a hard failure.
                    guard var m = self.meetings.first(where: { $0.id == id }) else { return }
                    m.status = .transcribed
                    self.persist(m)
                    self.lastMessage = "Summary failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func finishSummary(_ id: UUID, transcript: String, summary: String) {
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        // Language guard: reject a summary that translated the transcript away.
        if RefineOutputGuard.outputTranslatedAway(input: transcript, output: summary) {
            meeting.summary = nil
            meeting.status = .done
            persist(meeting)
            lastMessage = "The summary came back in a different language, so OpenWhisp kept the transcript only."
            return
        }
        meeting.summary = summary
        meeting.status = .done
        persist(meeting)
    }

    // MARK: - Delete / export helpers

    func delete(_ id: UUID) {
        pendingTranscribeIDs.removeAll { $0 == id }
        if id == activeTranscribeID { teardownEngine(); activeTranscribeID = nil }
        meetings = store.delete(id: id)
        kickPendingTranscription()
    }

    /// Assemble the Markdown export body (summary + transcript) for a meeting.
    func exportMarkdown(_ id: UUID) -> String? {
        guard let m = meetings.first(where: { $0.id == id }) else { return nil }
        return Self.exportMarkdown(for: m)
    }

    /// Pure export renderer (unit-tested): summary section (if any) then transcript.
    static func exportMarkdown(for meeting: Meeting) -> String {
        var out = "# Meeting — \(Self.dateFormatter.string(from: meeting.startedAt))\n\n"
        if let summary = meeting.summary, !summary.isEmpty {
            out += summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        out += "## Transcript\n\n"
        // MAK-52: prefer the attributed (Me/Them) transcript when present.
        let body = (meeting.attributedTranscript?.isEmpty == false)
            ? meeting.attributedTranscript! : (meeting.transcript ?? "(no transcript)")
        out += body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return out
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Persistence

    private func persist(_ meeting: Meeting) {
        meetings = store.upsert(meeting)
    }
}
