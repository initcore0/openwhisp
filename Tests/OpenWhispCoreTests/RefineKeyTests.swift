import XCTest
@testable import OpenWhispCore

final class RefineKeyTests: XCTestCase {

    func testDefaultAndOffMapping() {
        XCTAssertEqual(RefineKey.from(id: "rightOption"), .rightOption)
        XCTAssertEqual(RefineKey.from(id: "off"), .off)
        // Unknown ids fall back to a working default, never a crash.
        XCTAssertEqual(RefineKey.from(id: "bogus"), .rightOption)
    }

    func testKeyCodes() {
        XCTAssertNil(RefineKey.off.keyCode)
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

    func testOffHasNoKeyCodeSoRefineIsDisabled() {
        // "off" must map to nil so the monitor never fires refine.
        XCTAssertNil(RefineKey.from(id: "off").keyCode)
    }
}
