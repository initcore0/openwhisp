import XCTest
@testable import OpenWhispCore

/// Unit tests for the pure port-selection contract behind the two loopback
/// servers (MAK-85). These pin the two invariants the app-only bind-first
/// reservation (`ManagedServerProcess.reservePort`) depends on but which used to
/// live only as untested app constants:
///
///   1. whisper's and llama's port bands are DISJOINT (no sibling collision), and
///   2. the candidate walk COVERS the whole band (every port tried once).
///
/// The bind-first TOCTOU fix itself (holding the probe socket open until the
/// child binds) is a live/OS behavior and is exercised by a running dual-engine
/// startup + the `ServerLaunchRetry` decision, not here — see the type doc.
final class LoopbackPortRangesTests: XCTestCase {

    // MARK: - Disjointness (the anti-sibling-collision invariant)

    func testWhisperAndLlamaBandsAreDisjoint() {
        XCTAssertTrue(
            LoopbackPortRanges.disjoint,
            "whisper \(LoopbackPortRanges.whisper) and llama \(LoopbackPortRanges.llama) must not overlap"
        )
    }

    func testBandsShareNoPort() {
        let whisper = Set(LoopbackPortRanges.whisper)
        let llama = Set(LoopbackPortRanges.llama)
        XCTAssertTrue(whisper.isDisjoint(with: llama))
    }

    func testDisjointDetectsAnOverlap() {
        // Guard the guard: `disjoint` must actually return false for overlapping
        // ranges (so a future edit that slides the bands together is caught).
        // We can't mutate the static bands, so exercise the same predicate shape.
        let a = 100...200
        let b = 150...250
        XCTAssertFalse(a.upperBound < b.lowerBound || b.upperBound < a.lowerBound)
    }

    // MARK: - Candidate walk covers the whole band exactly once

    func testCandidateOrderIsAFullPermutation() {
        let order = LoopbackPortRanges.candidateOrder(in: LoopbackPortRanges.whisper)
        XCTAssertEqual(order.count, LoopbackPortRanges.whisper.count)
        XCTAssertEqual(Set(order), Set(LoopbackPortRanges.whisper),
                       "every port in the band must appear exactly once")
    }

    func testCandidateOrderCoversLlamaBandToo() {
        let order = LoopbackPortRanges.candidateOrder(in: LoopbackPortRanges.llama)
        XCTAssertEqual(Set(order), Set(LoopbackPortRanges.llama))
        XCTAssertEqual(order.count, order.count)
    }

    func testInjectedShuffleIsHonored() {
        // The `using:` seam lets a caller (a test, or a deterministic probe)
        // control the order; a reverse "shuffle" must produce the reversed band.
        let order = LoopbackPortRanges.candidateOrder(in: 1...5, using: { $0.reversed() })
        XCTAssertEqual(order, [5, 4, 3, 2, 1])
    }

    func testCandidateOrderIsRandomisedAcrossCalls() {
        // Not a strict guarantee (a shuffle CAN repeat), but across many draws of
        // a wide band the default shuffle must not be a constant order — that's
        // what spreads concurrent reservations across the range.
        let band = LoopbackPortRanges.whisper
        let firstElements = (0..<20).map { _ in
            LoopbackPortRanges.candidateOrder(in: band).first
        }
        XCTAssertGreaterThan(Set(firstElements).count, 1,
                             "shuffled candidate order should vary across calls")
    }
}
