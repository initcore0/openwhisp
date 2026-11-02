import Foundation
import OpenWhispCore

/// Tracks each MCP `tools/call` from arrival to reply so a
/// `notifications/cancelled` from the client can be honored.
///
/// The MCP server reads stdin on one thread and runs tool calls one at a time on
/// a worker queue, so a cancel can arrive while its request is still queued or
/// while it is running. This type owns the decision of what a cancel means in
/// each state; the server just carries it out. Thread-safe.
///
/// Per the MCP cancellation contract, a cancelled request gets NO response.
final class MCPRequestTracker {

    /// What the server must do for a `notifications/cancelled`.
    enum CancelAction: Equatable {
        /// Unknown, already finished, or already cancelled: nothing to do.
        case ignore
        /// Mark only: a queued call will be skipped, a running non-dictate call
        /// runs to completion and its reply is dropped.
        case suppressOnly
        /// A dictation is running: stop it over the bridge (`dictate.cancel`) so
        /// the mic closes now, and drop its reply.
        case cancelDictation
    }

    private struct Entry {
        let id: BridgeWire.RPCID
        let isDictate: Bool
        var running = false
        var cancelled = false
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    /// Register a call as it arrives (before it is queued). A nil id (a
    /// malformed notification-style `tools/call`) can't be cancelled, so it
    /// isn't tracked.
    func enqueue(_ id: BridgeWire.RPCID?, isDictate: Bool) {
        guard let id else { return }
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(id: id, isDictate: isDictate))
    }

    /// Mark a call as starting. Returns false when it was cancelled while queued
    /// — the caller must skip it (and still call ``finish(_:)``).
    func start(_ id: BridgeWire.RPCID?) -> Bool {
        guard let id else { return true }
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return true }
        if entries[i].cancelled { return false }
        entries[i].running = true
        return true
    }

    /// Apply a client cancel for `id`.
    func cancel(_ id: BridgeWire.RPCID) -> CancelAction {
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.id == id }), !entries[i].cancelled else {
            return .ignore
        }
        entries[i].cancelled = true
        return entries[i].running && entries[i].isDictate ? .cancelDictation : .suppressOnly
    }

    /// Cancel everything (stdin closed: the client is gone). Returns true when a
    /// dictation was running and must be stopped over the bridge.
    func cancelAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        var dictationRunning = false
        for i in entries.indices where !entries[i].cancelled {
            entries[i].cancelled = true
            if entries[i].running && entries[i].isDictate { dictationRunning = true }
        }
        return dictationRunning
    }

    /// Whether a cancelled call is still running (the dictate.cancel retry loop
    /// keeps going while this is true).
    func isRunningAndCancelled(_ id: BridgeWire.RPCID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.contains { $0.id == id && $0.running && $0.cancelled }
    }

    /// The running dictation's id, if any.
    func runningDictation() -> BridgeWire.RPCID? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.running && $0.isDictate }?.id
    }

    /// Remove a call once it is done. Returns whether its reply should be sent
    /// (false when it was cancelled).
    @discardableResult
    func finish(_ id: BridgeWire.RPCID?) -> Bool {
        guard let id else { return true }
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return true }
        let cancelled = entries[i].cancelled
        entries.remove(at: i)
        return !cancelled
    }
}
