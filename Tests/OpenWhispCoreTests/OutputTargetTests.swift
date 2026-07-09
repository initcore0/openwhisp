import XCTest
@testable import OpenWhispCore

/// Tests for the M9 output-target routing foundation (MAK-11): the pure picking
/// rules, the fail-open contract, and the payload shape. Uses fake `OutputTarget`
/// and `TextOutput` doubles — no AppKit, no window server.

// MARK: - Doubles

/// A recording `TextOutput` (mirrors `SpyTextOutput` in TextOutputTests, renamed
/// to avoid a cross-file collision) so the `FocusedAppOutputTarget` adapter can be
/// asserted without touching AX/clipboard.
private final class RecordingTextOutput: TextOutput {
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
    func setClipboard(_ text: String) { clipboardWrites.append(text) }
}

/// A configurable fake target. Records every payload it's asked to deliver and
/// returns a preset outcome — so a stub that ALWAYS fails can exercise fail-open.
private final class FakeTarget: OutputTarget {
    let kind: OutputTargetKind
    private let outcome: OutputDelivery
    private(set) var delivered: [OutputPayload] = []

    init(kind: OutputTargetKind, outcome: OutputDelivery) {
        self.kind = kind
        self.outcome = outcome
    }

    func deliver(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void) {
        delivered.append(payload)
        completion(outcome)
    }
}

private func payload(
    _ text: String = "hello world",
    language: String = "en",
    bundleID: String? = "com.example.app",
    isLiveChunk: Bool = false
) -> OutputPayload {
    OutputPayload(text: text, language: language, targetAppBundleID: bundleID, isLiveChunk: isLiveChunk)
}

final class OutputTargetTests: XCTestCase {

    // MARK: resolveKind (pure picking rule)

    func testResolveKindDefaultsToFocusedAppWhenNoSelection() {
        XCTAssertEqual(OutputRouter.resolveKind(for: "com.example.app", in: []), .focusedApp)
    }

    func testResolveKindDefaultsToFocusedAppWhenBundleIDIsNil() {
        let selections = [OutputTargetSelection(appBundleID: "com.example.app", kind: .file)]
        XCTAssertEqual(OutputRouter.resolveKind(for: nil, in: selections), .focusedApp)
    }

    func testResolveKindUsesPerAppSelection() {
        let selections = [
            OutputTargetSelection(appBundleID: "com.example.notes", kind: .file),
            OutputTargetSelection(appBundleID: "com.example.chat", kind: .webhook),
        ]
        XCTAssertEqual(OutputRouter.resolveKind(for: "com.example.chat", in: selections), .webhook)
        XCTAssertEqual(OutputRouter.resolveKind(for: "com.example.notes", in: selections), .file)
    }

    func testResolveKindUnmatchedBundleDefaultsToFocusedApp() {
        let selections = [OutputTargetSelection(appBundleID: "com.example.notes", kind: .file)]
        XCTAssertEqual(OutputRouter.resolveKind(for: "com.other.app", in: selections), .focusedApp)
    }

    // MARK: target(for:) — selection maps to the registered target

    func testRouterPicksSelectedRegisteredTarget() {
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let fileTarget = FakeTarget(kind: .file, outcome: .delivered)
        let router = OutputRouter(
            defaultTarget: def,
            targets: [fileTarget],
            selections: [OutputTargetSelection(appBundleID: "com.example.notes", kind: .file)]
        )
        XCTAssertTrue(router.target(for: "com.example.notes") === fileTarget)
    }

    func testRouterFallsToDefaultWhenNoTargetRegisteredForSelectedKind() {
        // A reserved-but-unimplemented kind is selected but no target is registered
        // for it → the router resolves straight to the default (never a nil sink).
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let router = OutputRouter(
            defaultTarget: def,
            targets: [],
            selections: [OutputTargetSelection(appBundleID: "com.example.notes", kind: .webhook)]
        )
        XCTAssertTrue(router.target(for: "com.example.notes") === def)
    }

    func testRouterUsesDefaultWhenNoSelection() {
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let router = OutputRouter(defaultTarget: def)
        XCTAssertTrue(router.target(for: "com.example.app") === def)
    }

    // MARK: route — delivery to the selected target

    func testRouteDeliversToSelectedTarget() {
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let fileTarget = FakeTarget(kind: .file, outcome: .delivered)
        let router = OutputRouter(
            defaultTarget: def,
            targets: [fileTarget],
            selections: [OutputTargetSelection(appBundleID: "com.example.notes", kind: .file)]
        )

        var result: OutputDelivery?
        router.route(payload("note this", bundleID: "com.example.notes")) { result = $0 }

        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(fileTarget.delivered.count, 1)
        XCTAssertEqual(fileTarget.delivered.first?.text, "note this")
        // The default focused-app insert was NOT touched — the file target handled it.
        XCTAssertTrue(spy.insertions.isEmpty)
    }

    func testRouteWithNoSelectionGoesToFocusedAppInsert() {
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let router = OutputRouter(defaultTarget: def)

        var result: OutputDelivery?
        router.route(payload("just type it", bundleID: "com.example.app")) { result = $0 }

        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(spy.insertions.map(\.text), ["just type it"])
    }

    // MARK: fail-open contract

    func testRouteFailsOpenToDefaultAndNeverDropsText() {
        // The selected target ALWAYS fails → the router must re-route the SAME
        // payload to the default focused-app insert. Text is never dropped.
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let flaky = FakeTarget(kind: .webhook, outcome: .failedFallback(reason: "offline"))
        let router = OutputRouter(
            defaultTarget: def,
            targets: [flaky],
            selections: [OutputTargetSelection(appBundleID: "com.example.chat", kind: .webhook)]
        )

        var result: OutputDelivery?
        router.route(payload("do not lose me", bundleID: "com.example.chat")) { result = $0 }

        // The failing target was tried once...
        XCTAssertEqual(flaky.delivered.count, 1)
        // ...then the SAME text landed in the focused-app insert (never dropped).
        XCTAssertEqual(spy.insertions.map(\.text), ["do not lose me"])
        // Final outcome after the fallback is delivered.
        XCTAssertEqual(result, .delivered)
    }

    func testRouteFailOpenForwardsIdenticalPayload() {
        // The payload re-routed on fail-open is byte-for-byte the original.
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let flaky = FakeTarget(kind: .file, outcome: .failedFallback(reason: "disk full"))
        let router = OutputRouter(
            defaultTarget: def,
            targets: [flaky],
            selections: [OutputTargetSelection(appBundleID: "com.example.notes", kind: .file)]
        )

        let p = payload("exactly this", language: "de", bundleID: "com.example.notes", isLiveChunk: true)
        router.route(p) { _ in }

        XCTAssertEqual(flaky.delivered, [p])
        XCTAssertEqual(spy.insertions.map(\.text), ["exactly this"])
    }

    // MARK: payload shape

    func testPayloadCarriesAllContractFields() {
        let p = payload("body", language: "fr", bundleID: "com.example.editor", isLiveChunk: true)
        XCTAssertEqual(p.text, "body")
        XCTAssertEqual(p.language, "fr")
        XCTAssertEqual(p.targetAppBundleID, "com.example.editor")
        XCTAssertTrue(p.isLiveChunk)
    }

    func testFocusedAppTargetForwardsPayloadTextToTextOutput() {
        let spy = RecordingTextOutput()
        let target = FocusedAppOutputTarget(textOutput: spy, mode: .paste, restoreClipboard: false)
        XCTAssertEqual(target.kind, .focusedApp)

        var result: OutputDelivery?
        target.deliver(payload("adapted", bundleID: nil)) { result = $0 }

        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(spy.insertions, [
            .init(text: "adapted", mode: .paste, restoreClipboard: false)
        ])
    }

    // MARK: kind & selection Codable round-trips

    func testOutputTargetKindRawValuesAreStable() {
        // The persisted string is a stored-selection contract — pin the raw values.
        XCTAssertEqual(OutputTargetKind.focusedApp.rawValue, "focusedApp")
        XCTAssertEqual(OutputTargetKind.file.rawValue, "file")
        XCTAssertEqual(OutputTargetKind.shortcut.rawValue, "shortcut")
        XCTAssertEqual(OutputTargetKind.webhook.rawValue, "webhook")
        XCTAssertEqual(OutputTargetKind(rawValue: "focusedApp"), .focusedApp)
        XCTAssertNil(OutputTargetKind(rawValue: "nonsense"))
    }

    func testOutputTargetSelectionCodableRoundTrips() throws {
        let selections = [
            OutputTargetSelection(appBundleID: "com.example.notes", kind: .file),
            OutputTargetSelection(appBundleID: "com.example.chat", kind: .webhook),
        ]
        let data = try JSONEncoder().encode(selections)
        let decoded = try JSONDecoder().decode([OutputTargetSelection].self, from: data)
        XCTAssertEqual(decoded, selections)
    }

    func testSelectionKindLookup() {
        let selections = [OutputTargetSelection(appBundleID: "com.example.notes", kind: .file)]
        XCTAssertEqual(OutputTargetSelection.kind(for: "com.example.notes", in: selections), .file)
        XCTAssertNil(OutputTargetSelection.kind(for: "com.other", in: selections))
        XCTAssertNil(OutputTargetSelection.kind(for: nil, in: selections))
    }
}
