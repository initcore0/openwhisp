import Cocoa
import ApplicationServices

/// macOS `TextOutput`: inserts dictated text into the focused app.
///
/// Two strategies:
///   - **Accessibility (AX) direct insert** — writes text at the caret / over the
///     selection of the focused UI element via the Accessibility API. Touches the
///     clipboard NOT AT ALL, so the user's copied content is preserved. Works in
///     most native (and many Electron) text fields; some apps don't expose a
///     settable selected-text attribute.
///   - **Paste (Cmd+V)** — the universal fallback. Sets the clipboard, posts
///     Cmd+V, and (optionally) restores the previous clipboard.
///
/// `insert(...)` picks per the `mode`: `.directAX` only, `.paste` only, or
/// `.auto` (try AX, fall back to paste). All work is serialized on one queue so
/// rapid live-chunk insertions stay in order.
///
/// The Apple-only AppKit/Accessibility/CoreGraphics calls are isolated here;
/// AppState depends on the `TextOutput` protocol, not this type. `InsertionMode`
/// lives in OpenWhispCore.
final class TextInserter: TextOutput {

    /// Serial queue shared with clipboard writes so insertions and clipboard
    /// sets stay strictly FIFO-ordered (prevents the paste/clobber races).
    private let queue = DispatchQueue(label: "com.openwhisp.app.insert")

    /// Insert `text` into the focused app. Runs off the main thread; `completion`
    /// (if given) reports on the main thread whether the insert was confirmed or fell
    /// back to leaving the text on the clipboard.
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool,
                completion: ((InsertionOutcome) -> Void)?) {
        guard !text.isEmpty else { return }
        queue.async {
            let outcome: InsertionOutcome
            switch mode {
            case .paste:
                outcome = Self.pasteWithSafetyNet(text, restoreClipboard: restoreClipboard)
            case .directAX, .auto:
                // Try verified AX first; fall back to paste (with its own safety net)
                // when AX is unsupported or its result can't be confirmed.
                if Self.insertViaAccessibility(text) {
                    outcome = .inserted
                } else {
                    outcome = Self.pasteWithSafetyNet(text, restoreClipboard: restoreClipboard)
                }
            }
            if let completion {
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    /// Set the clipboard, FIFO-ordered behind any in-flight insertions.
    func setClipboard(_ text: String) {
        queue.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    // MARK: - Accessibility insertion

    /// Attempt to insert `text` at the caret of the focused element via AX, and
    /// VERIFY it took where the element exposes a readable value. Returns false if
    /// AX is unpermitted, unsupported, or the set succeeded by status but the
    /// re-read value contradicts it (the "AX silently lied" case in some Electron /
    /// web views) — so the caller falls back to paste rather than dropping text.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusErr == .success, let focusedRef = focused else { return false }
        // CFTypeRef from AX is an AXUIElement; the cast is safe here.
        let element = focusedRef as! AXUIElement

        // The element must expose a settable selected-text attribute for this to
        // work as an "insert at caret / replace selection" operation.
        var settable: DarwinBoolean = false
        let settableErr = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableErr == .success, settable.boolValue else { return false }

        // Setting selected text replaces the current selection with `text`; with
        // an empty selection it inserts at the caret. This is exactly the paste
        // semantics, minus the clipboard.
        let setErr = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard setErr == .success else { return false }

        // Best-effort verification: re-read the element's whole value (if exposed)
        // and confirm our text is present. If the value is readable but doesn't
        // reflect the insert, AX lied → report failure so we fall back to paste.
        // If the value isn't readable, we can't verify → trust the status code.
        let readBack = copyStringAttribute(element, kAXValueAttribute)
        switch InsertVerifier.axInsertReflected(expected: text, current: readBack) {
        case .some(false): return false   // contradicted → fall back
        default:           return true    // verified, or unverifiable (trust setErr)
        }
    }

    // MARK: - AX read helper

    /// Copy a string-valued AX attribute, nil on any error or non-string value.
    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        return value as? String
    }

    // MARK: - Paste fallback (with safety net)

    /// Synchronous paste (already on `queue`) with verification: snapshot the
    /// clipboard, set our text and CONFIRM the write, then — only if a focused app
    /// can receive ⌘V — synthesize it. If preconditions can't be met (clipboard
    /// write failed, or no other app is frontmost to paste into), we DON'T restore
    /// the clipboard and report `.copiedToClipboard` so the text is never lost and
    /// the user can paste it manually.
    private static func pasteWithSafetyNet(_ text: String, restoreClipboard: Bool) -> InsertionOutcome {
        let pb = NSPasteboard.general

        var savedItems: [NSPasteboardItem] = []
        if restoreClipboard, let existing = pb.pasteboardItems {
            for item in existing {
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                if !copy.types.isEmpty {
                    savedItems.append(copy)
                }
            }
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Confirm our text actually made it onto the clipboard before we rely on ⌘V.
        guard pb.string(forType: .string) == text else {
            // Couldn't even write the clipboard — nothing more we can do; report so
            // the UI can tell the user. (Don't restore: our text is the best we have.)
            return .copiedToClipboard
        }

        // Is there a foreground app (other than us) that can receive the paste? The
        // overlay is a non-activating panel, so the target app should stay frontmost.
        // If not, leave the text on the clipboard rather than firing ⌘V into nothing.
        guard Self.hasPasteTarget() else {
            return .copiedToClipboard
        }

        Thread.sleep(forTimeInterval: 0.05)
        postCommandV()
        Thread.sleep(forTimeInterval: 0.15)

        if restoreClipboard, !savedItems.isEmpty {
            pb.clearContents()
            pb.writeObjects(savedItems)
        }
        return .inserted
    }

    /// True if some application other than OpenWhisp is frontmost (i.e. there's a
    /// real target for the synthesized ⌘V). Conservatively returns true if we can't
    /// determine frontmost, so we never block a paste that would have worked.
    private static func hasPasteTarget() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return true }
        return front.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let tap: CGEventTapLocation = .cghidEventTap
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: tap)
        }
        Thread.sleep(forTimeInterval: 0.08)
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: tap)
        }
    }
}
