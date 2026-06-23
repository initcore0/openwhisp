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

    /// Insert `text` into the focused app. Fire-and-forget; runs off the main thread.
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool) {
        guard !text.isEmpty else { return }
        queue.async {
            switch mode {
            case .directAX:
                if !Self.insertViaAccessibility(text) {
                    // Even in AX-only mode, fall back rather than silently dropping text.
                    Self.pasteSynchronously(text, restoreClipboard: restoreClipboard)
                }
            case .paste:
                Self.pasteSynchronously(text, restoreClipboard: restoreClipboard)
            case .auto:
                if !Self.insertViaAccessibility(text) {
                    Self.pasteSynchronously(text, restoreClipboard: restoreClipboard)
                }
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

    /// Attempt to insert `text` at the caret of the focused element via AX.
    /// Returns false if AX isn't permitted or the element doesn't support it.
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
        return setErr == .success
    }

    // MARK: - Paste fallback

    /// Synchronous paste (already on `queue`): snapshot all clipboard item types,
    /// set our text, Cmd+V, restore.
    private static func pasteSynchronously(_ text: String, restoreClipboard: Bool) {
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

        Thread.sleep(forTimeInterval: 0.05)
        postCommandV()
        Thread.sleep(forTimeInterval: 0.15)

        if restoreClipboard, !savedItems.isEmpty {
            pb.clearContents()
            pb.writeObjects(savedItems)
        }
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
