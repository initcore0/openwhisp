import AppKit
import Foundation
import NaturalLanguage
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
/// nil. It NEVER throws and NEVER hangs — missing-asset and unsupported pairs
/// fail FAST (the framework itself hangs on them), everything else carries a
/// watchdog timeout — and every caller falls back to the ORIGINAL text on nil.
enum AppleTextTranslation {

    /// Whether the on-device text-translation path exists on this OS. The app's
    /// deployment target is macOS 15, so in practice this is always true — the
    /// check is kept as cheap belt-and-braces (and so the `Translation` import
    /// stays optional for lean/host builds). If it ever answers false, the
    /// feature degrades quietly: offer gates dim, sessions never arm the text
    /// path, and no text is lost.
    static var isSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    /// Translate `text` into `targetLanguage` (a BCP-47-ish tag: "en", "es",
    /// "pt-BR"). `sourceHint` is the language the text is (probably) in — pass
    /// the session's language setting; nil/"auto"/empty falls back to on-device
    /// detection over the text itself (NLLanguageRecognizer). The source is
    /// ALWAYS resolved to an explicit language before the framework sees it: a
    /// nil-source `TranslationSession.Configuration` is broken in practice —
    /// `prepareTranslation` fails with `unableToIdentifyLanguage` and
    /// `translate` then hangs past any deadline (observed on macOS 26).
    ///
    /// Nil when the OS can't translate text, the pair is unsupported, language
    /// assets still need their one-time download (which this call kicks off),
    /// any framework error, or timeout.
    @MainActor
    static func translate(_ text: String, from sourceHint: String?, to targetLanguage: String) async -> String? {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return nil }
        return await AppleTranslationProvider.shared.translate(text, from: sourceHint, to: targetLanguage)
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
    /// No source hint here: caption lines are detected per-line (the overlay
    /// doesn't know the session language).
    @MainActor
    static func overlayTranslator() -> (@Sendable (String, String) async -> String?)? {
        guard isSupported else { return nil }
        return { text, target in
            await translate(text, from: nil, to: target)
        }
    }

    /// Asset state of one source→target pair, for the Settings status rows
    /// (`TranslationAssetStatusView`). Exists unconditionally, so the rows can
    /// render an "unavailable" state even where the framework is missing.
    enum AssetStatus: Equatable {
        /// Language assets are on disk — translation works right now.
        case installed
        /// The pair is supported but its assets need a one-time download.
        case needsDownload
        /// macOS translation can't do this pair at all.
        case unsupported
        /// No answer possible: no text translator on this OS, or no concrete
        /// source ("auto").
        case unavailable
    }

    /// Current asset state of `sourceTag`→`targetTag`. "auto"/empty source →
    /// `.unavailable` (no concrete pair to check — assets resolve on first use).
    @MainActor
    static func assetStatus(from sourceTag: String, to targetTag: String) async -> AssetStatus {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return .unavailable }
        return await AppleTranslationProvider.shared.assetStatus(from: sourceTag, to: targetTag)
        #else
        return .unavailable
        #endif
    }

    /// Kick off the one-time language-asset download for `sourceTag`→`targetTag`
    /// (presents the system consent sheet). User-initiated only — the Settings
    /// Download button; dictations never pop UI on their own.
    @MainActor
    static func requestAssetDownload(from sourceTag: String, to targetTag: String) {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return }
        AppleTranslationProvider.shared.requestDownload(from: sourceTag, to: targetTag)
        #endif
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
/// configuration change / teardown). The invisible anchor is proven to fire
/// (harness-tested): translation works headless as long as the pair's language
/// assets are INSTALLED.
///
/// **Missing assets are the sharp edge.** For a merely `supported` (not
/// installed) pair, `prepareTranslation`/`translate` hang indefinitely from an
/// invisible window — the consent sheet has nowhere to present. So `translate`
/// pre-checks `LanguageAvailability` and fails FAST on such pairs, while
/// kicking off a one-time visible consent flow: the anchor window becomes a
/// small centered panel for the duration of `prepareTranslation` (the system
/// download sheet presents from it), then goes invisible again. Once the user
/// approves and the download lands, the pair reads `.installed` and every later
/// request translates headless.
@available(macOS 15.0, *)
@MainActor
final class AppleTranslationProvider: ObservableObject {

    static let shared = AppleTranslationProvider()

    /// Per-request deadline. Generous because the first translation after a
    /// configuration change includes model load (~2.5s measured). Callers show
    /// "Translating…" while they wait; on timeout the request resolves nil and
    /// the caller keeps the original text (never a hang, never a loss).
    static let requestTimeout: TimeInterval = 12

    /// Drives the anchor's `.translationTask`. Nil until the first request;
    /// replaced (→ session restart) when the language pair changes.
    @Published private(set) var configuration: TranslationSession.Configuration?

    /// True while the anchor window is on screen hosting the one-time language
    /// download consent; drives the anchor view's visible body.
    @Published private(set) var presentingDownload = false

    /// Last framework error, for status surfaces.
    private(set) var lastError: String?

    /// One queued translate call. A class so the serve loop and the watchdog
    /// can race to finish it exactly once (MainActor-confined — no lock).
    private final class Request {
        let text: String
        let source: String
        let target: String
        private var continuation: CheckedContinuation<String?, Never>?

        init(text: String, source: String, target: String) {
            self.text = text
            self.source = source
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
    /// The language pair of the live/incoming configuration.
    private var currentPair: (source: String, target: String)?
    /// The invisible SwiftUI anchor hosting `.translationTask`.
    private var anchorWindow: NSWindow?

    // MARK: - Public API

    /// Translate `text` into `targetLanguage`. Nil on any failure or timeout —
    /// callers keep the original text. See `AppleTextTranslation.translate`.
    func translate(_ text: String, from sourceHint: String?, to targetLanguage: String) async -> String? {
        let target = Self.normalizedTag(targetLanguage)
        guard !target.isEmpty, !text.isEmpty else { return nil }
        guard let source = await resolveSourceCheckingAssets(
            hint: sourceHint, text: text, target: target) else {
            lastError = "Couldn't identify the dictated language"
            return nil
        }
        // Same language → nothing to translate; the original IS the result.
        if Self.baseCode(source) == Self.baseCode(target) { return text }

        // Fail FAST when the pair can't serve, instead of letting the request
        // ride the watchdog: the framework hangs (not errors) on not-installed
        // pairs, and 12 silent seconds per dictation reads as "broken".
        switch await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)) {
        case .installed:
            break
        case .supported:
            // Assets exist but need their one-time download. Fail fast and
            // point at Settings — mid-dictation is the wrong moment to pop a
            // consent sheet (a surprise window over whatever the user is
            // dictating into). The Settings row owns the download flow.
            lastError = "\(Self.pairName(source, target)) isn't downloaded — Settings → Dictation has the download"
            return nil
        case .unsupported:
            lastError = "\(Self.pairName(source, target)) isn't supported by macOS translation"
            return nil
        @unknown default:
            break
        }

        ensureAnchor()
        retarget(source: source, target: target)

        let request = Request(text: text, source: source, target: target)
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            request.adopt(c)
            pending.append(request)
            wakeAllParked()
            // Watchdog: no session may ever strand a dictation. If nothing
            // serves this request in time (framework stall), fail it — the
            // caller falls back to the original text.
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
        // For installed pairs this is a fast no-op; for a download-consent
        // session (anchor presented) it shows the system download sheet and
        // returns once the assets land (or the user declines).
        do {
            try await session.prepareTranslation()
            lastError = nil
        } catch {
            lastError = "Language assets not ready: \(error.localizedDescription)"
        }
        if presentingDownload { retractAnchor() }

        while !Task.isCancelled {
            guard let request = pending.first else {
                await parkUntilWork()
                continue
            }
            guard let pair = currentPair,
                  request.source == pair.source, request.target == pair.target else {
                // Queued for a different pair (dictation wants ru→en while the
                // overlay wants en→es). Swap the configuration — SwiftUI cancels
                // THIS action and starts a fresh session that serves it. The
                // request stays queued; its watchdog still bounds the wait.
                retarget(source: request.source, target: request.target)
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

    // MARK: - Language-asset status + download (the one visible moment)

    /// Asset state of one pair, for the Settings status rows. See
    /// `AppleTextTranslation.assetStatus`.
    func assetStatus(from sourceTag: String, to targetTag: String) async -> AppleTextTranslation.AssetStatus {
        let source = Self.normalizedTag(sourceTag)
        let target = Self.normalizedTag(targetTag)
        guard !source.isEmpty, source.lowercased() != "auto", !target.isEmpty else {
            return .unavailable
        }
        // Same language: nothing to download, translation is a no-op pass-through.
        if Self.baseCode(source) == Self.baseCode(target) { return .installed }
        switch await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unavailable
        }
    }

    /// USER-INITIATED download flow (the Settings row's Download button):
    /// present the anchor and point the configuration at the pair so the
    /// replacement session's `prepareTranslation` can show the system download
    /// consent from a REAL window. The Settings row polls `assetStatus` and
    /// flips to Installed when the download lands.
    func requestDownload(from sourceTag: String, to targetTag: String) {
        let source = Self.normalizedTag(sourceTag)
        let target = Self.normalizedTag(targetTag)
        guard !source.isEmpty, source.lowercased() != "auto", !target.isEmpty,
              Self.baseCode(source) != Self.baseCode(target),
              !presentingDownload else { return }
        ensureAnchor()
        presentAnchor()
        if let pair = currentPair, pair.source == source, pair.target == target,
           var live = configuration {
            // Same pair as the live session: invalidate to force a fresh action
            // (a new-but-equal configuration value may not re-trigger it).
            live.invalidate()
            configuration = live
        } else {
            currentPair = (source, target)
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target))
        }
    }

    /// Turn the invisible anchor into a small centered panel that can host the
    /// system download sheet.
    private func presentAnchor() {
        guard let window = anchorWindow, !presentingDownload else { return }
        presentingDownload = true
        window.styleMask = [.titled]
        window.title = "OpenWhisp — Translation"
        window.alphaValue = 1
        window.level = .floating
        window.setContentSize(NSSize(width: 380, height: 96))
        window.center()
        window.orderFrontRegardless()
        NSApp.activate()
    }

    /// Return the anchor to its invisible resting state.
    private func retractAnchor() {
        presentingDownload = false
        guard let window = anchorWindow else { return }
        window.styleMask = [.borderless]
        window.alphaValue = 0
        window.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.setFrame(NSRect(x: -4000, y: -4000, width: 1, height: 1), display: false)
        window.orderBack(nil)
    }

    // MARK: - Configuration / anchor plumbing

    /// Point the anchor's configuration at the EXPLICIT `source`→`target` pair.
    /// No-op when already there, so a stream of same-pair requests keeps one
    /// long-lived session. Never nil-source (see `AppleTextTranslation.translate`).
    private func retarget(source: String, target: String) {
        if let pair = currentPair, pair.source == source, pair.target == target,
           configuration != nil { return }
        currentPair = (source, target)
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target))
    }

    /// Lazily build the persistent invisible anchor: a borderless, alpha-0,
    /// click-through, offscreen 1×1 window whose content view carries the
    /// `.translationTask` modifier. It must be ordered into the window list so
    /// SwiftUI mounts the view (and with it the task); it is never key, never
    /// visible (except during a download consent), and lives for the app's
    /// lifetime.
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

    // MARK: - Language tags

    /// The session's language when it names one, else on-device detection over
    /// the text itself. Never returns "auto"; nil when even detection can't
    /// name a language (caller fails fast with a clear status).
    static func resolveSource(hint: String?, text: String) -> String? {
        if let hint {
            let tag = normalizedTag(hint)
            if !tag.isEmpty, tag.lowercased() != "auto" { return tag }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// `resolveSource`, hardened for "auto" sessions: instead of trusting the
    /// recognizer's single top guess, rank its hypotheses and prefer the
    /// best-confidence language whose pair with `target` is INSTALLED
    /// (`TextTranslationPolicy.pickDetectedSource`).
    ///
    /// The failure this closes: on the short Cyrillic fragments the live
    /// translation preview fires on, the top guess is often Ukrainian for
    /// RUSSIAN speech — uk→en is typically not downloaded, so the pre-check
    /// fail-fasted with "…isn't downloaded" while the user's real ru→en pair
    /// was installed and working (and the session FINAL, detected over the full
    /// text, translated fine). A concrete session-language hint still wins
    /// outright and skips all of this.
    private func resolveSourceCheckingAssets(
        hint: String?, text: String, target: String
    ) async -> String? {
        if let hint {
            let tag = Self.normalizedTag(hint)
            if !tag.isEmpty, tag.lowercased() != "auto" { return tag }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard !hypotheses.isEmpty else { return nil }

        // Resolve each candidate's install state up front (async), then let the
        // pure policy pick. The status query is cheap; at most 3 candidates.
        var installed = Set<String>()
        let availability = LanguageAvailability()
        for language in hypotheses.keys {
            let status = await availability.status(
                from: Locale.Language(identifier: language.rawValue),
                to: Locale.Language(identifier: target))
            if status == .installed { installed.insert(language.rawValue) }
        }
        return TextTranslationPolicy.pickDetectedSource(
            candidates: hypotheses.map { (code: $0.key.rawValue, confidence: $0.value) },
            isPairInstalled: { installed.contains($0) })
    }

    /// "pt-BR"-style tag the framework accepts: trimmed, underscores dashed.
    private static func normalizedTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }

    /// "pt" from "pt-BR" — for the same-language no-op check.
    static func baseCode(_ tag: String) -> String {
        tag.split(separator: "-").first.map { String($0).lowercased() } ?? tag.lowercased()
    }

    /// "Russian → English" — status text uses names, not tags.
    static func pairName(_ source: String, _ target: String) -> String {
        "\(LanguageResolver.displayName(for: source)) → \(LanguageResolver.displayName(for: target))"
    }
}

/// The invisible SwiftUI view that owns the `.translationTask`. Re-runs its
/// action whenever the provider publishes a new configuration; with a nil
/// configuration the framework runs nothing. During a language-asset download
/// consent it shows a small explanatory panel (the window is visible then);
/// the rest of the time it's a 1×1 clear pixel.
@available(macOS 15.0, *)
private struct TranslationAnchorView: View {
    @ObservedObject var provider: AppleTranslationProvider

    var body: some View {
        content
            .translationTask(provider.configuration) { session in
                await provider.serve(session)
            }
    }

    @ViewBuilder
    private var content: some View {
        if provider.presentingDownload {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preparing on-device translation")
                    .font(.headline)
                Text("macOS may ask to download a translation language. Approve it once — dictations translate from then on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 380)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

#endif
