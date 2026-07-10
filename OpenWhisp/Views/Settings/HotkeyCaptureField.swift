import SwiftUI
import AppKit

/// Record-a-shortcut capture control for the dictation trigger (MAK-17). Mirrors
/// the "click to record, press a combo" fields in macOS System Settings.
///
/// While recording it installs a LOCAL NSEvent monitor (Settings has key focus,
/// so local is enough — no global input-monitoring needed just to capture) and
/// resolves the pressed combo into a `DictationTrigger`:
///   • a non-modifier key + any held modifiers → a chord (e.g. ⌥⌘R)
///   • a lone modifier released with nothing else → a bare-modifier trigger (⌥)
///
/// The pure formatting/conflict logic lives in `DictationTrigger`; this view only
/// captures and reports the combo back through `onCapture`.
struct HotkeyCaptureField: View {
    /// Current trigger to display when not recording.
    let current: DictationTrigger
    /// Whether the custom trigger is the active one (drives the highlight).
    let isActive: Bool
    /// Called with the captured binding when the user completes a recording.
    let onCapture: (_ keyCode: Int64?, _ modifiers: TriggerModifiers) -> Void
    /// Recording started/stopped — the owner uses this to suspend the global
    /// hotkey monitor, so pressing the CURRENT trigger while recording a new one
    /// can't start dictation (and Esc-cancelling the recording can't fire the
    /// session cancel).
    var onRecordingChanged: ((Bool) -> Void)? = nil

    @State private var recording = false
    @State private var monitor: Any?
    /// Modifiers seen during the current recording, so a lone modifier released
    /// with no primary key becomes a bare-modifier binding.
    @State private var pendingModifiers: TriggerModifiers = []

    var body: some View {
        HStack {
            Text(recording ? "Press a key or combo…" : current.displayName)
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .frame(minWidth: 140, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(recording ? Color.accentColor
                                : (isActive ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.3)),
                                lineWidth: recording ? 2 : 1)
                )

            Button(recording ? "Stop" : "Record shortcut") {
                recording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        pendingModifiers = []
        recording = true
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil // swallow while recording so we don't type into the field
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { onRecordingChanged?(false) }
        recording = false
        pendingModifiers = []
    }

    private func handle(_ event: NSEvent) {
        var mods = Self.modifiers(from: event.modifierFlags)

        if event.type == .keyDown {
            let keyCode = Int64(event.keyCode)
            // Esc (however modified) cancels the recording without changing
            // anything — an Esc-keyed trigger can't work anyway (Esc is the
            // session cancel key; DictationTrigger rejects it as `.escapeKey`).
            if keyCode == DictationTrigger.escapeKeyCode {
                stopRecording()
                return
            }
            // Arrows/F-row/nav keys set the Fn flag implicitly on macOS — strip
            // it for those keys so recording ⌘← isn't stored (and displayed)
            // as Fn+⌘←.
            if DictationTrigger.impliesFnFlag(keyCode) {
                mods.remove(.function)
            }
            onCapture(keyCode, mods)
            stopRecording()
            return
        }

        // flagsChanged: accumulate held modifiers. When they all release again
        // (down to empty) with no key pressed, commit the last chord as a
        // bare-modifier trigger.
        if !mods.isEmpty {
            pendingModifiers.formUnion(mods)
        } else if !pendingModifiers.isEmpty {
            onCapture(nil, pendingModifiers)
            stopRecording()
        }
    }

    /// Map an NSEvent modifier mask to the side-agnostic TriggerModifiers set.
    static func modifiers(from flags: NSEvent.ModifierFlags) -> TriggerModifiers {
        var mods: TriggerModifiers = []
        if flags.contains(.control)  { mods.insert(.control) }
        if flags.contains(.option)   { mods.insert(.option) }
        if flags.contains(.shift)    { mods.insert(.shift) }
        if flags.contains(.command)  { mods.insert(.command) }
        if flags.contains(.function) { mods.insert(.function) }
        return mods
    }
}
