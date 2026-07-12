import Foundation
import CryptoKit

/// The **pure, boring v1 P2P-sync merge policy** (MAK-51 WP6) — the single funnel
/// both sides of the LAN link run to combine two devices' config + history.
/// Foundation + CryptoKit only, so it lives in `OpenWhispCore` and the ENTIRE
/// policy is exhaustively unit-tested with `swift test` (no sockets, no AppKit).
///
/// The transport (`LANBridgeServer`, TLS-PSK) and the live-store I/O (`AppState`,
/// the loopback harness) both call into these pure functions; nothing about the
/// merge decision lives in a socket handler, so "what wins a conflict" is provable
/// in isolation and can never drift between the two callers.
///
/// **Merge policy (v1, deliberately boring — ARCHITECTURE §6.5):**
///   - **vocabulary** = union by `Substitution.id`, newer `updatedAt` wins per
///     entry; `terms` = set union (order-preserving, first-seen wins).
///   - **history** = append-only union by entry `id` (an id already present is
///     never overwritten — history entries are immutable once recorded).
///   - **profiles / modes** = last-writer-wins per object by `updatedAt`.
///   - **packs** = content-hash identity (a pack the receiver already has by
///     content hash is a no-op; packs are read-only bundled resources on the Mac,
///     so the Mac never *applies* an incoming pack — see ``SyncState``).
///
/// Every merge is **idempotent**: applying the same incoming payload twice leaves
/// the receiver byte-identical to after the first apply (the wiring lesson demands
/// a test that proves this — see `SyncMergeTests`).
///
/// Missing `updatedAt` stamps decode as the epoch (`ConfigBundle` v3 note), so any
/// stamped v3 edit always beats unstamped legacy data in every last-writer-wins
/// comparison here.
public enum SyncMerge {

    // MARK: - Content hashing (manifest identity)

    /// A stable content digest of any `Encodable` section, used ONLY as opaque
    /// identity in a `sync.manifest` (never reversed, never authorization). The
    /// encoder sorts keys and omits escaping so two devices that hold equal data
    /// produce equal hashes regardless of in-memory ordering. Returns "" for a
    /// nil/absent section so the manifest can distinguish "no section" (empty
    /// string) from "empty section" (the hash of `[]`).
    public static func contentHash<T: Encodable>(_ value: T?) -> String {
        guard let value else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A fixed date strategy so `Date` fields hash identically across devices
        // (the default per-instance strategy is already deterministic, but pin it).
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Vocabulary

    /// Union two vocabularies by the boring v1 policy: substitutions unioned by
    /// `id` with newer `updatedAt` winning per entry, terms set-unioned
    /// (order-preserving, `local` first). Pure; returns a new `Vocabulary`.
    ///
    /// The returned substitution order is deterministic — `local`'s existing order,
    /// then any brand-new incoming ids appended in `incoming`'s order — so two
    /// applies of the same payload produce byte-identical output (idempotency).
    public static func mergeVocabulary(local: Vocabulary, incoming: Vocabulary) -> Vocabulary {
        // Substitutions: index local by id, then fold incoming in.
        var order: [Vocabulary.Substitution.ID] = local.substitutions.map(\.id)
        var byID: [Vocabulary.Substitution.ID: Vocabulary.Substitution] =
            Dictionary(local.substitutions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for sub in incoming.substitutions {
            if let existing = byID[sub.id] {
                // Newer updatedAt wins. Ties keep the LOCAL entry (stable — a tie is
                // not a real edit, and keeping local makes the merge idempotent).
                if sub.updatedAt > existing.updatedAt {
                    byID[sub.id] = sub
                }
            } else {
                byID[sub.id] = sub
                order.append(sub.id)
            }
        }
        let mergedSubs = order.compactMap { byID[$0] }

        // Terms: order-preserving set union, local first.
        var seenTerms = Set(local.terms)
        var mergedTerms = local.terms
        for term in incoming.terms where !seenTerms.contains(term) {
            seenTerms.insert(term)
            mergedTerms.append(term)
        }

        return Vocabulary(terms: mergedTerms, substitutions: mergedSubs)
    }

    /// How many substitutions an incoming vocabulary would actually CHANGE in
    /// `local` (a new id, or a strictly-newer edit to an existing id). Terms that
    /// are net-new count too. Pure; drives the `sync.push` merged-count report and
    /// the idempotency assertion (a second push reports 0).
    public static func vocabularyChangeCount(local: Vocabulary, incoming: Vocabulary) -> Int {
        let localByID = Dictionary(local.substitutions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = 0
        for sub in incoming.substitutions {
            if let existing = localByID[sub.id] {
                if sub.updatedAt > existing.updatedAt { changed += 1 }
            } else {
                changed += 1
            }
        }
        let localTerms = Set(local.terms)
        changed += incoming.terms.filter { !localTerms.contains($0) }.count
        return changed
    }

    // MARK: - Profiles / Modes (last-writer-wins per object by updatedAt)

    /// Merge two profile lists last-writer-wins per object by `updatedAt`, keyed by
    /// `id`. Deterministic order: local order first, then net-new incoming ids in
    /// incoming order. Idempotent.
    public static func mergeProfiles(local: [AppProfile], incoming: [AppProfile]) -> [AppProfile] {
        mergeLWW(local: local, incoming: incoming, id: { $0.id }, updatedAt: { $0.updatedAt })
    }

    /// How many profiles an incoming list would change (new id, or strictly-newer).
    public static func profilesChangeCount(local: [AppProfile], incoming: [AppProfile]) -> Int {
        lwwChangeCount(local: local, incoming: incoming, id: { $0.id }, updatedAt: { $0.updatedAt })
    }

    /// Merge two Mode lists last-writer-wins per object by `updatedAt`, keyed by
    /// `id`. Same determinism/idempotency as ``mergeProfiles(local:incoming:)``.
    public static func mergeModes(local: [Mode], incoming: [Mode]) -> [Mode] {
        mergeLWW(local: local, incoming: incoming, id: { $0.id }, updatedAt: { $0.updatedAt })
    }

    /// How many Modes an incoming list would change (new id, or strictly-newer).
    public static func modesChangeCount(local: [Mode], incoming: [Mode]) -> Int {
        lwwChangeCount(local: local, incoming: incoming, id: { $0.id }, updatedAt: { $0.updatedAt })
    }

    // Shared last-writer-wins list merge. `local` order is preserved; a conflict
    // replaces the local element IN PLACE (so order is stable across applies);
    // net-new incoming elements are appended in incoming order. Ties keep local.
    private static func mergeLWW<Element, ID: Hashable>(
        local: [Element], incoming: [Element],
        id: (Element) -> ID, updatedAt: (Element) -> Date
    ) -> [Element] {
        var result = local
        var indexByID: [ID: Int] = [:]
        for (i, e) in local.enumerated() { indexByID[id(e)] = i }

        for e in incoming {
            let key = id(e)
            if let i = indexByID[key] {
                if updatedAt(e) > updatedAt(result[i]) {
                    result[i] = e
                }
            } else {
                indexByID[key] = result.count
                result.append(e)
            }
        }
        return result
    }

    private static func lwwChangeCount<Element, ID: Hashable>(
        local: [Element], incoming: [Element],
        id: (Element) -> ID, updatedAt: (Element) -> Date
    ) -> Int {
        var current: [ID: Date] = [:]
        for e in local { current[id(e)] = updatedAt(e) }
        var changed = 0
        for e in incoming {
            if let existing = current[id(e)] {
                if updatedAt(e) > existing { changed += 1 }
            } else {
                changed += 1
            }
        }
        return changed
    }

    // MARK: - History (append-only union by id)

    /// Append-only union of two history lists by entry `id`: an id already present
    /// locally is left untouched (history entries are immutable once recorded);
    /// genuinely new incoming entries are appended. Deterministic order: local
    /// order first, then net-new incoming entries in incoming order.
    ///
    /// The result is NOT re-sorted by date here (the caller — `AppState` — owns the
    /// newest-first invariant and the retention cap); this returns the merged set
    /// in a stable, idempotent order and lets the store re-sort/trim.
    public static func mergeHistory(
        local: [TranscriptionEntry], incoming: [TranscriptionEntry]
    ) -> [TranscriptionEntry] {
        var seen = Set(local.map(\.id))
        var result = local
        for entry in incoming where !seen.contains(entry.id) {
            seen.insert(entry.id)
            result.append(entry)
        }
        return result
    }

    /// How many incoming history entries are genuinely new to `local` (append-only,
    /// so only net-new ids count). Drives the merged-count report + idempotency.
    public static func historyChangeCount(
        local: [TranscriptionEntry], incoming: [TranscriptionEntry]
    ) -> Int {
        let localIDs = Set(local.map(\.id))
        return incoming.filter { !localIDs.contains($0.id) }.count
    }

    // MARK: - Bundle-level merge

    /// The result of merging an incoming `ConfigBundle` (+ history delta) into a
    /// device's local state: the new sections to persist plus a per-section count of
    /// what actually changed. Sections the incoming bundle omitted are returned
    /// unchanged (nil count contribution).
    public struct Outcome: Equatable {
        public var vocabulary: Vocabulary
        public var profiles: [AppProfile]
        public var modes: [Mode]
        public var history: [TranscriptionEntry]
        public var counts: BridgeWire.SyncMergedCounts

        public init(
            vocabulary: Vocabulary, profiles: [AppProfile], modes: [Mode],
            history: [TranscriptionEntry], counts: BridgeWire.SyncMergedCounts
        ) {
            self.vocabulary = vocabulary
            self.profiles = profiles
            self.modes = modes
            self.history = history
            self.counts = counts
        }
    }

    /// Merge an incoming bundle + history delta into a local snapshot, applying the
    /// boring v1 policy section-by-section. Only sections present in `incoming.bundle`
    /// are merged; an absent section leaves the local section untouched and its
    /// count 0. `packs` are never merged into the Mac (bundled read-only resources);
    /// the count is reported from the manifest side, not here.
    ///
    /// Pure and idempotent: `merge(local, x)` then `merge(result, x)` yields the same
    /// sections and a zero count the second time.
    public static func merge(
        localVocabulary: Vocabulary,
        localProfiles: [AppProfile],
        localModes: [Mode],
        localHistory: [TranscriptionEntry],
        incomingBundle: ConfigBundle,
        incomingHistory: [TranscriptionEntry]
    ) -> Outcome {
        var counts = BridgeWire.SyncMergedCounts()

        var mergedVocab = localVocabulary
        if let inVocab = incomingBundle.vocabulary {
            counts.vocabulary = vocabularyChangeCount(local: localVocabulary, incoming: inVocab)
            mergedVocab = mergeVocabulary(local: localVocabulary, incoming: inVocab)
        }

        var mergedProfiles = localProfiles
        if let inProfiles = incomingBundle.profiles {
            counts.profiles = profilesChangeCount(local: localProfiles, incoming: inProfiles)
            mergedProfiles = mergeProfiles(local: localProfiles, incoming: inProfiles)
        }

        var mergedModes = localModes
        if let inModes = incomingBundle.modes {
            counts.modes = modesChangeCount(local: localModes, incoming: inModes)
            mergedModes = mergeModes(local: localModes, incoming: inModes)
        }

        counts.history = historyChangeCount(local: localHistory, incoming: incomingHistory)
        let mergedHistory = mergeHistory(local: localHistory, incoming: incomingHistory)

        return Outcome(
            vocabulary: mergedVocab, profiles: mergedProfiles, modes: mergedModes,
            history: mergedHistory, counts: counts
        )
    }

    // MARK: - History delta (for sync.pull)

    /// The history entries strictly newer than an ISO-8601 cursor, for a `sync.pull`
    /// delta. A nil/blank/unparseable cursor returns the full list (a first full
    /// sync). Comparison is strict `>` so re-pulling with the last-seen cursor
    /// returns nothing (idempotent). Order preserved from `all`.
    public static func historyDelta(_ all: [TranscriptionEntry], sinceCursor: String?) -> [TranscriptionEntry] {
        guard let cursor = sinceCursor,
              !cursor.isEmpty,
              let cutoff = BridgeWire.date(fromISO8601: cursor) else {
            return all
        }
        return all.filter { $0.date > cutoff }
    }

    // MARK: - Paged history (frame-cap safe)

    /// One page of the FULL history log, keyed by a total order (date, then id) so
    /// no entry is ever skipped by an equal-timestamp tie — the puller keeps
    /// re-pulling until `hasMore` is false, so it always sees every entry the
    /// server has, including older-but-unseen ones. This is the frame-cap-safe
    /// replacement for shipping the whole log in one NDJSON frame.
    ///
    /// - `afterCursor`: the previous page's `nextCursor` (nil → first page).
    /// - `limit`: max entries this page (clamped to ≥ 1).
    /// Returns the page, the cursor for the next page (nil when drained), and
    /// whether more remain.
    public struct HistoryPage: Equatable, Sendable {
        public let entries: [TranscriptionEntry]
        public let nextCursor: String?
        public let hasMore: Bool
    }

    /// A total-order cursor: ISO-8601 date + "|" + entry id, so ties on `date`
    /// still advance deterministically.
    private static func pageCursor(_ e: TranscriptionEntry) -> String {
        BridgeWire.iso8601String(from: e.date) + "|" + e.id.uuidString
    }

    private static func orderedAscending(_ all: [TranscriptionEntry]) -> [TranscriptionEntry] {
        all.sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func historyPage(
        _ all: [TranscriptionEntry], afterCursor: String?, limit: Int
    ) -> HistoryPage {
        let pageSize = max(1, limit)
        let ordered = orderedAscending(all)
        let start: Int
        if let cursor = afterCursor, !cursor.isEmpty {
            // Advance past every entry whose (date,id) key is <= the cursor.
            start = ordered.firstIndex { pageCursor($0) > cursor } ?? ordered.count
        } else {
            start = 0
        }
        let end = min(start + pageSize, ordered.count)
        let page = Array(ordered[start..<end])
        let hasMore = end < ordered.count
        return HistoryPage(
            entries: page,
            nextCursor: page.last.map(pageCursor),
            hasMore: hasMore
        )
    }

    // MARK: - Manifest head

    /// The `SyncHistoryHead` for a history list: count + the id/ISO-date of the
    /// NEWEST entry (max by `date`), the cursor a puller passes back. Empty list →
    /// count 0, nil id/date. Pure so both the app host and the harness agree.
    public static func historyHead(_ entries: [TranscriptionEntry]) -> BridgeWire.SyncHistoryHead {
        guard let newest = entries.max(by: { $0.date < $1.date }) else {
            return BridgeWire.SyncHistoryHead(count: 0, newestID: nil, newestDate: nil)
        }
        return BridgeWire.SyncHistoryHead(
            count: entries.count,
            newestID: newest.id,
            newestDate: BridgeWire.iso8601String(from: newest.date)
        )
    }

    /// The newest `updatedAt` across a stamped list, as an ISO-8601 string, or nil
    /// when empty — the coarse per-section LWW signal in a manifest's `updatedAt`
    /// map. Pure.
    public static func newestUpdatedAt<Element>(
        _ list: [Element], updatedAt: (Element) -> Date
    ) -> String? {
        guard let newest = list.map(updatedAt).max() else { return nil }
        return BridgeWire.iso8601String(from: newest)
    }
}
