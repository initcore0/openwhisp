import Cocoa
import CoreGraphics

/// Types text into the active application by pasting from clipboard.
/// Uses CGEvent to simulate Cmd+V.
class KeyboardSynthesizer {

    /// Dedicated serial queue for clipboard + paste work.
    /// Serial guarantees FIFO ordering so rapid (live-chunk / streaming) insertions
    /// paste in the same order they were requested. Doing the blocking
    /// Thread.sleep work here keeps the @MainActor from being parked.
    private static let pasteQueue = DispatchQueue(label: "com.encryptedcat.voicenote.paste")

    /// Type text into the active app.
    ///
    /// Callable synchronously (fire-and-forget); the actual clipboard manipulation,
    /// CGEvent posting, and timing sleeps run off the main thread on `pasteQueue`.
    static func typeViaPaste(
        _ text: String,
        restoreClipboard: Bool = false,
        targetApplication: NSRunningApplication? = nil
    ) {
        pasteQueue.async {
            print("[KS] typing (len=\(text.count))")

            let pb = NSPasteboard.general

            // Reading the clipboard can trigger privacy prompts on newer macOS versions,
            // so it is only done when the user explicitly enables restore behavior.
            //
            // Snapshot ALL pasteboard items (not just .string) so non-string content
            // (images, files, RTF, PDF, ...) survives the round-trip. The data must be
            // copied into detached NSPasteboardItem objects BEFORE we clearContents(),
            // because clearContents invalidates the existing items.
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

            // Set our text
            pb.clearContents()
            pb.setString(text, forType: .string)

            // Small delay to ensure clipboard is flushed
            Thread.sleep(forTimeInterval: 0.05)

            pasteViaCGEvent()

            // Brief pause after paste
            Thread.sleep(forTimeInterval: 0.15)

            if restoreClipboard {
                // Only restore (and wipe) if we actually captured something; otherwise
                // leave whatever is on the clipboard rather than destroying it.
                if !savedItems.isEmpty {
                    pb.clearContents()
                    pb.writeObjects(savedItems)
                }
            }

            print("[KS] done")
        }
    }

    /// Set the clipboard to `text` on the same serial queue used for pasting.
    /// Use this for any clipboard write that must stay ordered behind in-flight
    /// pastes (e.g. the final liveChunks clipboard set), so it never races a
    /// still-draining chunk paste and clobber/re-paste hazards are avoided.
    static func setClipboard(_ text: String) {
        pasteQueue.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    private static func pasteViaCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)!

        let tap: CGEventTapLocation = .cghidEventTap

        // V key down (0x09) with Cmd
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: tap)
            print("[KS] posted V-down to \(tap)")
        } else {
            print("[KS] failed to create V-down event")
        }

        Thread.sleep(forTimeInterval: 0.08)

        // V key up with Cmd
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: tap)
            print("[KS] posted V-up to \(tap)")
        }
    }
}
