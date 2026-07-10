import XCTest
@testable import OpenWhispCore

/// The mouse-button dictation trigger model (MAK-42): id↔button↔label mapping and
/// the bindability guard that keeps the left/right buttons unbindable.
final class MouseTriggerTests: XCTestCase {

    func testDefaultIsOff() {
        XCTAssertEqual(MouseTrigger.defaultTrigger, .off)
        XCTAssertNil(MouseTrigger.defaultTrigger.buttonNumber)
    }

    func testIdRoundTrip() {
        XCTAssertEqual(MouseTrigger.from(id: "off"), .off)
        XCTAssertEqual(MouseTrigger.from(id: "mouse2"), .button(2))
        XCTAssertEqual(MouseTrigger.from(id: "mouse5"), .button(5))
        XCTAssertEqual(MouseTrigger.button(3).id, "mouse3")
        XCTAssertEqual(MouseTrigger.off.id, "off")
    }

    func testLeftAndRightButtonsAreNotBindable() {
        // Buttons 0 (left) and 1 (right) are load-bearing for normal clicking and
        // must never parse to a binding — they fall back to `.off`.
        XCTAssertEqual(MouseTrigger.from(id: "mouse0"), .off)
        XCTAssertEqual(MouseTrigger.from(id: "mouse1"), .off)
        XCTAssertFalse(MouseTrigger.isBindable(buttonNumber: 0))
        XCTAssertFalse(MouseTrigger.isBindable(buttonNumber: 1))
        XCTAssertTrue(MouseTrigger.isBindable(buttonNumber: 2))
    }

    func testOutOfRangeAndGarbageIdsFallBackToOff() {
        XCTAssertEqual(MouseTrigger.from(id: "mouse99"), .off)   // above max
        XCTAssertEqual(MouseTrigger.from(id: "mouseX"), .off)    // not a number
        XCTAssertEqual(MouseTrigger.from(id: "bogus"), .off)
        XCTAssertEqual(MouseTrigger.from(id: ""), .off)
    }

    func testButtonNumberAccessor() {
        XCTAssertEqual(MouseTrigger.button(2).buttonNumber, 2)
        XCTAssertNil(MouseTrigger.off.buttonNumber)
    }

    func testLabels() {
        XCTAssertEqual(MouseTrigger.off.label, "Off")
        XCTAssertEqual(MouseTrigger.button(2).label, "Middle button")
        XCTAssertEqual(MouseTrigger.button(3).label, "Mouse 4 (back)")
        XCTAssertEqual(MouseTrigger.button(4).label, "Mouse 5 (forward)")
        // Gaming-mouse side buttons: physical "Mouse N" = button number N+1.
        XCTAssertEqual(MouseTrigger.button(5).label, "Mouse 6")
    }

    func testEverySelectableOptionHasALabelAndIsBindableOrOff() {
        let options = MouseTrigger.allSelectable
        XCTAssertEqual(options.first, .off)
        for option in options {
            XCTAssertFalse(option.label.isEmpty)
            if let n = option.buttonNumber {
                XCTAssertTrue(MouseTrigger.isBindable(buttonNumber: n))
            }
        }
        // Off + buttons 2...10 = 10 options.
        XCTAssertEqual(options.count, 10)
    }
}
