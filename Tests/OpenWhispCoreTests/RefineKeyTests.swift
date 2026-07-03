import XCTest
@testable import OpenWhispCore

final class RefineKeyTests: XCTestCase {

    func testDefaultAndOffMapping() {
        XCTAssertEqual(RefineKey.from(id: "leftControl"), .leftControl)
        XCTAssertEqual(RefineKey.from(id: "rightOption"), .rightOption)
        XCTAssertEqual(RefineKey.from(id: "off"), .off)
        // Unknown ids fall back to the working default, never a crash.
        XCTAssertEqual(RefineKey.from(id: "bogus"), RefineKey.defaultKey)
    }

    func testDefaultExistsOnEveryMacKeyboard() {
        // The old default (rightControl) doesn't exist on MacBook keyboards,
        // which made refine silently impossible there. The default must be a
        // key every Mac keyboard has.
        XCTAssertEqual(RefineKey.defaultKey, .leftControl)
    }

    func testKeyCodes() {
        XCTAssertNil(RefineKey.off.keyCode)
        XCTAssertEqual(RefineKey.leftControl.keyCode, 0x3B)
        XCTAssertEqual(RefineKey.leftOption.keyCode, 0x3A)
        XCTAssertEqual(RefineKey.leftCommand.keyCode, 0x37)
        XCTAssertEqual(RefineKey.rightOption.keyCode, 0x3D)
        XCTAssertEqual(RefineKey.rightCommand.keyCode, 0x36)
        XCTAssertEqual(RefineKey.rightControl.keyCode, 0x3E)
        XCTAssertEqual(RefineKey.rightShift.keyCode, 0x3C)
    }

    func testEveryCaseHasALabel() {
        for key in RefineKey.allCases {
            XCTAssertFalse(key.label.isEmpty)
        }
    }

    func testEveryKeyExceptOffHasAGlyph() {
        for key in RefineKey.allCases where key != .off {
            XCTAssertFalse(key.glyph.isEmpty)
        }
    }

    func testOffHasNoKeyCodeSoRefineIsDisabled() {
        // "off" must map to nil so the monitor never fires refine.
        XCTAssertNil(RefineKey.from(id: "off").keyCode)
    }

    func testControlKeysConflictWithControlSpaceTrigger() {
        // Control+Space matches EITHER Control key, so holding Control to start
        // dictation would read as a refine tap.
        XCTAssertTrue(RefineKey.leftControl.conflictsWithTrigger("controlSpace"))
        XCTAssertTrue(RefineKey.rightControl.conflictsWithTrigger("controlSpace"))
        XCTAssertFalse(RefineKey.leftOption.conflictsWithTrigger("controlSpace"))
        XCTAssertFalse(RefineKey.leftCommand.conflictsWithTrigger("controlSpace"))
        // The Fn trigger doesn't involve Control at all.
        XCTAssertFalse(RefineKey.leftControl.conflictsWithTrigger("fn"))
        XCTAssertFalse(RefineKey.rightControl.conflictsWithTrigger("fn"))
    }
}
