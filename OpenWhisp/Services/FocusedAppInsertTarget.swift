import Foundation

/// The app-side default `OutputTarget` used by `AppState` when a configured sink is
/// selected: it performs the SAME focused-app insert the historical path does —
/// including the "couldn't insert — copied, press ⌘V" clipboard-fallback notice —
/// so a sink fail-open re-routes to behavior identical to a normal dictation.
///
/// It differs from the core `FocusedAppOutputTarget` in two app-specific ways that
/// keep the default/fallback path byte-for-byte like today's:
///   1. it inserts a PRE-COMPUTED string (the final text plus any trailing space),
///      not `payload.text`, because the trailing-space decision lives in `AppState`;
///   2. it surfaces the clipboard-fallback notice on `.copiedToClipboard`.
/// Both are AppKit/`AppState`-flavored concerns, so this adapter lives in the app
/// (not `OpenWhispCore`) and is verified by the build + the AppState routing path.
///
/// Like every focused-app target it always reports `.delivered` — the underlying
/// insertion seam (AX → paste → clipboard) never loses text, so from the router's
/// perspective the fallback always succeeds and there is no second recursion.
final class FocusedAppInsertTarget: OutputTarget {
    let kind: OutputTargetKind = .focusedApp

    private let insertion: String
    private let mode: InsertionMode
    private let restoreClipboard: Bool
    /// Injected insert closure: `AppState` supplies the real `textOutput.insert`
    /// wrapped so a `.copiedToClipboard` outcome shows the fallback notice, then
    /// calls the completion. Keeps this adapter free of a direct `AppState`/AppKit
    /// dependency.
    private let insert: (_ text: String, _ mode: InsertionMode, _ restoreClipboard: Bool, _ completion: @escaping () -> Void) -> Void

    init(
        insertion: String,
        mode: InsertionMode,
        restoreClipboard: Bool,
        insert: @escaping (_ text: String, _ mode: InsertionMode, _ restoreClipboard: Bool, _ completion: @escaping () -> Void) -> Void
    ) {
        self.insertion = insertion
        self.mode = mode
        self.restoreClipboard = restoreClipboard
        self.insert = insert
    }

    func deliver(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void) {
        insert(insertion, mode, restoreClipboard) {
            completion(.delivered)
        }
    }
}
