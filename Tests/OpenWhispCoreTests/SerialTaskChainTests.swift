import XCTest
@testable import OpenWhispCore

/// Serializes async operations in enqueue order — the guarantee the WhisperKit
/// streaming lifecycle relies on so a stop's teardown finishes before the next
/// start's installTap (no race on a quick double-tap restart).
@MainActor
final class SerialTaskChainTests: XCTestCase {

    /// An async-safe recorder for operation events.
    private actor Recorder {
        private(set) var events: [String] = []
        func add(_ s: String) { events.append(s) }
    }

    func testRunsInEnqueueOrder() async {
        let chain = SerialTaskChain()
        let rec = Recorder()
        for i in 0..<5 {
            chain.enqueue { await rec.add("op\(i)") }
        }
        await chain.drain()
        let events = await rec.events
        XCTAssertEqual(events, ["op0", "op1", "op2", "op3", "op4"])
    }

    /// The crux: a SLOW first operation must still complete before a fast second one
    /// begins — order is by enqueue, not by duration. (The stop-before-start case.)
    func testSlowFirstStillCompletesBeforeFastSecond() async {
        let chain = SerialTaskChain()
        let rec = Recorder()
        chain.enqueue {
            try? await Task.sleep(nanoseconds: 200_000_000)   // slow "stop"
            await rec.add("stop-done")
        }
        chain.enqueue {
            await rec.add("start-begin")                       // fast "start"
        }
        await chain.drain()
        let events = await rec.events
        XCTAssertEqual(events, ["stop-done", "start-begin"])
    }

    /// Operations never overlap: each completes before the next starts, so a
    /// begin/end bracket per op is always well-nested (no interleaving).
    func testOperationsDoNotOverlap() async {
        let chain = SerialTaskChain()
        let rec = Recorder()
        for i in 0..<6 {
            chain.enqueue {
                await rec.add("begin\(i)")
                try? await Task.sleep(nanoseconds: UInt64((6 - i) * 10_000_000))   // decreasing
                await rec.add("end\(i)")
            }
        }
        await chain.drain()
        let events = await rec.events
        var expected: [String] = []
        for i in 0..<6 { expected.append("begin\(i)"); expected.append("end\(i)") }
        XCTAssertEqual(events, expected)
    }

    func testDrainWaitsForWorkEnqueivedSoFar() async {
        let chain = SerialTaskChain()
        let rec = Recorder()
        chain.enqueue {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await rec.add("a")
        }
        await chain.drain()
        let events = await rec.events
        XCTAssertEqual(events, ["a"])   // drain awaited it, didn't race past
    }
}
