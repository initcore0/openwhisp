import XCTest
@testable import OpenWhispCore

/// The MAK-51 WP6 merge-policy matrix: every syncable entity × the conflict axes
/// (newer / older / absent-on-one-side / both-changed) × **idempotency** (applying
/// the same payload twice = no further change). The pure `SyncMerge` funnel is the
/// single source of "what wins", so this is where the boring v1 policy is proven —
/// the transport just carries bytes.
final class SyncMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)   // oldest
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)   // newest

    // MARK: - Vocabulary substitutions

    func testVocabIncomingNewerWins() {
        let id = UUID()
        let local = Vocabulary(terms: [], substitutions: [
            .init(id: id, from: "clod", to: "cloud", updatedAt: t0)
        ])
        let incoming = Vocabulary(terms: [], substitutions: [
            .init(id: id, from: "clod", to: "Claude", updatedAt: t2)
        ])
        let merged = SyncMerge.mergeVocabulary(local: local, incoming: incoming)
        XCTAssertEqual(merged.substitutions.count, 1)
        XCTAssertEqual(merged.substitutions.first?.to, "Claude")
        XCTAssertEqual(SyncMerge.vocabularyChangeCount(local: local, incoming: incoming), 1)
    }

    func testVocabIncomingOlderLoses() {
        let id = UUID()
        let local = Vocabulary(terms: [], substitutions: [
            .init(id: id, from: "clod", to: "Claude", updatedAt: t2)
        ])
        let incoming = Vocabulary(terms: [], substitutions: [
            .init(id: id, from: "clod", to: "cloud", updatedAt: t0)
        ])
        let merged = SyncMerge.mergeVocabulary(local: local, incoming: incoming)
        XCTAssertEqual(merged.substitutions.first?.to, "Claude")
        XCTAssertEqual(SyncMerge.vocabularyChangeCount(local: local, incoming: incoming), 0)
    }

    func testVocabTieBreaksDeterministicallyAndConverges() {
        // An exact updatedAt tie with DIFFERENT content must not "keep local" on
        // both sides — that diverged forever with both devices reporting 0
        // changes. The tie-break is deterministic (larger content hash wins), so
        // A merging B and B merging A pick the SAME winner.
        let id = UUID()
        let a = Vocabulary(terms: [], substitutions: [.init(id: id, from: "a", to: "LOCAL", updatedAt: t1)])
        let b = Vocabulary(terms: [], substitutions: [.init(id: id, from: "a", to: "REMOTE", updatedAt: t1)])
        let aMergesB = SyncMerge.mergeVocabulary(local: a, incoming: b)
        let bMergesA = SyncMerge.mergeVocabulary(local: b, incoming: a)
        XCTAssertEqual(aMergesB.substitutions.first?.to, bMergesA.substitutions.first?.to,
            "both sides must converge on the same tie winner")
        // Idempotent: re-applying the same incoming changes nothing further.
        XCTAssertEqual(SyncMerge.mergeVocabulary(local: aMergesB, incoming: b), aMergesB)
        // A SAME-content tie is a no-op and reports zero changes.
        let same = Vocabulary(terms: [], substitutions: [.init(id: id, from: "a", to: "LOCAL", updatedAt: t1)])
        XCTAssertEqual(SyncMerge.vocabularyChangeCount(local: a, incoming: same), 0)
        XCTAssertEqual(SyncMerge.mergeVocabulary(local: a, incoming: same), a)
    }

    func testTwoWayMergeConvergesToEqualCanonicalHashes() {
        // The convergence property a hash-driven sync planner depends on: after A
        // merges B and B merges A, the two devices' MANIFEST hashes must be equal
        // even though each preserves its own local ordering.
        let shared = UUID(), t = t1
        let a = Vocabulary(terms: ["zeta", "alpha"], substitutions: [
            .init(id: shared, from: "x", to: "X", updatedAt: t),
            .init(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, from: "a", to: "A", updatedAt: t),
        ])
        let b = Vocabulary(terms: ["alpha", "midway"], substitutions: [
            .init(id: shared, from: "x", to: "X", updatedAt: t),
            .init(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!, from: "b", to: "B", updatedAt: t),
        ])
        let aSide = SyncMerge.mergeVocabulary(local: a, incoming: b)
        let bSide = SyncMerge.mergeVocabulary(local: b, incoming: a)
        // Different in-memory order (local-first)…
        XCTAssertNotEqual(aSide.substitutions.map(\.id), bSide.substitutions.map(\.id))
        // …but identical canonical hashes: the devices read as in-sync.
        XCTAssertEqual(SyncMerge.vocabularyHash(aSide), SyncMerge.vocabularyHash(bSide))
    }

    func testVocabIncomingAbsentEntryPreserved() {
        // A substitution only local has must survive (union, not replace).
        let onlyLocal = UUID()
        let local = Vocabulary(terms: [], substitutions: [.init(id: onlyLocal, from: "x", to: "y", updatedAt: t1)])
        let incoming = Vocabulary(terms: [], substitutions: [])
        let merged = SyncMerge.mergeVocabulary(local: local, incoming: incoming)
        XCTAssertEqual(merged.substitutions.map(\.id), [onlyLocal])
    }

    func testVocabIncomingNewEntryAppended() {
        let localID = UUID(); let remoteID = UUID()
        let local = Vocabulary(terms: [], substitutions: [.init(id: localID, from: "a", to: "b", updatedAt: t1)])
        let incoming = Vocabulary(terms: [], substitutions: [.init(id: remoteID, from: "c", to: "d", updatedAt: t1)])
        let merged = SyncMerge.mergeVocabulary(local: local, incoming: incoming)
        XCTAssertEqual(merged.substitutions.map(\.id), [localID, remoteID]) // local first, deterministic
        XCTAssertEqual(SyncMerge.vocabularyChangeCount(local: local, incoming: incoming), 1)
    }

    func testVocabTermsSetUnionOrderPreserved() {
        let local = Vocabulary(terms: ["Claude", "Anthropic"], substitutions: [])
        let incoming = Vocabulary(terms: ["Anthropic", "kubectl"], substitutions: [])
        let merged = SyncMerge.mergeVocabulary(local: local, incoming: incoming)
        XCTAssertEqual(merged.terms, ["Claude", "Anthropic", "kubectl"]) // local first, dedup, append new
        XCTAssertEqual(SyncMerge.vocabularyChangeCount(local: local, incoming: incoming), 1) // only "kubectl" is new
    }

    func testVocabUnstampedLegacyLosesToStampedEdit() {
        // A v2 entry decodes to epoch updatedAt; any stamped v3 edit must win.
        let id = UUID()
        let legacy = Vocabulary.Substitution(id: id, from: "a", to: "OLD", updatedAt: Date(timeIntervalSince1970: 0))
        let stamped = Vocabulary.Substitution(id: id, from: "a", to: "NEW", updatedAt: t1)
        let merged = SyncMerge.mergeVocabulary(
            local: Vocabulary(terms: [], substitutions: [legacy]),
            incoming: Vocabulary(terms: [], substitutions: [stamped]))
        XCTAssertEqual(merged.substitutions.first?.to, "NEW")
    }

    func testVocabMergeIsIdempotent() {
        let shared = UUID(); let remoteOnly = UUID()
        let local = Vocabulary(terms: ["a"], substitutions: [.init(id: shared, from: "x", to: "L", updatedAt: t0)])
        let incoming = Vocabulary(terms: ["a", "b"], substitutions: [
            .init(id: shared, from: "x", to: "R", updatedAt: t2),
            .init(id: remoteOnly, from: "y", to: "z", updatedAt: t1)
        ])
        let once = SyncMerge.mergeVocabulary(local: local, incoming: incoming)
        let twice = SyncMerge.mergeVocabulary(local: once, incoming: incoming)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(SyncMerge.vocabularyChangeCount(local: once, incoming: incoming), 0) // second push changes nothing
    }

    // MARK: - Profiles (LWW per object)

    private func profile(_ id: UUID, _ name: String, _ at: Date) -> AppProfile {
        AppProfile(id: id, appBundleID: "com.x", displayName: name, updatedAt: at)
    }

    func testProfilesIncomingNewerWins() {
        let id = UUID()
        let local = [profile(id, "Local", t0)]
        let incoming = [profile(id, "Remote", t2)]
        let merged = SyncMerge.mergeProfiles(local: local, incoming: incoming)
        XCTAssertEqual(merged.first?.displayName, "Remote")
        XCTAssertEqual(SyncMerge.profilesChangeCount(local: local, incoming: incoming), 1)
    }

    func testProfilesIncomingOlderLoses() {
        let id = UUID()
        let local = [profile(id, "Local", t2)]
        let incoming = [profile(id, "Remote", t0)]
        let merged = SyncMerge.mergeProfiles(local: local, incoming: incoming)
        XCTAssertEqual(merged.first?.displayName, "Local")
        XCTAssertEqual(SyncMerge.profilesChangeCount(local: local, incoming: incoming), 0)
    }

    func testProfilesAbsentOnIncomingPreserved() {
        let id = UUID()
        let local = [profile(id, "Local", t1)]
        let merged = SyncMerge.mergeProfiles(local: local, incoming: [])
        XCTAssertEqual(merged.map(\.id), [id])
    }

    func testProfilesNewIncomingAppended() {
        let a = UUID(); let b = UUID()
        let merged = SyncMerge.mergeProfiles(local: [profile(a, "A", t1)], incoming: [profile(b, "B", t1)])
        XCTAssertEqual(merged.map(\.id), [a, b])
        XCTAssertEqual(SyncMerge.profilesChangeCount(local: [profile(a, "A", t1)], incoming: [profile(b, "B", t1)]), 1)
    }

    func testProfilesBothChangedNewestWinsPerObject() {
        let a = UUID(); let b = UUID()
        let local = [profile(a, "A-local", t2), profile(b, "B-local", t0)]
        let incoming = [profile(a, "A-remote", t0), profile(b, "B-remote", t2)]
        let merged = SyncMerge.mergeProfiles(local: local, incoming: incoming)
        XCTAssertEqual(merged.first(where: { $0.id == a })?.displayName, "A-local")   // local newer
        XCTAssertEqual(merged.first(where: { $0.id == b })?.displayName, "B-remote")  // remote newer
        XCTAssertEqual(SyncMerge.profilesChangeCount(local: local, incoming: incoming), 1) // only b changed
    }

    func testProfilesMergeIdempotent() {
        let id = UUID()
        let local = [profile(id, "Local", t0)]
        let incoming = [profile(id, "Remote", t2), profile(UUID(), "New", t1)]
        let once = SyncMerge.mergeProfiles(local: local, incoming: incoming)
        let twice = SyncMerge.mergeProfiles(local: once, incoming: incoming)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(SyncMerge.profilesChangeCount(local: once, incoming: incoming), 0)
    }

    // MARK: - Modes (LWW per object)

    private func mode(_ id: UUID, _ name: String, _ at: Date) -> Mode {
        Mode(id: id, key: name.lowercased(), name: name, updatedAt: at)
    }

    func testModesNewerWinsOlderLosesBothChanged() {
        let a = UUID(); let b = UUID()
        let local = [mode(a, "Alocal", t2), mode(b, "Blocal", t0)]
        let incoming = [mode(a, "Aremote", t0), mode(b, "Bremote", t2)]
        let merged = SyncMerge.mergeModes(local: local, incoming: incoming)
        XCTAssertEqual(merged.first(where: { $0.id == a })?.name, "Alocal")
        XCTAssertEqual(merged.first(where: { $0.id == b })?.name, "Bremote")
        XCTAssertEqual(SyncMerge.modesChangeCount(local: local, incoming: incoming), 1)
    }

    func testModesAbsentAndNewAndIdempotent() {
        let localID = UUID(); let remoteID = UUID()
        let local = [mode(localID, "Local", t1)]
        let incoming = [mode(remoteID, "Remote", t1)]
        let once = SyncMerge.mergeModes(local: local, incoming: incoming)
        XCTAssertEqual(once.map(\.id), [localID, remoteID])
        let twice = SyncMerge.mergeModes(local: once, incoming: incoming)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(SyncMerge.modesChangeCount(local: once, incoming: incoming), 0)
    }

    // MARK: - History (append-only union by id)

    private func entry(_ id: UUID, _ text: String, _ at: Date) -> TranscriptionEntry {
        TranscriptionEntry(id: id, text: text, date: at, appBundleID: nil, appName: nil)
    }

    func testHistoryAppendsNewEntries() {
        let a = UUID(); let b = UUID()
        let local = [entry(a, "first", t0)]
        let incoming = [entry(b, "second", t1)]
        let merged = SyncMerge.mergeHistory(local: local, incoming: incoming)
        XCTAssertEqual(merged.map(\.id), [a, b])
        XCTAssertEqual(SyncMerge.historyChangeCount(local: local, incoming: incoming), 1)
    }

    func testHistoryExistingIdNeverOverwritten() {
        // Append-only: an id already present is immutable even if incoming text differs.
        let id = UUID()
        let local = [entry(id, "canonical", t0)]
        let incoming = [entry(id, "tampered", t2)]
        let merged = SyncMerge.mergeHistory(local: local, incoming: incoming)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "canonical")
        XCTAssertEqual(SyncMerge.historyChangeCount(local: local, incoming: incoming), 0)
    }

    func testHistoryAbsentOnIncomingPreserved() {
        let id = UUID()
        let merged = SyncMerge.mergeHistory(local: [entry(id, "keep", t0)], incoming: [])
        XCTAssertEqual(merged.map(\.id), [id])
    }

    func testHistoryMergeIdempotent() {
        let a = UUID(); let b = UUID()
        let local = [entry(a, "a", t0)]
        let incoming = [entry(a, "a", t0), entry(b, "b", t1)]
        let once = SyncMerge.mergeHistory(local: local, incoming: incoming)
        let twice = SyncMerge.mergeHistory(local: once, incoming: incoming)
        XCTAssertEqual(once.map(\.id), twice.map(\.id))
        XCTAssertEqual(SyncMerge.historyChangeCount(local: once, incoming: incoming), 0)
    }

    // MARK: - History delta / head cursor

    func testHistoryDeltaStrictlyAfterCursor() {
        let all = [entry(UUID(), "old", t0), entry(UUID(), "mid", t1), entry(UUID(), "new", t2)]
        let cursor = BridgeWire.iso8601String(from: t1)
        let delta = SyncMerge.historyDelta(all, sinceCursor: cursor)
        XCTAssertEqual(delta.map(\.text), ["new"]) // strict >, so t1 itself excluded
    }

    func testHistoryDeltaNilCursorReturnsAll() {
        let all = [entry(UUID(), "x", t0), entry(UUID(), "y", t1)]
        XCTAssertEqual(SyncMerge.historyDelta(all, sinceCursor: nil).count, 2)
        XCTAssertEqual(SyncMerge.historyDelta(all, sinceCursor: "").count, 2)
    }

    func testHistoryHeadPicksNewest() {
        let newestID = UUID()
        let all = [entry(UUID(), "a", t0), entry(newestID, "z", t2), entry(UUID(), "m", t1)]
        let head = SyncMerge.historyHead(all)
        XCTAssertEqual(head.count, 3)
        XCTAssertEqual(head.newestID, newestID)
        XCTAssertEqual(head.newestDate, BridgeWire.iso8601String(from: t2))
    }

    func testHistoryHeadEmpty() {
        let head = SyncMerge.historyHead([])
        XCTAssertEqual(head.count, 0)
        XCTAssertNil(head.newestID)
        XCTAssertNil(head.newestDate)
    }

    // MARK: - Content hashing (manifest identity)

    func testContentHashStableAcrossOrdering() {
        // Two vocabularies equal by value hash identically regardless of dict order.
        let subs = [Vocabulary.Substitution(from: "a", to: "b", updatedAt: t1)]
        let v1 = Vocabulary(terms: ["x", "y"], substitutions: subs)
        let v2 = Vocabulary(terms: ["x", "y"], substitutions: subs)
        XCTAssertEqual(SyncMerge.contentHash(v1), SyncMerge.contentHash(v2))
        XCTAssertFalse(SyncMerge.contentHash(v1).isEmpty)
    }

    func testContentHashDistinguishesEmptyFromNil() {
        let nilHash = SyncMerge.contentHash(Optional<Vocabulary>.none)
        let emptyHash = SyncMerge.contentHash(Vocabulary.empty)
        XCTAssertEqual(nilHash, "")            // absent section
        XCTAssertNotEqual(emptyHash, "")       // present-but-empty section
    }

    func testContentHashChangesWithContent() {
        let a = SyncMerge.contentHash(Vocabulary(terms: ["a"], substitutions: []))
        let b = SyncMerge.contentHash(Vocabulary(terms: ["b"], substitutions: []))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Bundle-level merge (the sync.push funnel)

    func testBundleMergeAppliesAllSectionsAndCounts() {
        let subID = UUID(); let profID = UUID(); let modeID = UUID(); let entID = UUID()
        let incomingBundle = ConfigBundle(
            profiles: [profile(profID, "P", t1)],
            modes: [mode(modeID, "M", t1)],
            vocabulary: Vocabulary(terms: ["w"], substitutions: [.init(id: subID, from: "a", to: "b", updatedAt: t1)])
        )
        let outcome = SyncMerge.merge(
            localVocabulary: .empty, localProfiles: [], localModes: [], localHistory: [],
            incomingBundle: incomingBundle,
            incomingHistory: [entry(entID, "h", t1)]
        )
        XCTAssertEqual(outcome.counts.vocabulary, 2)  // 1 sub + 1 term
        XCTAssertEqual(outcome.counts.profiles, 1)
        XCTAssertEqual(outcome.counts.modes, 1)
        XCTAssertEqual(outcome.counts.history, 1)
        XCTAssertEqual(outcome.vocabulary.substitutions.first?.id, subID)
        XCTAssertEqual(outcome.profiles.map(\.id), [profID])
        XCTAssertEqual(outcome.modes.map(\.id), [modeID])
        XCTAssertEqual(outcome.history.map(\.id), [entID])
    }

    func testBundleMergeAbsentSectionsLeaveLocalUntouched() {
        let localVocab = Vocabulary(terms: ["keep"], substitutions: [])
        // A bundle with ONLY modes: vocab/profiles must be untouched, counts 0.
        let bundle = ConfigBundle(modes: [mode(UUID(), "M", t1)])
        let outcome = SyncMerge.merge(
            localVocabulary: localVocab, localProfiles: [profile(UUID(), "P", t1)],
            localModes: [], localHistory: [],
            incomingBundle: bundle, incomingHistory: [])
        XCTAssertEqual(outcome.vocabulary, localVocab)
        XCTAssertEqual(outcome.counts.vocabulary, 0)
        XCTAssertEqual(outcome.counts.profiles, 0)
        XCTAssertEqual(outcome.profiles.count, 1)
        XCTAssertEqual(outcome.counts.modes, 1)
    }

    func testBundleMergeIsIdempotentEndToEnd() {
        let bundle = ConfigBundle(
            profiles: [profile(UUID(), "P", t2)],
            modes: [mode(UUID(), "M", t2)],
            vocabulary: Vocabulary(terms: ["a", "b"], substitutions: [.init(from: "x", to: "y", updatedAt: t2)])
        )
        let history = [entry(UUID(), "h1", t1), entry(UUID(), "h2", t2)]

        let first = SyncMerge.merge(
            localVocabulary: .empty, localProfiles: [], localModes: [], localHistory: [],
            incomingBundle: bundle, incomingHistory: history)
        // Second apply onto the first result: every count must be 0, state identical.
        let second = SyncMerge.merge(
            localVocabulary: first.vocabulary, localProfiles: first.profiles,
            localModes: first.modes, localHistory: first.history,
            incomingBundle: bundle, incomingHistory: history)

        XCTAssertEqual(first.vocabulary, second.vocabulary)
        XCTAssertEqual(first.profiles, second.profiles)
        XCTAssertEqual(first.modes, second.modes)
        XCTAssertEqual(first.history.map(\.id), second.history.map(\.id))
        XCTAssertEqual(second.counts, BridgeWire.SyncMergedCounts()) // all zero
    }

    // MARK: - Paged history (frame-cap safety)

    func testHistoryPagingWalksEveryEntryInOrder() {
        // 5 entries, page size 2 → the puller re-pulls until drained and must see
        // ALL five exactly once, in order, with no skips or repeats.
        let ids = (0..<5).map { _ in UUID() }
        let all = ids.enumerated().map { entry($0.element, "e\($0.offset)", Date(timeIntervalSince1970: Double(1_000 + $0.offset * 10))) }
        var seen: [UUID] = []
        var cursor: String? = nil
        var guardCount = 0
        while true {
            let page = SyncMerge.historyPage(all, afterCursor: cursor, limit: 2)
            seen.append(contentsOf: page.entries.map(\.id))
            guardCount += 1; XCTAssertLessThan(guardCount, 10, "paging must terminate")
            if !page.hasMore { break }
            cursor = page.nextCursor
        }
        XCTAssertEqual(seen, ids, "every entry, once, in date order")
    }

    func testHistoryPagingNeverSkipsSubMillisecondNeighbors() {
        // Two entries INSIDE the same millisecond whose raw-Date order disagrees
        // with their uuid order: sorting by raw Date while resuming by the
        // ms-truncated cursor string used to skip the second one forever when a
        // page boundary fell between them. Sort key == cursor key now.
        let base = Date(timeIntervalSince1970: 1_000)
        let earlierDateBiggerUUID = TranscriptionEntry(
            id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!,
            text: "first-by-date", date: base.addingTimeInterval(0.0001), appBundleID: nil, appName: nil)
        let laterDateSmallerUUID = TranscriptionEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            text: "second-by-date", date: base.addingTimeInterval(0.0009), appBundleID: nil, appName: nil)
        let all = [earlierDateBiggerUUID, laterDateSmallerUUID]

        var seen: [UUID] = []
        var cursor: String?
        for _ in 0..<4 {
            let page = SyncMerge.historyPage(all, afterCursor: cursor, limit: 1)
            seen += page.entries.map(\.id)
            cursor = page.nextCursor
            if !page.hasMore { break }
        }
        XCTAssertEqual(Set(seen), Set(all.map(\.id)),
            "an entry must never be silently skipped at a page boundary")
        XCTAssertEqual(seen.count, 2)
    }

    func testHistoryPagingNeverSkipsEqualTimestampTies() {
        // Three entries share the SAME date — a date-only cursor would skip some.
        // The total-order (date,id) cursor must still visit all three.
        let same = Date(timeIntervalSince1970: 5_000)
        let ids = (0..<3).map { _ in UUID() }
        let all = ids.map { entry($0, "tie", same) }
        var seen: Set<UUID> = []
        var cursor: String? = nil
        for _ in 0..<5 {
            let page = SyncMerge.historyPage(all, afterCursor: cursor, limit: 1)
            seen.formUnion(page.entries.map(\.id))
            if !page.hasMore { break }
            cursor = page.nextCursor
        }
        XCTAssertEqual(seen, Set(ids), "all equal-timestamp entries must be paged")
    }

    func testHistoryPageLimitClampedAndSingleWhenSmall() {
        let all = [entry(UUID(), "a", t0), entry(UUID(), "b", t1)]
        let page = SyncMerge.historyPage(all, afterCursor: nil, limit: 0) // clamps to 1
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertTrue(page.hasMore)
        let full = SyncMerge.historyPage(all, afterCursor: nil, limit: 50)
        XCTAssertEqual(full.entries.count, 2)
        XCTAssertFalse(full.hasMore)
    }

    // MARK: - Restamp-on-import (the imported data must win the next sync)

    func testRestampUnstampedVocabularyWinsMergeAfterImport() {
        // A pack-style substitution with a fixed id and NO stamp (epoch). Without
        // restamping it loses LWW to any stamped peer copy; with it, it wins.
        let id = UUID()
        let imported = Vocabulary(terms: [], substitutions: [
            .init(id: id, from: "gpt", to: "GPT", updatedAt: Vocabulary.Substitution.unstampedEpoch)
        ])
        XCTAssertEqual(imported.substitutions[0].updatedAt, Vocabulary.Substitution.unstampedEpoch)

        let restamped = imported.restampingUnstamped(now: t2)
        XCTAssertEqual(restamped.substitutions[0].updatedAt, t2, "unstamped entry gets now")

        // A peer holds the same id, stamped at t1 (< t2). After restamp, the
        // imported copy wins the merge; without it (epoch), the peer would win.
        let peer = Vocabulary(terms: [], substitutions: [.init(id: id, from: "gpt", to: "gpt", updatedAt: t1)])
        let merged = SyncMerge.mergeVocabulary(local: restamped, incoming: peer)
        XCTAssertEqual(merged.substitutions.first(where: { $0.id == id })?.to, "GPT",
                       "the just-imported entry must win the sync race")
    }

    func testRestampLeavesGenuineV3StampsUntouched() {
        let id = UUID()
        let v3 = Vocabulary(terms: [], substitutions: [.init(id: id, from: "a", to: "b", updatedAt: t1)])
        let restamped = v3.restampingUnstamped(now: t2)
        XCTAssertEqual(restamped.substitutions[0].updatedAt, t1, "a real v3 stamp is preserved")
    }
}
