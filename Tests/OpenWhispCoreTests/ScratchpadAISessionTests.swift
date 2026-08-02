import XCTest
@testable import OpenWhispCore

/// Tests for the Scratchpad AI delivery fence (MAK-99).
///
/// The bug class this pins: an AI result arriving after the user moved on, and
/// painting into the wrong note. Every one of these is a scenario a live LLM would
/// only surface intermittently.
final class ScratchpadAISessionTests: XCTestCase {

    private let noteA = UUID()
    private let noteB = UUID()

    // MARK: - Happy path

    func testAFreshSessionIsNotBusy() {
        let session = ScratchpadAISession()
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.busyAction)
        XCTAssertNil(session.inFlight)
    }

    func testBeginMarksTheSessionBusyWithItsAction() {
        var session = ScratchpadAISession()
        _ = session.begin(noteID: noteA, action: .summarize)
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(session.busyAction, .summarize)
    }

    func testAResultForTheStillSelectedNoteIsDelivered() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .formatMarkdown)
        XCTAssertTrue(session.accepts(ticket, currentNoteID: noteA))
    }

    func testFinishClearsTheBusyState() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .formatMarkdown)
        session.finish(ticket)
        XCTAssertFalse(session.isBusy)
    }

    // MARK: - The fence

    /// THE core case: the user switched notes while the request was in flight. The
    /// late result must not paint into the note now on screen.
    func testAResultIsRefusedAfterTheUserSwitchedNotes() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .formatMarkdown)
        session.noteChanged(to: noteB)
        XCTAssertFalse(session.accepts(ticket, currentNoteID: noteB))
        // …and not into its original note either — the request was cancelled.
        XCTAssertFalse(session.accepts(ticket, currentNoteID: noteA))
    }

    /// Closing the panel cancels delivery.
    func testAResultIsRefusedAfterCancel() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .summarize)
        session.cancel()
        XCTAssertFalse(session.accepts(ticket, currentNoteID: noteA))
        XCTAssertFalse(session.isBusy)
    }

    /// Belt and braces: even without a `noteChanged` call, a result whose note is
    /// not the selected one is refused.
    func testAResultForANonSelectedNoteIsRefusedEvenWithoutAnExplicitCancel() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .formatMarkdown)
        XCTAssertFalse(session.accepts(ticket, currentNoteID: noteB))
        XCTAssertFalse(session.accepts(ticket, currentNoteID: nil))
    }

    /// One action in flight at a time: starting a second invalidates the first, so
    /// two results can never both land.
    func testStartingASecondRequestInvalidatesTheFirst() {
        var session = ScratchpadAISession()
        let first = session.begin(noteID: noteA, action: .formatMarkdown)
        let second = session.begin(noteID: noteA, action: .summarize)
        XCTAssertFalse(session.accepts(first, currentNoteID: noteA))
        XCTAssertTrue(session.accepts(second, currentNoteID: noteA))
        XCTAssertEqual(session.busyAction, .summarize)
    }

    /// A stale reply must not clear the NEWER request's busy state — otherwise the
    /// toolbar would re-enable while a request is still running.
    func testAStaleFinishDoesNotClearTheNewerRequest() {
        var session = ScratchpadAISession()
        let first = session.begin(noteID: noteA, action: .formatMarkdown)
        let second = session.begin(noteID: noteA, action: .summarize)
        session.finish(first)
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(session.busyAction, .summarize)
        session.finish(second)
        XCTAssertFalse(session.isBusy)
    }

    /// A result that already landed can't be replayed into a later request's slot.
    func testAFinishedTicketIsNoLongerAccepted() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .summarize)
        session.finish(ticket)
        XCTAssertFalse(session.accepts(ticket, currentNoteID: noteA))
    }

    // MARK: - noteChanged

    func testNoteChangedToTheSameNoteDoesNotCancel() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .formatMarkdown)
        XCTAssertFalse(session.noteChanged(to: noteA))
        XCTAssertTrue(session.accepts(ticket, currentNoteID: noteA))
        XCTAssertTrue(session.isBusy)
    }

    func testNoteChangedReportsWhetherItCancelled() {
        var session = ScratchpadAISession()
        _ = session.begin(noteID: noteA, action: .formatMarkdown)
        XCTAssertTrue(session.noteChanged(to: noteB))
    }

    func testNoteChangedWithNothingInFlightIsANoOp() {
        var session = ScratchpadAISession()
        XCTAssertFalse(session.noteChanged(to: noteB))
        XCTAssertFalse(session.isBusy)
    }

    func testNoteChangedToNoSelectionCancels() {
        var session = ScratchpadAISession()
        let ticket = session.begin(noteID: noteA, action: .summarize)
        XCTAssertTrue(session.noteChanged(to: nil))
        XCTAssertFalse(session.accepts(ticket, currentNoteID: nil))
    }

    // MARK: - Token monotonicity

    /// Tokens must never be reused, or a much older reply could alias a current
    /// ticket. Exercised through a long cancel/begin churn.
    func testTicketsAreNeverReusedAcrossCancelChurn() {
        var session = ScratchpadAISession()
        var seen = Set<Int>()
        for _ in 0..<200 {
            let ticket = session.begin(noteID: noteA, action: .formatMarkdown)
            XCTAssertTrue(seen.insert(ticket.token).inserted, "token \(ticket.token) reused")
            session.cancel()
        }
    }

    /// Every ticket ever issued for a cancelled run stays refused forever.
    func testAllStaleTicketsRemainRefused() {
        var session = ScratchpadAISession()
        var stale: [ScratchpadAISession.Ticket] = []
        for _ in 0..<20 {
            stale.append(session.begin(noteID: noteA, action: .summarize))
        }
        let live = session.begin(noteID: noteA, action: .summarize)
        for ticket in stale {
            XCTAssertFalse(session.accepts(ticket, currentNoteID: noteA))
        }
        XCTAssertTrue(session.accepts(live, currentNoteID: noteA))
    }
}
