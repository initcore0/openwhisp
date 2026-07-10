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

    /// The user's clipboard snapshot awaiting a deferred restore, carried forward
    /// across consecutive paste chunks so live dictation restores the ORIGINAL
    /// clipboard, not an intermediate chunk. Only touched on `queue`.
    private var pendingRestoreItems: [NSPasteboardItem] = []
    /// `NSPasteboard.changeCount` right after our last paste write; lets a chunk
    /// recognize "the clipboard still holds our previous chunk" and keep the
    /// carried snapshot instead of re-snapshotting our own text. Only on `queue`.
    private var lastPasteWriteCount: Int = -1

    /// Insert `text` into the focused app. Runs off the main thread; `completion`
    /// (if given) reports on the main thread whether the insert was confirmed or fell
    /// back to leaving the text on the clipboard.
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool,
                completion: ((InsertionOutcome) -> Void)?) {
        guard !text.isEmpty else { return }
        queue.async { [self] in
            let outcome: InsertionOutcome
            switch mode {
            case .paste:
                outcome = pasteWithSafetyNet(text, restoreClipboard: restoreClipboard)
            case .appleScript:
                // Type via System Events keystroke — for apps that mangle ⌘V and
                // AX (Electron, VNC, non-QWERTY). Never touches the clipboard. Fall
                // back to paste (its own safety net) if the script can't run.
                if Self.insertViaAppleScript(text) {
                    outcome = .inserted
                } else {
                    outcome = pasteWithSafetyNet(text, restoreClipboard: restoreClipboard)
                }
            case .directAX, .auto:
                // Try verified AX first; fall back to paste (with its own safety net)
                // when AX is unsupported or its result can't be confirmed.
                if Self.insertViaAccessibility(text) {
                    outcome = .inserted
                } else {
                    outcome = pasteWithSafetyNet(text, restoreClipboard: restoreClipboard)
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

    /// Overlay "revert to original" (MAK-35): swap the text we just inserted for the
    /// raw pre-cleanup words, IN PLACE, without touching the clipboard. Runs off the
    /// main thread (FIFO behind any late chunk paste) and reports on the main thread
    /// whether the swap was actually performed. The whole operation is gated on the
    /// pure `ReplaceLastInsertion` decision: it only mutates the field when the focused
    /// element's readable value still ends with exactly our inserted text (so we never
    /// clobber the user's own edits). Any failure — no AX, no readable value, the field
    /// changed, the write not settable, or the read-back doesn't reflect the swap —
    /// reports `false`, and the caller keeps the raw words on the clipboard.
    func replaceLastInsertion(inserted: String, raw: String,
                              completion: @escaping (Bool) -> Void) {
        queue.async {
            let ok = Self.replaceViaAccessibility(inserted: inserted, raw: raw)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// The AX side of `replaceLastInsertion`. Reads the focused element's whole value,
    /// asks `ReplaceLastInsertion` for the safe new value, and writes it back over a
    /// full-field selection — verifying the read-back reflects the swap. Returns false
    /// on any precondition miss so the caller falls back to the clipboard copy.
    private static func replaceViaAccessibility(inserted: String, raw: String) -> Bool {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return false }

        // We rewrite the whole field, so both the value AND selected-text must be
        // settable (selecting the range then replacing the selection).
        guard isAttributeSettable(element, kAXValueAttribute),
              isAttributeSettable(element, kAXSelectedTextAttribute) else { return false }

        // Read the field's current value and let the pure decision return the exact
        // replacement — or nil if it's unsafe (field no longer ends with our text).
        let current = copyStringAttribute(element, kAXValueAttribute)
        guard let newValue = ReplaceLastInsertion.newValue(
            currentValue: current, inserted: inserted, raw: raw
        ) else { return false }

        // Select the entire field, then replace the selection with the new value —
        // the same "set selected text" primitive the insert path uses, applied to a
        // full-range selection so it swaps the whole value atomically.
        let length = (current as NSString?)?.length ?? 0
        var range = CFRange(location: 0, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }
        let selErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, rangeValue
        )
        guard selErr == .success else { return false }

        let setErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, newValue as CFString
        )
        guard setErr == .success else { return false }

        // Verify the swap took using the SAME normalized read-back the insert path uses
        // (InsertVerifier) rather than exact equality — so a field that re-renders the
        // value with smart quotes/dashes still verifies as success instead of nagging
        // the user to ⌘V-paste over an already-correct field. `before` is `current` (the
        // pre-swap value); a readable, changed value that now contains our new text (or
        // whose change we can't contradict) counts as done.
        let readBack = copyStringAttribute(element, kAXValueAttribute)
        switch InsertVerifier.axInsertReflected(expected: newValue, before: current, current: readBack) {
        case .some(false): return false   // contradicted → clipboard fallback
        default:           return true    // verified, or unverifiable (trust setErr)
        }
    }

    /// True when `attribute` is settable on `element` (AX success + settable flag).
    private static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// The system-wide focused UI element, or nil when AX can't resolve one. Shared by
    /// the AX insert and the AX in-place replace so the focus lookup lives in one place.
    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard err == .success, let focusedRef = focused else { return nil }
        // CFTypeRef from AX is an AXUIElement; the cast is safe here.
        return (focusedRef as! AXUIElement)
    }

    // MARK: - Accessibility insertion

    /// Attempt to insert `text` at the caret of the focused element via AX, and
    /// VERIFY it took where the element exposes a readable value. Returns false if
    /// AX is unpermitted, unsupported, or the set succeeded by status but the
    /// re-read value contradicts it (the "AX silently lied" case in some Electron /
    /// web views) — so the caller falls back to paste rather than dropping text.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return false }

        // The element must expose a settable selected-text attribute for this to
        // work as an "insert at caret / replace selection" operation.
        guard isAttributeSettable(element, kAXSelectedTextAttribute) else { return false }

        // Snapshot the element's value BEFORE the set so verification can tell
        // "the set changed the field" apart from "our text was already there"
        // (see InsertVerifier.axInsertReflected).
        let before = copyStringAttribute(element, kAXValueAttribute)

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
        // and compare against the pre-set snapshot. If the value is readable but
        // unchanged and doesn't reflect the insert, AX lied → report failure so we
        // fall back to paste. If it can't be decided, trust the status code.
        let readBack = copyStringAttribute(element, kAXValueAttribute)
        switch InsertVerifier.axInsertReflected(expected: text, before: before, current: readBack) {
        case .some(false): return false   // contradicted → fall back
        default:           return true    // verified, or unverifiable (trust setErr)
        }
    }

    // MARK: - AppleScript keystroke insertion

    /// Type `text` into the frontmost app via AppleScript / System Events
    /// `keystroke` (MAK-42). The transcript is embedded ONLY as the safely-escaped
    /// AppleScript string literal built by `AppleScriptInsert` (never interpolated
    /// into script source unescaped), so quotes / backslashes / newlines in the
    /// transcript can't break or inject script. Returns false when the script
    /// couldn't run (no Accessibility/Automation permission, compile/exec error) so
    /// the caller falls back to paste rather than dropping text.
    ///
    /// Two guards:
    /// - Over-long transcripts (`AppleScriptInsert.maxKeystrokeLength`) are refused
    ///   up-front — `keystroke` types synchronously at keyboard speed with no way
    ///   to interrupt, so an unbounded transcript would "type" for a very long
    ///   time. The false return routes them to the instant paste fallback.
    /// - `NSAppleScript` is documented main-thread-only; this is called on the
    ///   serial insert queue, so hop to the main thread for the execution. Safe:
    ///   nothing ever blocks the main thread on the insert queue, and the length
    ///   cap bounds how long the main thread is held.
    private static func insertViaAppleScript(_ text: String) -> Bool {
        guard AppleScriptInsert.isKeystrokeSized(text) else { return false }
        let source = AppleScriptInsert.keystrokeScript(for: text)
        var succeeded = false
        let execute = {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            succeeded = (error == nil)
        }
        if Thread.isMainThread { execute() } else { DispatchQueue.main.sync(execute: execute) }
        return succeeded
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
    /// write failed, ⌘V couldn't be synthesized, or no other app is frontmost to
    /// paste into), we DON'T restore the clipboard and report `.copiedToClipboard`
    /// so the text is never lost and the user can paste it manually.
    private func pasteWithSafetyNet(_ text: String, restoreClipboard: Bool) -> InsertionOutcome {
        let pb = NSPasteboard.general

        if restoreClipboard {
            // Snapshot the current clipboard for the deferred restore — unless it
            // still holds OUR previous chunk (changeCount unchanged since our last
            // write), in which case keep carrying the user's original snapshot.
            if pb.changeCount != lastPasteWriteCount {
                var savedItems: [NSPasteboardItem] = []
                for item in pb.pasteboardItems ?? [] {
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
                pendingRestoreItems = savedItems
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
        lastPasteWriteCount = pb.changeCount

        // Is there a foreground app (other than us) that can receive the paste? The
        // overlay is a non-activating panel, so the target app should stay frontmost.
        // If not, leave the text on the clipboard rather than firing ⌘V into nothing.
        guard Self.hasPasteTarget() else {
            return .copiedToClipboard
        }

        Thread.sleep(forTimeInterval: 0.05)
        guard Self.postCommandV() else {
            // ⌘V couldn't be synthesized — no paste happened. Leave our text on the
            // clipboard (no restore) and report it so the user can paste manually.
            return .copiedToClipboard
        }
        Thread.sleep(forTimeInterval: 0.15)

        if restoreClipboard, !pendingRestoreItems.isEmpty {
            // The target app services the synthesized ⌘V asynchronously; a busy app
            // can read the pasteboard well after 150ms, and restoring here would
            // make it paste the OLD clipboard. Defer the restore on the same serial
            // queue, and skip it if anything (a user copy, a later chunk, or
            // setClipboard) has rewritten the pasteboard since — the later writer
            // owns the clipboard then. Bind the guard to OUR verified write
            // (recorded before the sleeps), not the current count: a foreign
            // write during the sleeps must veto the restore, not be clobbered.
            let expectedChangeCount = lastPasteWriteCount
            queue.asyncAfter(deadline: .now() + 1.0) { [self] in
                let pb = NSPasteboard.general
                guard pb.changeCount == expectedChangeCount else { return }
                let items = pendingRestoreItems
                guard !items.isEmpty else { return }
                pendingRestoreItems = []
                pb.clearContents()
                pb.writeObjects(items)
            }
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

    /// Returns false when the ⌘V events couldn't even be created — the caller must
    /// NOT assume a paste happened (and must not restore the clipboard over the
    /// text it just set).
    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }
        let tap: CGEventTapLocation = .cghidEventTap
        vDown.flags = .maskCommand
        vDown.post(tap: tap)
        Thread.sleep(forTimeInterval: 0.08)
        vUp.flags = .maskCommand
        vUp.post(tap: tap)
        return true
    }
}
