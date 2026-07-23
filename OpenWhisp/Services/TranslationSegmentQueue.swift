import Foundation

/// The pure ordering/backpressure core of the dual-runtime translator's queue
/// (`LiveTranslationCoordinator` wraps it with the actual whisper file-engine
/// calls). Kept pure so the invariants that matter — single in-flight,
/// drop-oldest backpressure, and IN-ORDER segment output regardless of when each
/// translation completes — are `swift test`-able with no audio or engine.
///
/// Model: chunks are enqueued with `enqueue`; `next()` hands out the oldest
/// pending chunk to translate (marking one in-flight) — the caller must not call
/// `next()` again until it reports the result via `complete`. Because exactly one
/// chunk is ever in flight and `complete` appends to `segments` in the same order
/// chunks were dispatched, out-of-order *completion timing* cannot reorder output:
/// there is only ever one outstanding job, so its result is always the next
/// segment. The queue also enforces `maxPending` by dropping the OLDEST waiting
/// chunks (never unbounded growth).
public struct TranslationSegmentQueue {

    /// A pending chunk plus the monotonic id it was enqueued under (so a caller
    /// can correlate an async completion back to the right dispatch).
    public struct Dispatched: Equatable {
        public let id: Int
        public let chunk: [Float]
    }

    public let maxPending: Int
    private var pending: [Dispatched] = []
    private var nextID = 0
    private var inFlightID: Int?
    /// Completed translated segments, in dispatch order.
    public private(set) var segments: [String] = []
    /// How many oldest chunks were dropped for backpressure (diagnostics/tests).
    public private(set) var droppedCount = 0

    public init(maxPending: Int = 6) {
        self.maxPending = max(1, maxPending)
    }

    public var isInFlight: Bool { inFlightID != nil }
    public var pendingCount: Int { pending.count }
    public var isDrained: Bool { inFlightID == nil && pending.isEmpty }

    /// Add a chunk. Drops the oldest pending chunks when the backlog exceeds
    /// `maxPending` (the in-flight one is never dropped).
    public mutating func enqueue(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        pending.append(Dispatched(id: nextID, chunk: chunk))
        nextID += 1
        if pending.count > maxPending {
            let drop = pending.count - maxPending
            pending.removeFirst(drop)
            droppedCount += drop
        }
    }

    /// Dispatch the oldest pending chunk if nothing is in flight. Returns the
    /// chunk (and its id) the caller should now translate, or nil when a job is
    /// already in flight or nothing is pending.
    public mutating func next() -> Dispatched? {
        guard inFlightID == nil, !pending.isEmpty else { return nil }
        let d = pending.removeFirst()
        inFlightID = d.id
        return d
    }

    /// Report a dispatched chunk's translation. Appends non-empty text to
    /// `segments` in dispatch order and frees the in-flight slot. A completion for
    /// an id that isn't the one in flight (a stale/duplicate callback) is ignored.
    /// Returns the accepted segment (nil if empty/ignored) so the caller can
    /// forward it to the overlay.
    @discardableResult
    public mutating func complete(id: Int, text: String) -> String? {
        guard inFlightID == id else { return nil }
        inFlightID = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        segments.append(trimmed)
        return trimmed
    }

    /// The concatenated English transcript so far (ordered, space-joined).
    public var joinedText: String {
        segments.joined(separator: " ")
    }

    /// Reset for a new session.
    public mutating func reset() {
        pending.removeAll()
        segments.removeAll()
        inFlightID = nil
        droppedCount = 0
        nextID = 0
    }
}
