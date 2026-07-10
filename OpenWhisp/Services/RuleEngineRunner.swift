import Foundation
import AppKit

/// App-side executor for the rules engine (MAK-43): takes the ordered `[PlannedAction]`
/// the pure `RulePlanner` produced and runs each one on the EXISTING delivery layer.
///
/// It adds NO new delivery code — every action maps onto something that already
/// ships:
///   - `appendFile`   → `FileOutputTarget`  (MAK-12)
///   - `postWebhook`  → `WebhookOutputTarget`(MAK-14)
///   - `runShortcut`  → `ShortcutOutputTarget`(MAK-13)
///   - `runShell`     → `ScriptRunner`       (the hardened stdin→stdout subprocess)
///   - `insertSnippet`→ the injected text inserter (the same `TextOutput` seam)
///   - `openURL`      → `NSWorkspace.open`
///
/// **Fail-open / side-channel contract.** This runner is a SIDE CHANNEL invoked
/// AFTER the normal transcript insert has been dispatched. It never returns text to
/// the insert path and never throws into it; a failing or slow action affects only
/// itself. Sinks already fail open by contract (`.failedFallback`) — here that
/// simply means "the action didn't land"; there is no focused-app re-route because
/// the transcript was already delivered by the caller. Runs off the main thread so
/// a shell/shortcut action can't block finalization.
///
/// Lives OUTSIDE `OpenWhispCore` (not in Package.swift) because it links AppKit,
/// `Process`, and `URLSession` via the sinks; the decision logic it obeys is the
/// `swift test`-covered `RulePlanner`.
final class RuleEngineRunner {
    /// How a snippet is inserted into the focused app. Injected as a closure so the
    /// runner doesn't reach into `AppState`; the app passes a thin adapter over its
    /// `TextOutput.insert`.
    typealias SnippetInserter = (_ text: String) -> Void
    /// Opens a URL (the app passes `NSWorkspace.shared.open`); injectable for tests.
    typealias URLOpener = (_ url: URL) -> Void

    private let insertSnippet: SnippetInserter
    private let openURL: URLOpener
    /// Bounded timeout for a rule's shell action, mirroring `ScriptRunner`'s default.
    private let shellTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.openwhisp.app.rule-engine", qos: .utility)

    init(
        insertSnippet: @escaping SnippetInserter,
        openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        shellTimeout: TimeInterval = 2.0
    ) {
        self.insertSnippet = insertSnippet
        self.openURL = openURL
        self.shellTimeout = shellTimeout
    }

    /// Run every planned action for one finished dictation. `payload` carries the
    /// transcript + metadata the sinks need; `plan` is what `RulePlanner.plan`
    /// returned. Non-blocking: dispatches the work and returns immediately, so the
    /// finalize path is never held up by a rule's I/O.
    func run(_ plan: [PlannedAction], payload: OutputPayload) {
        guard !plan.isEmpty else { return }
        queue.async { [self] in
            for planned in plan {
                perform(planned.action, payload: payload)
            }
        }
    }

    /// Perform one action. Every branch is best-effort and swallows its own failures
    /// (logged via the sink's fail-open reason where relevant) so one bad action
    /// never aborts the rest of the plan.
    private func perform(_ action: RuleAction, payload: OutputPayload) {
        switch action {
        case .insertSnippet(let text):
            // Snippet is fixed local text (not the transcript); insert on the main
            // thread where the inserter expects to run.
            DispatchQueue.main.async { [insertSnippet] in insertSnippet(text) }

        case .openURL(let template):
            // Interpolate the transcript into `{{text}}`, percent-encoded so it can't
            // break out of the URL. A template with no token just opens as-is.
            guard let url = RuleURLBuilder.build(template: template, text: payload.text) else { return }
            DispatchQueue.main.async { [openURL] in openURL(url) }

        case .runShell(let scriptPath):
            // Reuse the hardened runner: transcript on stdin only (never argv), 2 s
            // timeout, SIGTERM→SIGKILL. We ignore its returned text — a rule shell
            // action is fire-and-observe, not a transcript rewrite.
            _ = ScriptRunner.run(payload.text, scriptPath: scriptPath, timeout: shellTimeout)

        case .runShortcut(let name):
            // Reuse the Shortcut sink; its completion is delivered on a GLOBAL queue
            // (never our serial `queue`) so the semaphore wait below can't deadlock
            // against the completion that would signal it.
            deliver(ShortcutOutputTarget(shortcutName: name, completionQueue: Self.completionQueue), payload: payload)

        case .postWebhook(let config):
            deliver(WebhookOutputTarget(config: config, completionQueue: Self.completionQueue), payload: payload)

        case .appendFile(let config):
            // FileOutputTarget delivers its completion on `.main`; the semaphore wait
            // below runs on our serial `queue` (not main), so it doesn't block main.
            deliver(FileOutputTarget(config: config), payload: payload)
        }
    }

    /// A concurrent queue for sink completions, kept SEPARATE from the serial work
    /// `queue`: a sink that hands its callback back on `completionQueue.async` must
    /// not enqueue behind the `deliver` call that is blocking `queue` on the
    /// semaphore — that would deadlock until the 30 s cap.
    private static let completionQueue = DispatchQueue(label: "com.openwhisp.app.rule-engine.completion",
                                                       attributes: .concurrent)

    /// Drive an `OutputTarget` sink to completion, blocking this serial queue until
    /// it reports back so the plan runs its actions in order. A sink that never calls
    /// back can't hang us forever — a generous wall-clock cap releases the wait
    /// (the sinks have their own internal timeouts well under this).
    private func deliver(_ target: OutputTarget, payload: OutputPayload) {
        let done = DispatchSemaphore(value: 0)
        target.deliver(payload) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 30)
    }
}
