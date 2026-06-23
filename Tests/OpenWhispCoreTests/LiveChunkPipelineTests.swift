import XCTest
@testable import OpenWhispCore

/// Exercises the live-chunk ordering/sequencing machine extracted from AppState.
/// This logic — concurrent transcription completing out of order but emitted in
/// order, with drain detection — was previously untested and implicated in
/// live-chunk bugs.
final class LiveChunkPipelineTests: XCTestCase {

    // MARK: Capture / concurrency

    func testEnqueueAssignsSequentialIDsAndCounts() {
        var p = LiveChunkPipeline(maxConcurrent: 2)
        XCTAssertEqual(p.enqueue(), 0)
        XCTAssertEqual(p.enqueue(), 1)
        XCTAssertEqual(p.enqueue(), 2)
        XCTAssertEqual(p.queuedCount, 3)
    }

    func testDispatchableRespectsConcurrencyCap() {
        var p = LiveChunkPipeline(maxConcurrent: 2)
        _ = p.enqueue(); _ = p.enqueue(); _ = p.enqueue()
        XCTAssertEqual(p.dispatchable(), [0, 1], "only maxConcurrent dispatch at first")
        XCTAssertEqual(p.dispatchable(), [], "cap reached, nothing more until one completes")
    }

    func testCompletingFreesAConcurrencySlot() {
        var p = LiveChunkPipeline(maxConcurrent: 2)
        _ = p.enqueue(); _ = p.enqueue(); _ = p.enqueue()
        XCTAssertEqual(p.dispatchable(), [0, 1])
        p.complete(0, text: "a")
        XCTAssertEqual(p.dispatchable(), [2], "one slot freed -> dispatch the third")
    }

    // MARK: Ordering

    func testInOrderCompletionEmitsInOrder() {
        var p = LiveChunkPipeline(maxConcurrent: 3)
        _ = p.enqueue(); _ = p.enqueue(); _ = p.enqueue()
        _ = p.dispatchable()
        p.complete(0, text: "first")
        XCTAssertEqual(p.takeOrderedReady(), ["first"])
        p.complete(1, text: "second")
        XCTAssertEqual(p.takeOrderedReady(), ["second"])
    }

    func testOutOfOrderCompletionBuffersUntilContiguous() {
        var p = LiveChunkPipeline(maxConcurrent: 3)
        _ = p.enqueue(); _ = p.enqueue(); _ = p.enqueue()
        _ = p.dispatchable()
        // Chunk 2 finishes first — must NOT emit (0 and 1 not ready).
        p.complete(2, text: "third")
        XCTAssertEqual(p.takeOrderedReady(), [], "cannot emit ahead of the cursor")
        // Chunk 0 finishes — emits 0 only (1 still missing).
        p.complete(0, text: "first")
        XCTAssertEqual(p.takeOrderedReady(), ["first"])
        // Chunk 1 finishes — now 1 and the buffered 2 flush together, in order.
        p.complete(1, text: "second")
        XCTAssertEqual(p.takeOrderedReady(), ["second", "third"])
    }

    func testEmptyResultAdvancesCursorWithoutEmitting() {
        var p = LiveChunkPipeline(maxConcurrent: 3)
        _ = p.enqueue(); _ = p.enqueue(); _ = p.enqueue()
        _ = p.dispatchable()
        p.complete(0, text: "")        // silent/failed chunk
        p.complete(1, text: "hello")
        // 0 advances the cursor but yields no text; 1 then emits.
        XCTAssertEqual(p.takeOrderedReady(), ["hello"])
    }

    func testEmptyMiddleChunkDoesNotBlockLaterOnes() {
        var p = LiveChunkPipeline(maxConcurrent: 3)
        _ = p.enqueue(); _ = p.enqueue(); _ = p.enqueue()
        _ = p.dispatchable()
        p.complete(2, text: "c")
        p.complete(0, text: "a")
        XCTAssertEqual(p.takeOrderedReady(), ["a"])
        p.complete(1, text: "")       // empty middle
        XCTAssertEqual(p.takeOrderedReady(), ["c"], "empty 1 skipped, buffered 2 flows")
    }

    // MARK: Insertion gate

    func testInsertionIsSingleInFlight() {
        var p = LiveChunkPipeline()
        p.queueForInsertion(["one", "two"])
        XCTAssertEqual(p.nextInsertion(), "one")
        XCTAssertNil(p.nextInsertion(), "must not hand out a second while one is in flight")
        p.finishInsertion()
        XCTAssertEqual(p.nextInsertion(), "two")
        p.finishInsertion()
        XCTAssertNil(p.nextInsertion())
    }

    // MARK: Drain detection

    func testDrainedInitially() {
        let p = LiveChunkPipeline()
        XCTAssertTrue(p.isDrained)
    }

    func testNotDrainedWithPendingInFlightBufferedOrInserting() {
        var p = LiveChunkPipeline(maxConcurrent: 2)
        _ = p.enqueue()
        XCTAssertFalse(p.isDrained, "pending chunk")
        _ = p.dispatchable()
        XCTAssertFalse(p.isDrained, "in flight")
        p.complete(0, text: "x")
        XCTAssertFalse(p.isDrained, "buffered result not yet taken")
        _ = p.takeOrderedReady()
        p.queueForInsertion(["x"])
        XCTAssertFalse(p.isDrained, "queued for insertion")
        _ = p.nextInsertion()
        XCTAssertFalse(p.isDrained, "insertion in flight")
        p.finishInsertion()
        XCTAssertTrue(p.isDrained, "fully drained")
    }

    // MARK: Reset

    func testResetReturnsToInitialState() {
        var p = LiveChunkPipeline(maxConcurrent: 2)
        _ = p.enqueue(); _ = p.enqueue()
        _ = p.dispatchable()
        p.complete(0, text: "x")
        p.queueForInsertion(["x"])
        _ = p.nextInsertion()
        p.reset()
        XCTAssertTrue(p.isDrained)
        XCTAssertEqual(p.queuedCount, 0)
        // Sequencing restarts from 0 after reset.
        XCTAssertEqual(p.enqueue(), 0)
        XCTAssertEqual(p.dispatchable(), [0])
        p.complete(0, text: "fresh")
        XCTAssertEqual(p.takeOrderedReady(), ["fresh"])
    }

    /// End-to-end: 5 chunks, cap 2, completing in a scrambled order, must emit
    /// exactly in chunk order with no loss and end drained.
    func testFullScrambledRunEmitsInOrder() {
        var p = LiveChunkPipeline(maxConcurrent: 2)
        for _ in 0..<5 { _ = p.enqueue() }
        var emitted: [String] = []
        let texts = ["c0", "c1", "c2", "c3", "c4"]

        // Drive it like AppState: dispatch, then complete in a scrambled order,
        // re-dispatching and flushing after each completion.
        _ = p.dispatchable()                      // [0,1]
        for id in [1, 0, 3, 2, 4] {               // scrambled completion order
            p.complete(id, text: texts[id])
            _ = p.dispatchable()                  // fill freed slots
            emitted.append(contentsOf: p.takeOrderedReady())
        }
        XCTAssertEqual(emitted, texts, "all 5 emitted exactly in chunk order")
        // Run the insertion stage to drain it.
        p.queueForInsertion(emitted)
        while let _ = p.nextInsertion() { p.finishInsertion() }
        XCTAssertTrue(p.isDrained)
    }
}
