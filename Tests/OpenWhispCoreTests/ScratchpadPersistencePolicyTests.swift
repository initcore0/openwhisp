import XCTest
@testable import OpenWhispCore

/// Tests for the Scratchpad's persistence policy (MAK-95) — the rule that closed
/// the "full atomic JSON write per keystroke" perf bug from the July-2026 bug hunt.
final class ScratchpadPersistencePolicyTests: XCTestCase {

    // MARK: - The coalesced path (the bug this fixes)

    func testEditsAreCoalescedNotImmediate() {
        XCTAssertFalse(
            ScratchpadPersistencePolicy.requiresImmediateWrite(.edit),
            "a per-keystroke edit must NOT trigger a synchronous full-store write"
        )
    }

    func testDictationIsCoalesced() {
        XCTAssertFalse(ScratchpadPersistencePolicy.requiresImmediateWrite(.dictation))
    }

    // MARK: - The immediate (structural) path

    func testStructuralMutationsWriteImmediately() {
        for mutation in [ScratchpadPersistencePolicy.Mutation.create, .delete, .meetingInsert] {
            XCTAssertTrue(
                ScratchpadPersistencePolicy.requiresImmediateWrite(mutation),
                "\(mutation) changes which notes exist — it must persist immediately"
            )
        }
    }

    func testTeardownWritesImmediately() {
        XCTAssertTrue(ScratchpadPersistencePolicy.requiresImmediateWrite(.teardown))
    }

    // MARK: - Stale-snapshot invariant

    func testImmediateMutationsCancelAPendingWrite() {
        // The invariant that stops a snapshot captured BEFORE a delete from landing
        // AFTER it and resurrecting the deleted note.
        for mutation in [ScratchpadPersistencePolicy.Mutation.create, .delete, .meetingInsert, .teardown] {
            XCTAssertTrue(
                ScratchpadPersistencePolicy.cancelsPendingWrite(mutation),
                "\(mutation) writes the whole store, so a pending stale timer must be cancelled"
            )
        }
    }

    func testCoalescedMutationsDoNotCancel() {
        XCTAssertFalse(ScratchpadPersistencePolicy.cancelsPendingWrite(.edit))
        XCTAssertFalse(ScratchpadPersistencePolicy.cancelsPendingWrite(.dictation))
    }

    func testCancelAndImmediateAgreeForEveryMutation() {
        let all: [ScratchpadPersistencePolicy.Mutation] =
            [.edit, .dictation, .create, .delete, .meetingInsert, .teardown]
        for mutation in all {
            XCTAssertEqual(
                ScratchpadPersistencePolicy.requiresImmediateWrite(mutation),
                ScratchpadPersistencePolicy.cancelsPendingWrite(mutation),
                "every immediate write supersedes (and must cancel) a pending one"
            )
        }
    }

    // MARK: - Debounce window

    func testDebounceIntervalIsShortButCoalescing() {
        // Long enough that ordinary typing collapses into one write, short enough
        // that a sub-second pause already has the note on disk.
        XCTAssertGreaterThanOrEqual(ScratchpadPersistencePolicy.debounceInterval, 0.3)
        XCTAssertLessThanOrEqual(ScratchpadPersistencePolicy.debounceInterval, 1.0)
    }
}
