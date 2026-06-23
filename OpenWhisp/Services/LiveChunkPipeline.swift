import Foundation

/// Pure ordering/sequencing state machine for live-chunk dictation.
///
/// In live-chunk mode, audio is sliced into chunks that transcribe **concurrently**
/// (up to `maxConcurrent`) and therefore complete **out of order**, yet must be
/// emitted to the user **in order** once a contiguous prefix is available. This
/// type owns exactly that bookkeeping — sequence assignment, the in-flight count,
/// the out-of-order results buffer, the ordered-output cursor, the downstream
/// insertion queue, and drain detection — and nothing else.
///
/// It performs NO side effects (no transcription, no file IO, no text insertion).
/// Each mutating call returns *what the caller should do next* (dispatch these
/// chunk IDs, emit these texts in order), and AppState carries out those effects.
/// Being pure data logic, it lives in OpenWhispCore and is unit-tested — this was
/// previously untested machinery implicated in live-chunk bugs.
///
/// The caller is responsible for owning the chunk *payloads* (e.g. file URLs)
/// keyed by the `ChunkID` this returns; the pipeline only tracks sequencing.
struct LiveChunkPipeline {
    /// Opaque identifier for a queued chunk, in arrival order.
    typealias ChunkID = Int

    /// Max chunks transcribing at once (matches the prior `liveMaxConcurrentTranscriptions`).
    let maxConcurrent: Int

    // Capture (transcription) stage
    private var nextChunkSequence = 0
    private var pending: [ChunkID] = []
    private var inFlightCount = 0

    // Ordering stage: results arrive keyed by sequence, possibly out of order.
    private var results: [ChunkID: String] = [:]
    private var nextOutputSequence = 0

    // Insertion stage: ordered texts awaiting (possibly async) insertion downstream.
    private var insertionQueue: [String] = []
    private var insertionInFlight = false

    /// User-facing count of chunks queued this session (only ever increments).
    private(set) var queuedCount = 0

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    // MARK: - Capture stage

    /// Register a newly-recorded chunk. Returns its `ChunkID` so the caller can
    /// associate the payload (file URL) with it.
    mutating func enqueue() -> ChunkID {
        let id = nextChunkSequence
        nextChunkSequence += 1
        pending.append(id)
        queuedCount += 1
        return id
    }

    /// Pull the chunk IDs that should start transcribing now, respecting the
    /// concurrency cap. Each returned ID is counted as in-flight.
    mutating func dispatchable() -> [ChunkID] {
        var dispatched: [ChunkID] = []
        while inFlightCount < maxConcurrent, !pending.isEmpty {
            let id = pending.removeFirst()
            inFlightCount += 1
            dispatched.append(id)
        }
        return dispatched
    }

    // MARK: - Ordering stage

    /// Record a finished (or empty/failed) transcription for `id` and decrement
    /// the in-flight count. Does NOT emit — the caller then frees concurrency via
    /// `dispatchable()` and pulls emittable text via `takeOrderedReady()`, matching
    /// the original record → dispatch → flush ordering.
    mutating func complete(_ id: ChunkID, text: String) {
        results[id] = text
        inFlightCount = max(0, inFlightCount - 1)
    }

    /// Emit and consume the contiguous prefix of results from the output cursor,
    /// dropping empties (a failed/silent chunk advances the cursor without
    /// producing text). Returns texts in chunk order.
    mutating func takeOrderedReady() -> [String] {
        var emitted: [String] = []
        while let text = results.removeValue(forKey: nextOutputSequence) {
            if !text.isEmpty { emitted.append(text) }
            nextOutputSequence += 1
        }
        return emitted
    }

    // MARK: - Insertion stage

    /// Append ordered texts to the insertion queue.
    mutating func queueForInsertion(_ texts: [String]) {
        insertionQueue.append(contentsOf: texts)
    }

    /// If nothing is currently being inserted and the queue is non-empty, mark
    /// the next item in-flight and return it; otherwise nil. Mirrors the prior
    /// single-in-flight insertion choke point.
    mutating func nextInsertion() -> String? {
        guard !insertionInFlight, !insertionQueue.isEmpty else { return nil }
        insertionInFlight = true
        return insertionQueue.removeFirst()
    }

    /// Mark the in-flight insertion done (call before pulling `nextInsertion()` again).
    mutating func finishInsertion() {
        insertionInFlight = false
    }

    // MARK: - Drain detection

    /// True when nothing is pending, in flight, buffered, queued, or inserting —
    /// i.e. the session can be finalized. Matches the prior `livePipelineIsDrained`.
    var isDrained: Bool {
        pending.isEmpty
            && inFlightCount == 0
            && results.isEmpty
            && insertionQueue.isEmpty
            && !insertionInFlight
    }

    /// Reset all sequencing state for a fresh session. Does NOT touch payloads —
    /// the caller cleans up any files it still holds for pending chunks.
    mutating func reset() {
        nextChunkSequence = 0
        pending.removeAll()
        inFlightCount = 0
        results.removeAll()
        nextOutputSequence = 0
        insertionQueue.removeAll()
        insertionInFlight = false
        queuedCount = 0
    }
}
