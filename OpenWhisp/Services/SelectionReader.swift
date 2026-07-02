import Cocoa
import ApplicationServices

/// Reads the user's currently-selected text from the focused app, for the
/// "refine my selection" flow (double-tap with no dictation → transform the
/// highlighted text via the LLM).
///
/// Two strategies, tried in order:
///   1. **Accessibility (AX)** — read `kAXSelectedTextAttribute` on the focused
///      element. Touches the clipboard NOT AT ALL. Works in most native/Electron
///      text views; some apps don't expose it.
///   2. **Clipboard (⌘C) fallback** — snapshot the clipboard, synthesize ⌘C, read
///      the copied text, then RESTORE the previous clipboard. Universal, and it
///      leaves the selection intact so the refined result can replace it in place.
///
/// The Apple-only AX/AppKit/CoreGraphics calls are isolated here. Returns nil when
/// nothing is selected or selection can't be read (caller treats that as "no
/// selection").
enum SelectionReader {

    /// Returns the focused app's selected text, or nil if there is none / it can't
    /// be read. `allowClipboardFallback` gates the ⌘C path (which briefly uses the
    /// clipboard); the previous clipboard is always restored.
    static func readSelectedText(allowClipboardFallback: Bool = true) -> String? {
        if let viaAX = readViaAccessibility(), !viaAX.isEmpty {
            return viaAX
        }
        guard allowClipboardFallback else { return nil }
        return readViaClipboard()
    }

    // MARK: - Accessibility

    private static func readViaAccessibility() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusErr == .success, let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        )
        guard err == .success, let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Clipboard (⌘C) fallback

    private static func readViaClipboard() -> String? {
        let pb = NSPasteboard.general

        // Snapshot the current clipboard so we can restore it afterward.
        var savedItems: [NSPasteboardItem] = []
        if let existing = pb.pasteboardItems {
            for item in existing {
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                if !copy.types.isEmpty { savedItems.append(copy) }
            }
        }

        // Mark the pasteboard, synthesize ⌘C, then detect whether it changed. The
        // marker count is taken AFTER clearContents (which itself bumps changeCount)
        // so only the target app's copy registers as a change.
        pb.clearContents()
        let beforeCount = pb.changeCount
        postCommandC()

        // Wait for the target app to service the copy, polling so a fast copy
        // returns early. This blocks the calling thread (the refine tap arrives on
        // the main actor), so the 150ms worst-case is only paid when the app never
        // copies (e.g. nothing selected).
        let deadline = Date().addingTimeInterval(0.15)
        while pb.changeCount == beforeCount, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Read whatever the copy produced (nil if the app didn't copy anything).
        let copied = pb.changeCount != beforeCount
            ? pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        // Restore the user's previous clipboard.
        pb.clearContents()
        if !savedItems.isEmpty { pb.writeObjects(savedItems) }

        guard let copied, !copied.isEmpty else { return nil }
        return copied
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let tap: CGEventTapLocation = .cghidEventTap
        // 0x08 = 'C'.
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: tap)
        }
        Thread.sleep(forTimeInterval: 0.08)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: tap)
        }
    }
}
