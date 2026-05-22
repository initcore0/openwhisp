import Cocoa
import CoreGraphics

/// Types text into the active application by pasting from clipboard.
/// Uses CGEvent to simulate Cmd+V.
class KeyboardSynthesizer {
    
    /// Type text into the active app.
    static func typeViaPaste(_ text: String) {
        print("[KS] typing: \"\(text)\"")
        
        let pb = NSPasteboard.general
        
        // Save current clipboard
        var savedText: String?
        if let existing = pb.string(forType: .string) {
            savedText = existing
        }
        
        // Set our text
        pb.clearContents()
        pb.setString(text, forType: .string)
        
        // Small delay to ensure clipboard is flushed
        Thread.sleep(forTimeInterval: 0.05)
        
        // Approach 1: CGEvent at session level
        pasteViaCGEvent()
        
        // Brief pause after paste
        Thread.sleep(forTimeInterval: 0.15)
        
        // Restore clipboard
        if let saved = savedText {
            pb.clearContents()
            pb.setString(saved, forType: .string)
        } else {
            pb.clearContents()
        }
        
        print("[KS] done")
    }
    
    private static func pasteViaCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)!
        
        // Post at session event tap for cross-app delivery
        let tap: CGEventTapLocation = .cghidEventTap
        
        // V key down (0x09) with Cmd
        if var vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: tap)
            print("[KS] posted V-down to \(tap)")
        } else {
            print("[KS] failed to create V-down event")
        }
        
        Thread.sleep(forTimeInterval: 0.08)
        
        // V key up with Cmd
        if var vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: tap)
            print("[KS] posted V-up to \(tap)")
        }
    }
}
