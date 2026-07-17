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
    struct Replacement: Equatable {
        let inserted: String
        let raw: String
    }
    private(set) var insertions: [Insertion] = []
    private(set) var clipboardWrites: [String] = []
    private(set) var replacements: [Replacement] = []
    /// What `replaceLastInsertion` reports — defaults to "no AX replace happened"
    /// (the common test path where the caller falls back to the clipboard copy).
    var replaceSucceeds = false

    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool,
                completion: ((InsertionOutcome) -> Void)?) {
        insertions.append(.init(text: text, mode: mode, restoreClipboard: restoreClipboard))
        completion?(.inserted)
    }
    func setClipboard(_ text: String) {
        clipboardWrites.append(text)
    }
    func replaceLastInsertion(inserted: String, raw: String,
                              completion: @escaping (Bool) -> Void) {
        replacements.append(.init(inserted: inserted, raw: raw))
        completion(replaceSucceeds)
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

    func testVerifyReflectedWhenAppAppliedSmartQuotes() {
        // The app applied typographic substitution (smart quotes) to our text —
        // normalization reclassifies this as a verified insert (a paste fallback
        // would insert a second copy).
        XCTAssertEqual(
            InsertVerifier.axInsertReflected(expected: "it's ready", before: "", current: "it\u{2019}s ready"),
            true
        )
    }

    func testVerifyContradictedWhenFieldClearedBySet() {
        // AX reported success but the field ended up EMPTY — the app discarded
        // the text (validator reset). The text exists nowhere; paste must recover.
        XCTAssertEqual(
            InsertVerifier.axInsertReflected(expected: "hello", before: "draft text", current: ""),
            false
        )
    }

    func testVerifyContradictedWhenFieldShrankWithoutText() {
        // Field shrank and doesn't contain our text — a successful insert of
        // non-empty text cannot shrink the value → discarded → paste fallback.
        XCTAssertEqual(
            InsertVerifier.axInsertReflected(expected: "hello world", before: "some longer content", current: "some"),
            false
        )
    }

    func testVerifyUnverifiableWhenFieldGrewWithRewrittenText() {
        // Field grew but our text is absent even after normalization — the app
        // aggressively rewrote it (autocorrect/markdown). Pasting would
        // duplicate → trust the AX status.
        XCTAssertNil(
            InsertVerifier.axInsertReflected(expected: "teh quick fix", before: "note: ", current: "note: the quick fix")
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

    // MARK: - InsertThreadPolicy (self-process AX mutation must hop to main thread)

    func testInsertRequiresMainThreadWhenElementIsSelfProcess() {
        // Dictating into OpenWhisp's OWN text field (e.g. a Settings Substitutions
        // "Heard" cell): the AX set is serviced in-process by AppKit/TSM, which
        // asserts the main queue and SIGTRAPs if run on the background insert queue.
        // The regression this guards: that crash. Same pid → must run on main.
        XCTAssertTrue(
            InsertThreadPolicy.requiresMainThread(elementPID: 4242, selfPID: 4242)
        )
    }

    func testInsertStaysOffMainThreadForCrossAppTarget() {
        // The normal path — dictating into ANOTHER app. The set goes over XPC and
        // is serviced on the target's main thread, so we keep it on the insert
        // queue (off our main thread) as before.
        XCTAssertFalse(
            InsertThreadPolicy.requiresMainThread(elementPID: 99, selfPID: 4242)
        )
    }

    func testInsertStaysOffMainThreadWhenPIDUnknown() {
        // AX couldn't report a pid → treat as out-of-process (safe default: the
        // cross-app path never trips the TSM assertion).
        XCTAssertFalse(
            InsertThreadPolicy.requiresMainThread(elementPID: nil, selfPID: 4242)
        )
    }

    // MARK: - InsertionMode (MAK-42 adds .appleScript)

    func testInsertionModeFromIdRoundTrip() {
        XCTAssertEqual(InsertionMode.from(id: "auto"), .auto)
        XCTAssertEqual(InsertionMode.from(id: "directAX"), .directAX)
        XCTAssertEqual(InsertionMode.from(id: "paste"), .paste)
        XCTAssertEqual(InsertionMode.from(id: "appleScript"), .appleScript)
        // Unknown ids fall back to the safe default, never a crash.
        XCTAssertEqual(InsertionMode.from(id: "bogus"), .auto)
    }

    func testEveryInsertionModeHasALabel() {
        for mode in [InsertionMode.auto, .directAX, .paste, .appleScript] {
            XCTAssertFalse(mode.label.isEmpty)
        }
    }
}
