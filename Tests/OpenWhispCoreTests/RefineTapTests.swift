import XCTest
@testable import OpenWhispCore

final class RefineTapTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testCleanQuickTapFires() {
        var r = RefineTapRecognizer()
        r.keyDown(at: t0)
        XCTAssertTrue(r.keyUp(at: t0.addingTimeInterval(0.15)))
    }

    func testLongHoldIsNotATap() {
        var r = RefineTapRecognizer()
        r.keyDown(at: t0)
        XCTAssertFalse(r.keyUp(at: t0.addingTimeInterval(1.2)))
    }

    func testShortcutChordIsNotATap() {
        // ⌃C: control down, 'c' keyDown, control up — must never arm refine.
        var r = RefineTapRecognizer()
        r.keyDown(at: t0)
        r.otherInput()
        XCTAssertFalse(r.keyUp(at: t0.addingTimeInterval(0.1)))
    }

    func testOtherInputWhileNotHeldIsIgnored() {
        // Typing before the tap must not poison the next tap.
        var r = RefineTapRecognizer()
        r.otherInput()
        r.keyDown(at: t0)
        XCTAssertTrue(r.keyUp(at: t0.addingTimeInterval(0.1)))
    }

    func testUpWithoutDownIsNotATap() {
        var r = RefineTapRecognizer()
        XCTAssertFalse(r.keyUp(at: t0))
    }

    func testRecognizerRecoversAfterADisqualifiedHold() {
        var r = RefineTapRecognizer()
        r.keyDown(at: t0)
        r.otherInput()
        XCTAssertFalse(r.keyUp(at: t0.addingTimeInterval(0.1)))
        // A fresh, clean tap right after still works.
        r.keyDown(at: t0.addingTimeInterval(1))
        XCTAssertTrue(r.keyUp(at: t0.addingTimeInterval(1.2)))
    }

    func testCustomTapDurationBoundaryIsInclusive() {
        var r = RefineTapRecognizer(maxTapDuration: 0.3)
        r.keyDown(at: t0)
        XCTAssertTrue(r.keyUp(at: t0.addingTimeInterval(0.3)))
        r.keyDown(at: t0)
        XCTAssertFalse(r.keyUp(at: t0.addingTimeInterval(0.31)))
    }
}
