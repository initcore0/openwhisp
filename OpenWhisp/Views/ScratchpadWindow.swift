import AppKit
import SwiftUI

/// The floating Scratchpad panel (MAK-49, rebuilt in MAK-95): an always-on-top,
/// ACTIVATING `NSPanel` hosting the SwiftUI `ScratchpadView` — a target-free
/// surface to dictate into when no other app has focus.
///
/// Why an *activating* titled panel (not the `.nonactivatingPanel` the dictation
/// overlay uses): the pad is a thing you TYPE and DICTATE into, so it must be able
/// to become key and give its editor first-responder. When it's frontmost,
/// `AppState.insertCompletedText` appends the dictation straight into the active
/// note (see `appendDictationIfKey`) rather than through the focused-app insert
/// path — whose paste fallback deliberately declines when our own app is frontmost.
///
/// **This controller is deliberately thin.** It owns only the panel's lifecycle and
/// the AppState-facing seam (`isKeyWindow`, `appendDictationIfKey`,
/// `openMeetingNote`, `showAndFocus`). All state lives in `ScratchpadModel`; all
/// rules live in OpenWhispCore (`ScratchpadText`, `ScratchpadPersistencePolicy`,
/// `MarkdownPreviewRenderer`, `ScratchpadExport`, `ScratchpadFilter`,
/// `ScratchpadTags`) where `swift test` covers them.
@MainActor
final class ScratchpadWindowController: NSObject, NSWindowDelegate {

    /// The observable model behind the SwiftUI content — notes, selection, editor
    /// text, debounced persistence.
    let model = ScratchpadModel()

    private var panel: NSPanel?

    override init() {
        super.init()
    }

    // MARK: - Show / focus

    /// Open the pad, bring it to front, and make the editor first responder so the
    /// very next dictation (or keystroke) lands in the active note. Idempotent.
    func showAndFocus() {
        model.loadIfNeeded()
        let panel = panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusEditor(in: panel)
    }

    /// True while the pad is the frontmost key window — the signal AppState uses to
    /// route a completed dictation here instead of the focused app.
    var isKeyWindow: Bool { panel?.isKeyWindow ?? false }

    /// Append a completed dictation to the active note IF the pad is the key window.
    /// Returns whether it handled the text (so AppState skips its focused-app
    /// insert). Creates a first note on demand so a dictation is never dropped.
    /// Always lands the text — the pad is a local model, so there is no fail path.
    @discardableResult
    func appendDictationIfKey(_ text: String) -> Bool {
        guard isKeyWindow, !text.isEmpty else { return false }
        return model.appendDictation(text) != nil
    }

    /// Open a meeting's transcript + summary as a NEW editable note and focus it
    /// (MAK-50 "Open in Scratchpad"). The body comes from the pure, unit-tested
    /// `MeetingScratchpadExport`; this is only the persist + show shell.
    ///
    /// Ordering matters: the note is inserted and persisted BEFORE the panel is
    /// shown, so a first open selects the meeting note rather than a stale one.
    func openMeetingNote(_ meeting: Meeting) {
        model.loadIfNeeded()
        model.insertMeetingNote(meeting)
        showAndFocus()
    }

    /// Open a completed file transcription as a NEW editable note and focus it
    /// (MAK-98 "Open in Scratchpad" for transcribed audio/video files). The body
    /// comes from the pure, unit-tested `FileTranscriptScratchpadExport`; this is
    /// only the persist + show shell, and the same insert-before-show ordering the
    /// meeting path uses applies.
    ///
    /// Takes primitives rather than the queue job so this seam has no dependency on
    /// the file-transcription types.
    func openFileTranscript(
        fileName: String, date: Date, duration: TimeInterval, transcript: String
    ) {
        model.loadIfNeeded()
        model.insertFileTranscriptNote(
            fileName: fileName, date: date, duration: duration, transcript: transcript)
        showAndFocus()
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scratchpad"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 460, height: 260)
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: ScratchpadView(model: model))
        // Remember size/position across relaunches. Restore an existing saved
        // frame first; only center at the 640x420 default when there is none
        // (first run), so the autosave never fights the initial layout.
        let autosaveName = "OpenWhispScratchpadPanel"
        if !panel.setFrameUsingName(autosaveName) {
            panel.center()
        }
        panel.setFrameAutosaveName(autosaveName)
        return panel
    }

    /// Give the note editor first responder, so a keystroke or dictation lands in
    /// the text rather than the search field. The hosting view builds asynchronously
    /// on first open, so this retries once on the next runloop turn.
    private func focusEditor(in panel: NSPanel) {
        if let editor = Self.firstTextView(in: panel.contentView) {
            panel.makeFirstResponder(editor)
            return
        }
        DispatchQueue.main.async { [weak panel] in
            guard let panel, let editor = Self.firstTextView(in: panel.contentView) else { return }
            panel.makeFirstResponder(editor)
        }
    }

    /// Depth-first search for the editor's `NSTextView` inside the hosting view.
    /// The search field is an `NSTextField`, so the first `NSTextView` found is the
    /// note editor (the preview renders `Text`, which is not a text view).
    private static func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Flush the debounced write: any edit still inside the coalescing window
        // must hit disk now. The model stays in memory so re-opening is instant.
        model.flush()
    }
}
