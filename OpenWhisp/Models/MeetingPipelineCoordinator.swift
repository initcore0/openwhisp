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

    /// One LLM round-trip: (systemInstruction, userText) → output. Fail by throwing;
    /// the caller decides the fallback. The app wires this to the refine service
    /// (`OpenAITranslationService.processFinalText` via `customInstruction`).
    typealias SummarizeCall = (_ instruction: String, _ input: String) async throws -> String

    private let store: MeetingSessionStore
    private let transcriptionConfig: () -> TranscriptionConfig
    /// The LLM call, or nil when no LLM is configured (summarize disabled).
    private let summarizeCall: SummarizeCall?
    /// Whether the current refine provider keeps text on-device — decides whether
    /// summarize may auto-run vs. require explicit per-meeting consent.
    private let providerIsLocal: () -> Bool

    // Per-active-transcription working state.
    private var activeTranscribeID: UUID?
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
        providerIsLocal: @escaping () -> Bool = { false }
    ) {
        self.store = store
        self.transcriptionConfig = transcriptionConfig
        self.summarizeCall = summarizeCall
        self.providerIsLocal = providerIsLocal
        self.meetings = store.load()
    }

    /// Whether summarization can run automatically (local provider) vs. needs an
    /// explicit "text leaves this Mac" confirmation. Exposed for the UI to decide
    /// which affordance to show.
    var canAutoSummarize: Bool { summarizeCall != nil && providerIsLocal() }
    /// Whether summarization is available at all (an LLM is configured).
    var summarizeAvailable: Bool { summarizeCall != nil }

    // MARK: - Live-recording hooks (driven by the capture integrator)

    /// Called by the integrator when a recording starts, so the pane can show a live
    /// row. The id should match the eventual `MeetingRecording.id`.
    func beginRecording(id: UUID, startedAt: Date = Date()) {
        recordingInProgress = Meeting(id: id, startedAt: startedAt, status: .recorded)
    }

    /// Clear the live-recording row (the finished recording arrives via `ingest`).
    func endRecording() {
        recordingInProgress = nil
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
        // Move/copy the WAV into our audio dir under the canonical leaf name.
        do {
            try FileManager.default.createDirectory(at: store.audioDirectory, withIntermediateDirectories: true)
            let dest = store.audioDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: recording.wavURL, to: dest)
        } catch {
            meeting.status = .failed(reason: "Couldn't store recording: \(error.localizedDescription)")
            persist(meeting)
            return meeting.id
        }
        persist(meeting)
        transcribe(meeting.id)
        return meeting.id
    }

    // MARK: - Transcription

    /// Transcribe (or re-transcribe) a meeting's stored WAV through the file-
    /// transcription engine. No-op if already transcribing or the WAV is missing.
    func transcribe(_ id: UUID) {
        guard activeTranscribeID == nil else {
            // One at a time; leave it for the caller to retry after the active one
            // finishes. (Meeting recordings are infrequent; a simple guard suffices.)
            lastMessage = "Another meeting is transcribing; try again in a moment."
            return
        }
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

    private func handleChunk(_ req: UUID, text: String, error: String? = nil) {
        guard let id = activeTranscribeID, let chunkIndex = requestToChunk.removeValue(forKey: req) else { return }
        if let error { lastChunkError = error }
        chunkTexts[chunkIndex] = text
        // All chunks in?
        guard chunkPlan.allSatisfy({ chunkTexts[$0.index] != nil }) else { return }

        let full = chunkPlan
            .compactMap { chunkTexts[$0.index]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if full.isEmpty, let err = lastChunkError {
            failTranscription(id, err)
            return
        }
        finishTranscription(id, transcript: full)
    }

    private func finishTranscription(_ id: UUID, transcript: String) {
        teardownEngine()
        guard var meeting = meetings.first(where: { $0.id == id }) else { activeTranscribeID = nil; return }
        meeting.transcript = transcript
        meeting.status = .transcribed
        persist(meeting)
        activeTranscribeID = nil
        // Auto-summarize only when the provider is local (privacy rule). Cloud/agent
        // providers require an explicit per-meeting confirmation from the UI.
        if canAutoSummarize {
            summarize(id, confirmedCloud: false)
        }
    }

    private func failTranscription(_ id: UUID, _ message: String) {
        teardownEngine()
        activeTranscribeID = nil
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
              let transcript = meeting.transcript, !transcript.isEmpty else { return }
        if !providerIsLocal() && !confirmedCloud {
            lastMessage = "Summarizing with a cloud provider needs your confirmation."
            return
        }

        var working = meeting
        working.status = .summarizing
        persist(working)

        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await MeetingSummarizer.run(transcript: transcript) { instruction, input in
                    try await summarize(instruction, input)
                }
                await MainActor.run { self.finishSummary(id, transcript: transcript, summary: summary) }
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
        if id == activeTranscribeID { teardownEngine(); activeTranscribeID = nil }
        meetings = store.delete(id: id)
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
        out += (meeting.transcript ?? "(no transcript)").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
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
