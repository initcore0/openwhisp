import Foundation

/// Where a dictation result is sent (M9 foundation).
///
/// Today the app has exactly one sink: insert into the focused app (`TextOutput`
/// / macOS `TextInserter`). `OutputTarget` generalizes that seam so a dictation
/// can instead be routed somewhere else — a file, a Shortcut, a webhook — chosen
/// per-app or per-profile. Those concrete sinks are SEPARATE tickets (MAK-12/13/14)
/// that implement this protocol; THIS layer is only the protocol, the delivery
/// context, the fail-open contract, and the pure `OutputRouter` that picks a target
/// and enforces the fail-open rule.
///
/// Foundation-only so it lives in `OpenWhispCore` and is `swift test`-able without
/// AppKit — the router and its decision logic are the testable heart.

// MARK: - Selectable identity

/// The selectable identity of an output target, stored per-app / per-profile.
///
/// `.focusedApp` is the default (and today the only implemented target): insert
/// into whatever app is frontmost, i.e. the historical behavior. The remaining
/// cases are RESERVED for the concrete-sink tickets so a selection persisted now
/// round-trips once those land; the router treats any kind with no registered
/// target as "fall back to focused-app" (fail-open), so an unimplemented reserved
/// selection never drops text.
enum OutputTargetKind: String, Codable, CaseIterable {
    /// Insert into the focused app — the default, wrapping the existing `TextOutput`.
    case focusedApp
    /// Reserved: write to a file / notes vault (MAK-12).
    case file
    /// Reserved: hand off to a macOS Shortcut (MAK-13).
    case shortcut
    /// Reserved: POST to a webhook (MAK-14).
    case webhook
}

// MARK: - Delivery context

/// Everything a target needs to deliver one dictation result. Exactly the four
/// fields the ticket's contract names: `{text, language, targetAppBundleID,
/// isLiveChunk}`.
struct OutputPayload: Equatable {
    /// The dictated text to deliver.
    let text: String
    /// BCP-47-ish language code of the transcription (e.g. "en", "auto").
    let language: String
    /// Bundle ID of the app that was frontmost at dictation start, if known —
    /// lets a target route/label by app (nil when the frontmost app is unknown).
    let targetAppBundleID: String?
    /// True for an incremental live-chunk insert mid-session; false for the final
    /// delivery. A non-insert target may choose to ignore live chunks and only act
    /// on the final result.
    let isLiveChunk: Bool

    init(text: String, language: String, targetAppBundleID: String?, isLiveChunk: Bool) {
        self.text = text
        self.language = language
        self.targetAppBundleID = targetAppBundleID
        self.isLiveChunk = isLiveChunk
    }
}

// MARK: - Delivery outcome (fail-open contract)

/// The result a target reports back — this IS the fail-open contract.
///
/// A target that cannot deliver MUST report `.failedFallback` (never throw text
/// away and never report `.delivered`). The `OutputRouter` responds by re-routing
/// the SAME payload to the default focused-app insert target, so text is never
/// dropped just because a fancy sink was misconfigured or offline.
enum OutputDelivery: Equatable {
    /// The target delivered the payload; nothing more to do.
    case delivered
    /// The target could not deliver — the router falls back to focused-app insert.
    /// `reason` is a short human-readable note for logging/telemetry.
    case failedFallback(reason: String)
}

// MARK: - The target protocol

/// A destination for a dictation result. Callback style (mirrors `TextOutput`) so
/// implementations can do async work (file I/O, a network POST, a Shortcut run) and
/// report the fail-open outcome when they finish. `completion` is invoked exactly
/// once, on the caller's expected thread (the main thread in the app).
protocol OutputTarget: AnyObject {
    /// A stable identity so a selection can name this target and the router can key
    /// on it.
    var kind: OutputTargetKind { get }

    /// Deliver `payload`, calling `completion` exactly once with the outcome. A
    /// target that can't deliver reports `.failedFallback(reason:)` rather than
    /// throwing text away.
    func deliver(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void)
}

// MARK: - Default focused-app target

/// The trivial default target: forward the payload to the existing `TextOutput`
/// insert path (i.e. type/paste into the focused app). Thin by design — it just
/// adapts `TextOutput` behind the `OutputTarget` protocol so the router always has
/// a real, always-available default to fall back to. Because it wraps the
/// insertion seam that already never loses text (AX → paste → clipboard), it
/// always reports `.delivered`.
final class FocusedAppOutputTarget: OutputTarget {
    let kind: OutputTargetKind = .focusedApp

    private let textOutput: TextOutput
    private let mode: InsertionMode
    private let restoreClipboard: Bool

    /// - Parameters:
    ///   - textOutput: the insertion seam to forward to.
    ///   - mode: insertion mode for the forwarded insert (defaults to `.auto`).
    ///   - restoreClipboard: whether a paste fallback should restore the prior
    ///     clipboard.
    init(textOutput: TextOutput, mode: InsertionMode = .auto, restoreClipboard: Bool = true) {
        self.textOutput = textOutput
        self.mode = mode
        self.restoreClipboard = restoreClipboard
    }

    func deliver(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void) {
        textOutput.insert(payload.text, mode: mode, restoreClipboard: restoreClipboard) { _ in
            // The insertion seam itself already fails open (AX → paste → clipboard,
            // never dropping text), so from the router's perspective the focused-app
            // target always delivers.
            completion(.delivered)
        }
    }
}

// MARK: - Per-app / per-profile selection

/// Which `OutputTargetKind` a given app routes to. Additive, standalone storage —
/// deliberately NOT folded into `AppProfile`'s stored schema (keeping profiles'
/// on-disk shape stable). A `nil`/absent selection means "use the default"
/// (focused-app). Codable so a future Settings surface can persist a map of these.
struct OutputTargetSelection: Codable, Equatable {
    /// Frontmost app bundle ID this selection applies to.
    var appBundleID: String
    /// The target kind to route dictations for this app to.
    var kind: OutputTargetKind

    init(appBundleID: String, kind: OutputTargetKind) {
        self.appBundleID = appBundleID
        self.kind = kind
    }

    /// The kind selected for `bundleID`, if any selection matches — pure lookup a
    /// resolver/router consumes. Returns nil when there's no per-app selection (→
    /// caller uses the default focused-app kind).
    static func kind(for bundleID: String?, in selections: [OutputTargetSelection]) -> OutputTargetKind? {
        guard let bundleID else { return nil }
        return selections.first { $0.appBundleID == bundleID }?.kind
    }
}

// MARK: - The router (pure decision logic + fail-open enforcement)

/// Routes an `OutputPayload` to the right target and enforces the fail-open rule.
///
/// Given the registered targets, a per-app/profile selection, and the always-present
/// default focused-app target, the router:
///   1. resolves which `OutputTargetKind` should handle the payload (the app's
///      selection, or `.focusedApp` when there's none),
///   2. finds the registered target for that kind (or the default when none is
///      registered — an unimplemented reserved kind never drops text),
///   3. delivers, and on `.failedFallback` re-routes the SAME payload to the
///      default focused-app target.
///
/// The default target is assumed to always deliver (it wraps the never-lose-text
/// insertion seam); the router does not recurse a second time. This class holds
/// references to the targets but its decision logic (`resolveKind`) is a pure
/// static function so the picking rules are unit-testable in isolation.
final class OutputRouter {
    /// The default target used when no selection is made, no target is registered
    /// for the selected kind, or a target fails open. Always the focused-app insert.
    private let defaultTarget: OutputTarget
    /// Non-default targets, keyed by kind. The default target is never stored here.
    private let targetsByKind: [OutputTargetKind: OutputTarget]
    /// Per-app selection of which kind to route to (nil-match → default).
    private let selections: [OutputTargetSelection]

    /// - Parameters:
    ///   - defaultTarget: the always-available fallback (focused-app insert).
    ///   - targets: additional registered targets; any whose `kind` equals the
    ///     default's is ignored (the default always wins that slot).
    ///   - selections: per-app target selection (empty = everything uses default).
    init(
        defaultTarget: OutputTarget,
        targets: [OutputTarget] = [],
        selections: [OutputTargetSelection] = []
    ) {
        self.defaultTarget = defaultTarget
        var byKind: [OutputTargetKind: OutputTarget] = [:]
        for target in targets where target.kind != defaultTarget.kind {
            byKind[target.kind] = target
        }
        self.targetsByKind = byKind
        self.selections = selections
    }

    /// Pure: which kind should handle a payload for `bundleID`, given `selections`.
    /// Falls back to `.focusedApp` when there's no per-app selection. Kept static
    /// and side-effect-free so the picking rule is testable without any targets.
    static func resolveKind(
        for bundleID: String?,
        in selections: [OutputTargetSelection]
    ) -> OutputTargetKind {
        OutputTargetSelection.kind(for: bundleID, in: selections) ?? .focusedApp
    }

    /// The target that will handle a payload for `bundleID` BEFORE any fail-open
    /// fallback: the registered target for the resolved kind, or the default when
    /// no target is registered for that kind (reserved-but-unimplemented kinds
    /// resolve straight to the default). Exposed for testing/introspection.
    func target(for bundleID: String?) -> OutputTarget {
        let kind = OutputRouter.resolveKind(for: bundleID, in: selections)
        if kind == defaultTarget.kind { return defaultTarget }
        return targetsByKind[kind] ?? defaultTarget
    }

    /// Route `payload` to its target, applying the fail-open rule. `completion`
    /// reports the FINAL outcome after any fallback: `.delivered` when either the
    /// selected target or (after a fail-open) the default delivered; the default is
    /// trusted to always deliver, so the final outcome is effectively always
    /// `.delivered` — but the type is preserved for callers that want to observe a
    /// fallback happening. `completion` is called exactly once.
    func route(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void) {
        let selected = target(for: payload.targetAppBundleID)
        // Already on the default → deliver directly; no fallback is possible/needed.
        guard selected !== defaultTarget else {
            defaultTarget.deliver(payload, completion: completion)
            return
        }
        // Latch: only the FIRST outcome from the selected target counts. A
        // misbehaving target that invokes its completion more than once (a network
        // callback firing twice, or `.delivered` followed by a late
        // `.failedFallback`) must not make the router deliver the same text into
        // the focused app twice.
        var handled = false
        selected.deliver(payload) { [defaultTarget] outcome in
            guard !handled else { return }
            handled = true
            switch outcome {
            case .delivered:
                completion(.delivered)
            case .failedFallback:
                // Fail open: never drop text — re-route the SAME payload to the
                // default focused-app insert, which itself never loses text.
                defaultTarget.deliver(payload, completion: completion)
            }
        }
    }
}
