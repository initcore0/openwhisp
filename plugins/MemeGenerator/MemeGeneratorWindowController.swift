import AppKit
import SwiftUI

/// The Meme Generator plugin's window (spike).
///
/// Deliberately thin, like `ScratchpadWindowController`: it owns the window's
/// lifecycle, the LLM wiring, and the dictation seam. All state lives in
/// `MemeGeneratorModel`; all rules live in OpenWhispCore (`MemeAI`,
/// `MemeTemplateMatcher`, `MemeCaptionLayout`) where `swift test` covers them.
///
/// A normal titled `NSWindow` rather than a floating panel: this is a workspace you
/// look at, not an always-on-top scratch surface. It still needs to become KEY so
/// dictation can land in it — that is what makes `appendDictationIfKey` fire.
@MainActor
final class MemeGeneratorWindowController: NSWindowController, NSWindowDelegate, PluginDictationSink {

    private let model = MemeGeneratorModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = PluginRegistry.memeGenerator.name
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenWhispMemeGeneratorWindow")
        window.center()

        self.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: MemeGeneratorView(model: model))
        window.delegate = self
        wireAI()
    }

    // MARK: - LLM seam

    /// Wire the plugin's Generate action to the app's configured LLM.
    ///
    /// The same bridge `ScratchpadWindowController.wireAI` uses: both closures are
    /// re-evaluated per call so a mid-session settings change lands, and the model
    /// never sees AppState. Reusing `summarizeResolved` means the plugin inherits its
    /// guarantees for free — busy-reject while dictating, bundled-engine bracketing,
    /// fail-closed on the agent-CLI provider, and exactly-once delivery.
    ///
    /// Note the plugin does NOT get its own model picker in this spike: it follows
    /// the Scratchpad's resolution (its override, else the cleanup settings). A real
    /// plugin config surface would put that on the plugin's own defaults keys.
    private func wireAI() {
        model.configureAI(
            call: { instruction, input, resolved in
                try await withCheckedThrowingContinuation { cont in
                    Task { @MainActor in
                        AppState.shared.summarizeResolved(
                            text: input, instruction: instruction, resolved: resolved
                        ) { result in
                            switch result {
                            case .success(let out): cont.resume(returning: out)
                            case .failure(let err): cont.resume(throwing: err)
                            }
                        }
                    }
                }
            },
            resolveModel: { ScratchpadWindowController.resolvedAIModel() })
    }

    // MARK: - PluginDictationSink

    /// True while this window is frontmost — the signal that a completed dictation
    /// belongs here rather than in the focused app.
    var isKeyWindow: Bool { window?.isKeyWindow ?? false }

    /// Append a completed dictation to the meme description IF this window is key.
    ///
    /// Returns whether it handled the text so AppState skips its focused-app insert.
    /// Without this the words would be lost: the focused-app paste path deliberately
    /// declines while OpenWhisp itself is frontmost.
    @discardableResult
    func appendDictationIfKey(_ text: String) -> Bool {
        guard isKeyWindow, !text.isEmpty else { return false }
        model.appendDictation(text)
        return true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // A closed window must never be mutated by a late generate result.
        model.cancel()
    }
}
