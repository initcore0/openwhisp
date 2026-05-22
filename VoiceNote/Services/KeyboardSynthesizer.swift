import Cocoa
import CoreGraphics

/// Types text into the active application by pasting from clipboard.
/// Uses CGEvent to simulate Cmd+V.
class KeyboardSynthesizer {
    
    /// Type text into the active app.
    static func typeViaPaste(
        _ text: String,
        restoreClipboard: Bool = false,
        targetApplication: NSRunningApplication? = nil
    ) {
        print("[KS] typing: \"\(text)\"")
        
        let pb = NSPasteboard.general
        
        // Reading the clipboard can trigger privacy prompts on newer macOS versions,
        // so it is only done when the user explicitly enables restore behavior.
        var savedText: String?
        if restoreClipboard, let existing = pb.string(forType: .string) {
            savedText = existing
        }
        
        // Set our text
        pb.clearContents()
        pb.setString(text, forType: .string)
        
        if let targetApplication, !targetApplication.isTerminated {
            targetApplication.activate(options: [.activateIgnoringOtherApps])
        }
        
        // Small delay to ensure clipboard is flushed
        Thread.sleep(forTimeInterval: 0.15)
        
        // Approach 1: CGEvent at session level
        pasteViaCGEvent()
        
        // Brief pause after paste
        Thread.sleep(forTimeInterval: 0.15)
        
        if restoreClipboard {
            if let saved = savedText {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            } else {
                pb.clearContents()
            }
        }
        
        print("[KS] done")
    }
    
    private static func pasteViaCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)!
        
        let tap: CGEventTapLocation = .cgSessionEventTap
        
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
