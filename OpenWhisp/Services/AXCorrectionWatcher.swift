import Cocoa
import ApplicationServices

/// macOS side of the self-learning dictionary's capture step (MAK-41 Part C).
///
/// After OpenWhisp inserts a FINAL dictation via the Accessibility path, this
/// watcher snapshots the focused field's whole value, then re-reads it once after a
/// short debounce to see whether the user typed over a single word. If the same
/// element still holds focus and the change is a clean single-token edit, it hands
/// the (inserted, surviving) pair to `EditDiff` → the caller's `onCorrection`.
///
/// # What is and isn't reliable here (read before trusting this)
///
/// This is a best-effort, HONESTLY-SCOPED capture, gated hard so a wrong signal
/// can't reach the dictionary:
///
///  - **AX-path inserts only.** `arm(...)` is called only when the final text went
///    in via `kAXSelectedText` (not the paste fallback), because only then can we
///    read the field value back. Paste-path dictations are never watched.
///  - **Same element, still focused.** The delayed re-read is discarded unless the
///    system-wide focused element is byte-for-byte the one we armed on (CFEqual).
///    Focus moved on, window closed, app switched → no capture.
///  - **Single delayed re-read, not a live AXObserver.** A full
///    `kAXValueChangedNotification` observer is fragile and app-dependent (many
///    apps — Electron/web views especially — never emit it, and the observer's
///    threading/lifetime is a footgun). A single debounced re-read of
///    `kAXValueAttribute` is the reliable subset, so that's what ships.
///  - **The learner is the final gate.** Even a captured pair only becomes a
///    *proposal* the user must accept; `CorrectionLearner.proposeSubstitution` and
///    `CorrectionProposalState` reject anything that isn't an unambiguous one-word
///    correction, and nothing is ever applied to the dictionary silently.
///
/// # Known limits (deferred, documented)
///
///  - If the user keeps DICTATING after the final (so the field grows by whole
///    sentences), `EditDiff` returns nil — we only learn from a localized one-word
///    fix, not from continued dictation.
///  - Apps that don't expose a readable `kAXValueAttribute` (some web/Electron
///    fields) yield no snapshot, so nothing is captured there.
///  - Only ONE deferred re-read per insert: if the user corrects the word AFTER the
///    debounce window, this pass misses it. The window is a deliberate
///    reliability/latency trade, not a claim of continuous observation.
final class AXCorrectionWatcher {

    /// How long to wait after the insert before re-reading the field. Long enough
    /// for a quick "type over the wrong word" correction, short enough to still be
    /// looking at the same element/focus.
    private let reReadDelay: TimeInterval

    /// The armed capture, if any. Retained only between `arm` and the delayed
    /// re-read; cleared after. Access on the main queue only.
    private var pending: Armed?

    /// Monotonic token so a newer `arm` (or a `cancel`) invalidates an older
    /// scheduled re-read that hasn't fired yet.
    private var generation: Int = 0

    private struct Armed {
        let element: AXUIElement
        let afterInsertValue: String
        let insertedText: String
        let generation: Int
    }

    init(reReadDelay: TimeInterval = 2.5) {
        self.reReadDelay = reReadDelay
    }

    /// Arm a capture after an AX-path insert. `insertedText` is what we just wrote.
    /// Reads the current focused element + value NOW, schedules one re-read after
    /// the debounce, and on a clean single-token edit calls `onCorrection` on the
    /// main queue with the pair. No-op (nothing armed) if AX can't read the field.
    ///
    /// - Note: Call on the main queue. Only call for `directAX`/`auto` inserts that
    ///   actually took via AX — never for the paste fallback.
    func arm(insertedText: String, onCorrection: @escaping (_ inserted: String, _ surviving: String) -> Void) {
        guard AXIsProcessTrusted() else { return }
        guard let (element, value) = Self.focusedElementAndValue() else { return }

        generation &+= 1
        let gen = generation
        pending = Armed(element: element, afterInsertValue: value, insertedText: insertedText, generation: gen)

        DispatchQueue.main.asyncAfter(deadline: .now() + reReadDelay) { [weak self] in
            self?.fire(expectedGeneration: gen, onCorrection: onCorrection)
        }
    }

    /// Cancel any armed capture (e.g. a new dictation started). Invalidates the
    /// pending re-read via the generation token.
    func cancel() {
        generation &+= 1
        pending = nil
    }

    // MARK: - Deferred re-read

    private func fire(expectedGeneration: Int,
                      onCorrection: @escaping (_ inserted: String, _ surviving: String) -> Void) {
        guard let armed = pending, armed.generation == expectedGeneration else { return }
        pending = nil   // one-shot

        // The SAME element must still be focused. If focus moved (or we can't read
        // focus), we can't attribute any change to our insert → drop it.
        guard let (focusedNow, currentValue) = Self.focusedElementAndValue(),
              CFEqual(focusedNow, armed.element) else { return }

        // Nothing changed → nothing to learn.
        guard currentValue != armed.afterInsertValue else { return }

        // Localized single-word edit? EditDiff + the learner are the gate.
        guard let pair = EditDiff.singleTokenCorrection(
            afterInsert: armed.afterInsertValue,
            later: currentValue
        ) else { return }

        onCorrection(pair.inserted, pair.surviving)
    }

    // MARK: - AX plumbing

    /// The system-wide focused element and its readable string value, or nil when
    /// there's no focus / no readable value (fail-quiet: capture just doesn't arm).
    private static func focusedElementAndValue() -> (AXUIElement, String)? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusErr == .success, let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        var valueRef: CFTypeRef?
        let valErr = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        )
        guard valErr == .success, let value = valueRef as? String else { return nil }
        return (element, value)
    }
}
