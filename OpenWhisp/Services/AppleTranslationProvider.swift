import AppKit
import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// App-side ONLY (not in OpenWhispCore): Apple's Translation framework + the
// SwiftUI/AppKit anchor below. The pure arm/offer decisions live in core
// (TextTranslationPolicy.swift) and are unit-tested there.

/// On-device TEXT translation via Apple's Translation framework (macOS 15+),
/// wrapped so the rest of the app can ask one plain async question: "translate
/// this string into that language, or tell me you couldn't".
///
/// Contract (the never-lose-text rule): `translate` returns the translation or
/// nil. It NEVER throws and NEVER hangs — every request carries a watchdog
/// timeout — and every caller falls back to the ORIGINAL text on nil.
enum AppleTextTranslation {

    /// Whether the on-device text-translation path exists on this OS. The app's
    /// deployment target is macOS 14; there this is false and the feature is
    /// simply unavailable (offer gates dim, sessions never arm the text path).
    static var isSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    /// Translate `text` into `targetLanguage` (a BCP-47-ish tag: "en", "es",
    /// "pt-BR"). Nil when the OS can't translate text, on any framework error
    /// (missing language assets, unsupported pairing), or on timeout.
    @MainActor
    static func translate(_ text: String, to targetLanguage: String) async -> String? {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return nil }
        return await AppleTranslationProvider.shared.translate(text, to: targetLanguage)
        #else
        return nil
        #endif
    }

    /// Last framework error, for status surfaces ("kept original text").
    @MainActor
    static var lastError: String? {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return nil }
        return AppleTranslationProvider.shared.lastError
        #else
        return nil
        #endif
    }

    /// The stream-overlay server's injected `Translator` closure, or nil when
    /// this OS can't translate text. The server already treats a nil result as
    /// "keep the original caption line" — the same never-lose-text fallback.
    @MainActor
    static func overlayTranslator() -> (@Sendable (String, String) async -> String?)? {
        guard isSupported else { return nil }
        return { text, target in
            await translate(text, to: target)
        }
    }
}

#if canImport(Translation)

/// The hidden-anchor `TranslationSession` broker.
///
/// Apple gives no direct initializer for `TranslationSession`; the ONLY way to
/// obtain one is SwiftUI's `.translationTask(configuration:)` view modifier. So
/// this provider keeps a persistent, invisible anchor — a 1×1, alpha-0,
/// offscreen borderless `NSWindow` hosting a SwiftUI view that carries
/// `.translationTask` — alive for the app's lifetime. Publishing a new
/// `TranslationSession.Configuration` (re)triggers the modifier; its action
/// hands us a live session, which we hold inside the action (`serve`) and use
/// to drain a MainActor request queue until SwiftUI cancels the action (next
/// configuration change / teardown).
///
/// The configuration always uses a nil SOURCE language so the framework
/// auto-detects what was dictated; only the target is pinned. When a queued
/// request wants a different target than the live session, the provider swaps
/// the configuration and lets the replacement session serve it.
@available(macOS 15.0, *)
@MainActor
final class AppleTranslationProvider: ObservableObject {

    static let shared = AppleTranslationProvider()

    /// Per-request deadline. Generous because the first translation after a
    /// configuration change can include model load — and, when language assets
    /// are missing, the framework's download flow. Callers show "Translating…"
    /// while they wait; on timeout the request resolves nil and the caller
    /// keeps the original text (never a hang, never a loss).
    static let requestTimeout: TimeInterval = 12

    /// Drives the anchor's `.translationTask`. Nil until the first request;
    /// replaced (→ session restart) when the target language changes.
    @Published private(set) var configuration: TranslationSession.Configuration?

    /// Last framework error, for status surfaces.
    private(set) var lastError: String?

    /// One queued translate call. A class so the serve loop and the watchdog
    /// can race to finish it exactly once (MainActor-confined — no lock).
    private final class Request {
        let text: String
        let target: String
        private var continuation: CheckedContinuation<String?, Never>?

        init(text: String, target: String) {
            self.text = text
            self.target = target
        }

        func adopt(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        var isFinished: Bool { continuation == nil }

        /// Resume the caller exactly once; later calls are no-ops (e.g. the
        /// session's late result after the watchdog already fired).
        func finish(returning value: String?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// FIFO of unserved requests. MainActor-only.
    private var pending: [Request] = []
    /// Serve loops parked waiting for work; resumed by enqueue/cancel. An array
    /// (not a single slot) so a cancelled loop's late wake can never strand the
    /// replacement loop's continuation.
    private var parked: [CheckedContinuation<Void, Never>] = []
    /// The target language of the live/incoming configuration.
    private var currentTarget: String?
    /// The invisible SwiftUI anchor hosting `.translationTask`.
    private var anchorWindow: NSWindow?

    // MARK: - Public API

    /// Translate `text` into `targetLanguage`. Nil on any failure or timeout —
    /// callers keep the original text.
    func translate(_ text: String, to targetLanguage: String) async -> String? {
        let target = Self.normalizedTarget(targetLanguage)
        guard !target.isEmpty, !text.isEmpty else { return nil }
        ensureAnchor()
        retarget(target)

        let request = Request(text: text, target: target)
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            request.adopt(c)
            pending.append(request)
            wakeAllParked()
            // Watchdog: no session may ever strand a dictation. If nothing
            // serves this request in time (assets missing and the download
            // prompt unanswered, framework stall), fail it — the caller falls
            // back to the original text.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                guard !request.isFinished else { return }
                if let self {
                    self.pending.removeAll { $0 === request }
                    if self.lastError == nil { self.lastError = "Translation timed out" }
                }
                request.finish(returning: nil)
            }
        }
    }

    // MARK: - Session serving (runs inside the anchor's .translationTask action)

    /// Drain the request queue with `session`. Runs as the `.translationTask`
    /// action; the session is only valid inside it, so the loop holds it here
    /// until SwiftUI cancels the action (configuration change / teardown).
    func serve(_ session: TranslationSession) async {
        // Surface the download flow once per session: when language assets are
        // missing this asks the OS to fetch them (it can present a consent
        // prompt). Failure is non-fatal — translate calls below just fail and
        // callers keep their original text.
        do {
            try await session.prepareTranslation()
            lastError = nil
        } catch {
            lastError = "Language assets not ready: \(error.localizedDescription)"
        }

        while !Task.isCancelled {
            guard let request = pending.first else {
                await parkUntilWork()
                continue
            }
            guard request.target == currentTarget else {
                // Queued for a different target (dictation wants "en" while the
                // overlay wants "es"). Swap the configuration — SwiftUI cancels
                // THIS action and starts a fresh session that serves it. The
                // request stays queued; its watchdog still bounds the wait.
                retarget(request.target)
                return
            }
            pending.removeFirst()
            do {
                let response = try await session.translate(request.text)
                // Clear the sticky error on success so a LATER failure's status
                // ("Kept original text — …") can't cite a stale cause.
                lastError = nil
                request.finish(returning: response.targetText)
            } catch {
                lastError = error.localizedDescription
                request.finish(returning: nil)
            }
        }
    }

    /// Park the serve loop until a request arrives or the action is cancelled.
    private func parkUntilWork() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || !pending.isEmpty {
                    c.resume()
                    return
                }
                parked.append(c)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wakeAllParked() }
        }
    }

    /// Wake every parked serve loop; each re-checks its own cancellation/queue
    /// state (a spurious wake just re-parks). Safe against the cancelled-loop /
    /// replacement-loop overlap during a configuration swap.
    private func wakeAllParked() {
        let waiters = parked
        parked = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Configuration / anchor plumbing

    /// Point the anchor's configuration at `target` (nil SOURCE — the framework
    /// auto-detects the dictated language). No-op when already there, so a
    /// stream of same-target requests keeps one long-lived session.
    private func retarget(_ target: String) {
        guard currentTarget != target || configuration == nil else { return }
        currentTarget = target
        configuration = TranslationSession.Configuration(
            source: nil,
            target: Locale.Language(identifier: target))
    }

    /// Lazily build the persistent invisible anchor: a borderless, alpha-0,
    /// click-through, offscreen 1×1 window whose content view carries the
    /// `.translationTask` modifier. It must be ordered into the window list so
    /// SwiftUI mounts the view (and with it the task); it is never key, never
    /// visible, and lives for the app's lifetime.
    private func ensureAnchor() {
        guard anchorWindow == nil else { return }
        let host = NSHostingView(rootView: TranslationAnchorView(provider: self))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.alphaValue = 0
        window.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = host
        window.orderBack(nil)
        anchorWindow = window
    }

    /// "pt-BR"-style tag the framework accepts: trimmed, underscores dashed.
    private static func normalizedTarget(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }
}

/// The invisible SwiftUI view that owns the `.translationTask`. Re-runs its
/// action whenever the provider publishes a new configuration; with a nil
/// configuration the framework runs nothing.
@available(macOS 15.0, *)
private struct TranslationAnchorView: View {
    @ObservedObject var provider: AppleTranslationProvider

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(provider.configuration) { session in
                await provider.serve(session)
            }
    }
}

#endif
