import Foundation

/// One-shot, on-device transcription of a single local file for the Agent Bridge
/// `transcribe.file` verb (MAK-83).
///
/// This is the effectful glue AppState's `bridgeTranscribeFile` delegates to, kept
/// OUT of AppState so the god-object ratchet doesn't grow: it reuses the EXACT file
/// pipeline the batch queue / watch folders / history re-transcribe already use —
/// `MediaFileDecoder` (AVFoundation → 16 kHz mono WAV, handling mp3/m4a/mp4/… for
/// free), the Foundation-only `FileChunkPlanner`, and a fresh
/// `FileTranscriptionEngine` from the user's configured `EngineConfig`. Nothing
/// here is invented; it's the coordinator's decode→transcribe→join loop distilled
/// to a single blocking-friendly async call with no persisted queue.
///
/// App-target only (AVFoundation via `MediaFileDecoder`, plus the concrete
/// engines). The path VALIDATION lives in the pure, tested
/// `TranscribeFileRequest`; this type assumes it already passed.
@MainActor
final class AgentFileTranscriber {

    /// A per-run progress signal (chunkIndex, chunkCount) for the bridge to relay
    /// as MCP `notifications/progress`. Fires on the main actor as each chunk lands.
    typealias ProgressHandler = (_ completedChunks: Int, _ totalChunks: Int) -> Void

    /// Retain the in-flight transcriber for the life of a call so its engine (and
    /// its subprocess/callbacks) isn't deallocated mid-transcription.
    private var engine: FileTranscriptionEngine?
    private var workDir: URL?
    /// True while a call is in flight — one file at a time (a fresh engine per
    /// call must not contend with another agent transcription).
    private var busy = false

    /// The bridge entry point: validate the agent-supplied `path` (pure
    /// `TranscribeFileRequest`), reject a concurrent call, then decode + transcribe
    /// with `config` and deliver the transcript (or a mapped error) to `completion`.
    func run(
        path: String, language: String?,
        config: FileTranscriptionCoordinator.EngineConfig,
        completion: @escaping (Result<BridgeWire.TranscribeFileResult, BridgeWire.ErrorObject>) -> Void
    ) {
        let validated: TranscribeFileRequest.Validated
        switch TranscribeFileRequest.validate(path: path, language: language) {
        case .success(let v): validated = v
        case .failure(let rejection): completion(.failure(rejection.errorObject)); return
        }
        guard !busy else {
            completion(.failure(.domain(.busy, message: "another file is already transcribing; try again shortly")))
            return
        }
        busy = true
        Task { @MainActor in
            let result = await self.transcribe(
                canonicalPath: validated.canonicalPath, config: config, language: validated.language)
            self.busy = false
            completion(result)
        }
    }

    /// Transcribe `canonicalPath` (already validated) with `config`, optionally
    /// overriding the engine's language for this call. Returns the joined transcript
    /// + decoded duration, or throws a `BridgeWire.ErrorObject`.
    ///
    /// One chunk at a time (bounded memory for a long file); each 16 kHz WAV chunk
    /// is decoded then transcribed, and `progress` fires as each completes.
    func transcribe(
        canonicalPath: String,
        config: FileTranscriptionCoordinator.EngineConfig,
        language: String?,
        progress: ProgressHandler? = nil
    ) async -> Result<BridgeWire.TranscribeFileResult, BridgeWire.ErrorObject> {
        let source = URL(fileURLWithPath: canonicalPath)

        let duration: Double
        do {
            duration = try await MediaFileDecoder.duration(of: source)
        } catch {
            return .failure(.domain(.unsupportedFormat, message: error.localizedDescription))
        }

        let plan = FileChunkPlanner.plan(duration: duration)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhisp-agent-transcribe-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(.domain(.internalError, message: "couldn't create a work directory: \(error.localizedDescription)"))
        }
        workDir = dir
        defer {
            try? FileManager.default.removeItem(at: dir)
            workDir = nil
            engine?.stopServer()
            engine = nil
        }

        let engine = config.makeEngine()
        self.engine = engine
        // The agent's language hint wins over the user's default for this call.
        let effectiveLanguage: String = {
            let hint = language?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (hint?.isEmpty ?? true) ? config.languageSetting : hint!
        }()

        var chunkTexts: [Int: String] = [:]
        var lastError: String?

        for chunk in plan {
            let wav = dir.appendingPathComponent("chunk-\(chunk.index).wav")
            do {
                try await MediaFileDecoder.decodeRange(
                    source: source, start: chunk.start,
                    end: chunk.index == plan.count - 1 ? nil : chunk.end,
                    outputURL: wav
                )
            } catch {
                return .failure(.domain(.unsupportedFormat, message: error.localizedDescription))
            }

            let outcome = await transcribeOneChunk(
                engine: engine, wavPath: wav.path,
                language: effectiveLanguage, config: config
            )
            chunkTexts[chunk.index] = outcome.text
            if let err = outcome.error { lastError = err }
            progress?(chunk.index + 1, plan.count)
        }

        let joined = plan
            .compactMap { chunkTexts[$0.index]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Nothing came back AND a chunk errored → surface the failure, not a silent
        // empty transcript (mirrors the coordinator's failActive-on-empty rule).
        if joined.isEmpty, let lastError {
            return .failure(.domain(.internalError, message: "transcription failed: \(lastError)"))
        }
        return .success(BridgeWire.TranscribeFileResult(text: joined, durationSeconds: duration))
    }

    /// Run one already-decoded WAV chunk through the engine, bridging its
    /// callback API to an async result.
    private func transcribeOneChunk(
        engine: FileTranscriptionEngine, wavPath: String,
        language: String, config: FileTranscriptionCoordinator.EngineConfig
    ) async -> (text: String, error: String?) {
        await withCheckedContinuation { cont in
            let requestID = UUID()
            var resumed = false
            engine.onTranscriptionComplete = { rid, text in
                guard rid == requestID, !resumed else { return }
                resumed = true
                cont.resume(returning: (text: text, error: nil))
            }
            engine.onTranscriptionError = { rid, message in
                guard rid == requestID, !resumed else { return }
                resumed = true
                cont.resume(returning: (text: "", error: message))
            }
            engine.transcribe(
                requestID: requestID,
                binaryPath: config.binaryPath,
                modelPath: config.modelPath,
                language: language,
                wavPath: wavPath,
                deleteWhenDone: true,
                backend: config.backend,
                prompt: config.prompt
            )
        }
    }
}

// MARK: - AppState conformance seam (kept off AppState.swift for the LOC ratchet)

extension AppState {
    /// One retained transcriber for agent `transcribe.file` calls (single-flight).
    private static let sharedAgentFileTranscriber = AgentFileTranscriber()

    /// Agent Bridge `transcribe.file` (MAK-83): delegate wholesale to the
    /// transcriber, supplying the user's configured file engine. All the
    /// validate/decode/engine logic lives in `AgentFileTranscriber`; AppState only
    /// hands over the engine config. Only ever reads the file the agent named.
    func bridgeTranscribeFile(
        clientName: String, path: String, language: String?,
        completion: @escaping (Result<BridgeWire.TranscribeFileResult, BridgeWire.ErrorObject>) -> Void
    ) {
        Self.sharedAgentFileTranscriber.run(
            path: path, language: language,
            config: fileEngineConfig(), completion: completion)
    }
}
