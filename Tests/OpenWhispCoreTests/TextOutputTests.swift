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

    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool,
                completion: ((InsertionOutcome) -> Void)?) {
        insertions.append(.init(text: text, mode: mode, restoreClipboard: restoreClipboard))
        completion?(.inserted)
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

    // MARK: InsertVerifier (AX read-back decision)

    func testVerifyReflectedWhenValueChangedAndContainsText() {
        XCTAssertEqual(
            InsertVerifier.axInsertReflected(expected: "hello", before: "say ", current: "say hello there"),
            true
        )
    }

    func testVerifyContradictedWhenValueUnchangedAndLacksText() {
        // Readable value, unchanged by the set, doesn't contain our text →
        // AX silently failed → fall back to paste.
        XCTAssertEqual(
            InsertVerifier.axInsertReflected(expected: "hello", before: "unchanged", current: "unchanged"),
            false
        )
    }

    func testVerifyUnverifiableWhenTextAlreadyPresentBeforeSet() {
        // The field already held the dictated phrase and the set changed nothing:
        // could be an ignored AX set OR a no-op replacement of an identical
        // selection — must NOT verify (would silently drop text in lying apps),
        // must NOT contradict (paste would duplicate) → nil.
        XCTAssertNil(
            InsertVerifier.axInsertReflected(expected: "thanks", before: "well thanks", current: "well thanks")
        )
    }

    func testVerifyUnverifiableWhenValueChangedButTextTransformed() {
        // The set clearly changed the field but the app transformed the inserted
        // text (smart quotes etc.) → not a contradiction; a paste fallback would
        // insert a second copy → nil.
        XCTAssertNil(
            InsertVerifier.axInsertReflected(expected: "it's ready", before: "", current: "it\u{2019}s ready")
        )
    }

    func testVerifyReflectedWhenBeforeUnreadable() {
        // No pre-set snapshot but the read-back changed relative to nil and
        // contains our text → verified.
        XCTAssertEqual(
            InsertVerifier.axInsertReflected(expected: "hello", before: nil, current: "say hello there"),
            true
        )
    }

    func testVerifyUnverifiableWhenNoReadableValue() {
        // nil read-back → can't verify → trust the AX status (nil result).
        XCTAssertNil(InsertVerifier.axInsertReflected(expected: "hello", before: "x", current: nil))
    }

    func testVerifyEmptyExpectedIsUnverifiable() {
        XCTAssertNil(InsertVerifier.axInsertReflected(expected: "   ", before: "", current: "anything"))
    }
}
