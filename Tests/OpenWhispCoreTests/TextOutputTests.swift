import XCTest
@testable import OpenWhispCore

/// A recording `TextOutput` double — the kind of fake that becomes possible once
/// insertion is behind a protocol. Captures calls instead of touching the real
/// clipboard/accessibility APIs, so higher-level paste/clipboard orchestration
/// can be asserted in `swift test` (the concrete macOS TextInserter still needs
/// a real window server and isn't unit-testable).
final class SpyTextOutput: TextOutput {
    struct Insertion: Equatable {
        let text: String
        let mode: InsertionMode
        let restoreClipboard: Bool
    }
    private(set) var insertions: [Insertion] = []
    private(set) var clipboardWrites: [String] = []

    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool) {
        insertions.append(.init(text: text, mode: mode, restoreClipboard: restoreClipboard))
    }
    func setClipboard(_ text: String) {
        clipboardWrites.append(text)
    }
}

final class TextOutputTests: XCTestCase {
    func testInsertionModeRawValueRoundTrips() {
        XCTAssertEqual(InsertionMode(rawValue: "auto"), .auto)
        XCTAssertEqual(InsertionMode(rawValue: "directAX"), .directAX)
        XCTAssertEqual(InsertionMode(rawValue: "paste"), .paste)
    }

    func testInsertionModeUnknownRawValueIsNil() {
        // AppState relies on `InsertionMode(rawValue:) ?? .auto` for an unknown
        // stored setting — verify the nil that the `?? .auto` depends on.
        XCTAssertNil(InsertionMode(rawValue: "nonsense"))
        XCTAssertNil(InsertionMode(rawValue: ""))
    }

    func testSpyRecordsInsertions() {
        let spy: TextOutput = SpyTextOutput()
        spy.insert("hello", mode: .auto, restoreClipboard: true)
        spy.insert(" world", mode: .paste, restoreClipboard: false)
        spy.setClipboard("final")

        let recorder = spy as! SpyTextOutput
        XCTAssertEqual(recorder.insertions, [
            .init(text: "hello", mode: .auto, restoreClipboard: true),
            .init(text: " world", mode: .paste, restoreClipboard: false)
        ])
        XCTAssertEqual(recorder.clipboardWrites, ["final"])
    }
}
