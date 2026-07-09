import XCTest
@testable import OpenWhispCore

/// Tests for the pure output-target resolver (the "which kind actually handles this,
/// and is it configured" decision the app-side router builder consumes). No AppKit.
final class OutputTargetResolverTests: XCTestCase {

    // MARK: - focusedApp is always configured / the default

    func testFocusedAppIsAlwaysConfigured() {
        let settings = OutputTargetSettings(kind: .focusedApp)
        XCTAssertTrue(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .focusedApp)
    }

    func testDefaultSettingsAreFocusedApp() {
        // The zero-config default must be today's behavior: focused-app insert.
        let settings = OutputTargetSettings()
        XCTAssertEqual(settings.kind, .focusedApp)
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .focusedApp)
    }

    // MARK: - file

    func testFileConfiguredWithPath() {
        let settings = OutputTargetSettings(kind: .file, file: FileOutputConfig(path: "~/notes.md"))
        XCTAssertTrue(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .file)
    }

    func testFileWithBlankPathFallsBackToFocusedApp() {
        let settings = OutputTargetSettings(kind: .file, file: FileOutputConfig(path: "   "))
        XCTAssertFalse(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .focusedApp)
    }

    // MARK: - webhook

    func testWebhookConfiguredWithAbsoluteURL() {
        let settings = OutputTargetSettings(kind: .webhook, webhook: WebhookConfig(url: "https://example.com/hook"))
        XCTAssertTrue(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .webhook)
    }

    func testWebhookWithEmptyURLFallsBackToFocusedApp() {
        let settings = OutputTargetSettings(kind: .webhook, webhook: WebhookConfig(url: ""))
        XCTAssertFalse(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .focusedApp)
    }

    func testWebhookWithNonAbsoluteURLFallsBackToFocusedApp() {
        // A bare host / relative string has no scheme → not a real endpoint.
        let settings = OutputTargetSettings(kind: .webhook, webhook: WebhookConfig(url: "example.com/hook"))
        XCTAssertFalse(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .focusedApp)
    }

    // MARK: - shortcut

    func testShortcutConfiguredWithName() {
        let settings = OutputTargetSettings(kind: .shortcut, shortcutName: "Add to Things")
        XCTAssertTrue(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .shortcut)
    }

    func testShortcutWithBlankNameFallsBackToFocusedApp() {
        let settings = OutputTargetSettings(kind: .shortcut, shortcutName: "   ")
        XCTAssertFalse(OutputTargetResolver.isConfigured(settings))
        XCTAssertEqual(OutputTargetResolver.effectiveKind(settings), .focusedApp)
    }

    // MARK: - persistence round-trip

    func testOutputTargetSettingsCodableRoundTrips() throws {
        let settings = OutputTargetSettings(
            kind: .file,
            file: FileOutputConfig(path: "~/vault/daily.md", template: "## {{datetime}}", mode: .append),
            webhook: WebhookConfig(url: "https://example.com/hook", headers: ["Authorization": "Bearer x"], timeout: 8),
            shortcutName: "Add to Things"
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputTargetSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - settings → router end-to-end (the wiring the app does, in core)

    /// A recording focused-app insert double, so the fallback path can be asserted
    /// without AppKit.
    private final class RecordingTextOutput: TextOutput {
        private(set) var insertions: [String] = []
        private(set) var clipboardWrites: [String] = []
        func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool,
                    completion: ((InsertionOutcome) -> Void)?) {
            insertions.append(text)
            completion?(.inserted)
        }
        func setClipboard(_ text: String) { clipboardWrites.append(text) }
    }

    /// A fake sink for a given kind with a preset outcome — stands in for the real
    /// File/Webhook/Shortcut sinks (which link Process/URLSession/AppKit).
    private final class FakeSink: OutputTarget {
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

    /// Build a router the way `AppState` does: resolve the effective kind from the
    /// settings, and only register a sink when the selection is configured. A global
    /// (not per-app) selection is modeled by applying the effective kind to whatever
    /// bundle is frontmost — so the router keys on a single selection covering the
    /// current app.
    private func router(
        for settings: OutputTargetSettings,
        bundleID: String?,
        default def: OutputTarget,
        sink: OutputTarget?
    ) -> OutputRouter {
        let effective = OutputTargetResolver.effectiveKind(settings)
        var targets: [OutputTarget] = []
        var selections: [OutputTargetSelection] = []
        if effective != .focusedApp, let sink, let bundleID {
            targets.append(sink)
            selections.append(OutputTargetSelection(appBundleID: bundleID, kind: effective))
        }
        return OutputRouter(defaultTarget: def, targets: targets, selections: selections)
    }

    func testConfiguredFileSelectionRoutesToTheFileSink() {
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let fileSink = FakeSink(kind: .file, outcome: .delivered)
        let settings = OutputTargetSettings(kind: .file, file: FileOutputConfig(path: "~/notes.md"))
        let router = router(for: settings, bundleID: "com.example.notes", default: def, sink: fileSink)

        var result: OutputDelivery?
        router.route(
            OutputPayload(text: "note this", language: "en", targetAppBundleID: "com.example.notes", isLiveChunk: false)
        ) { result = $0 }

        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(fileSink.delivered.map(\.text), ["note this"])
        XCTAssertTrue(spy.insertions.isEmpty, "configured file selection must not fall back to the focused app")
    }

    func testUnconfiguredSelectionRoutesToFocusedAppInsert() {
        // Kind is .webhook but the URL is blank → resolver folds to focusedApp, so no
        // sink is registered and the text types into the focused app exactly as today.
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let settings = OutputTargetSettings(kind: .webhook, webhook: WebhookConfig(url: ""))
        let router = router(for: settings, bundleID: "com.example.chat", default: def, sink: nil)

        var result: OutputDelivery?
        router.route(
            OutputPayload(text: "just type it", language: "en", targetAppBundleID: "com.example.chat", isLiveChunk: false)
        ) { result = $0 }

        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(spy.insertions, ["just type it"])
    }

    func testConfiguredButFailingSinkFallsOpenToFocusedApp() {
        // A configured webhook whose POST fails must re-route the SAME text to the
        // focused app — the fail-open contract that makes today's behavior the floor.
        let spy = RecordingTextOutput()
        let def = FocusedAppOutputTarget(textOutput: spy)
        let failing = FakeSink(kind: .webhook, outcome: .failedFallback(reason: "offline"))
        let settings = OutputTargetSettings(kind: .webhook, webhook: WebhookConfig(url: "https://example.com/hook"))
        let router = router(for: settings, bundleID: "com.example.chat", default: def, sink: failing)

        var result: OutputDelivery?
        router.route(
            OutputPayload(text: "do not lose me", language: "en", targetAppBundleID: "com.example.chat", isLiveChunk: false)
        ) { result = $0 }

        XCTAssertEqual(failing.delivered.count, 1)
        XCTAssertEqual(spy.insertions, ["do not lose me"], "fail-open must re-insert into the focused app")
        XCTAssertEqual(result, .delivered)
    }
}
