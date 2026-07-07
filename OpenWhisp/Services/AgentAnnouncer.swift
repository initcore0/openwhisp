import AppKit
import AVFoundation

/// Audible "an agent needs you" cues for agent-initiated dictation: a one-time
/// chime and an optional spoken reading of the agent's question. Both are
/// on-device (NSSound / AVSpeechSynthesizer) — nothing leaves the Mac — and both
/// are opt-out settings. Only ever used for agent sessions; a user's own hotkey
/// dictation stays silent.
///
/// The spoken question drives a completion callback (`speak(_:onFinish:)`) so the
/// caller can hold off opening the mic until speech ends — otherwise the mic
/// captures the app's own TTS and returns it to the agent as the human's answer
/// (an acoustic feedback loop).
@MainActor
final class AgentAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    /// Held for the synthesizer's lifetime so speech isn't cut off by ARC. A new
    /// utterance stops any in-flight one (a fresh question supersedes the old).
    private let synth = AVSpeechSynthesizer()

    /// Fired exactly once when the current utterance finishes OR is cancelled.
    /// Cleared as it fires so a later stray delegate callback can't re-invoke it.
    private var onSpeechEnd: (() -> Void)?
    /// Identity of the utterance whose completion `onSpeechEnd` is waiting on.
    /// `speak()` cancels any in-flight utterance, which delivers a `didCancel` for
    /// the OLD one — this token lets us ignore that stale callback and only honor
    /// the completion of the utterance the current caller actually scheduled.
    private var pendingUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Play the attention chime. Uses a stock macOS system sound (always present,
    /// no bundled asset). Fire-and-forget; a missing sound simply no-ops.
    func chime() {
        // "Submarine" is a soft, distinct ping — attention without alarm. Falls
        // back to the default beep if the named sound is ever unavailable.
        (NSSound(named: "Submarine") ?? NSSound(named: NSSound.Name("Ping")))?.play()
    }

    /// Speak the agent's question aloud, invoking `onFinish` (on the main actor)
    /// once speech ends — whether it finishes naturally or is cancelled. `raw` is
    /// the sanitized prompt text (NOT the "X asks:" overlay label). Long prompts
    /// are clipped to their first sentence so a multi-paragraph instruction doesn't
    /// become a monologue; the overlay still shows it all.
    ///
    /// If there's nothing speakable, `onFinish` is called immediately so the caller
    /// never stalls. `onFinish` is guaranteed to run exactly once.
    func speak(_ raw: String, onFinish: @escaping () -> Void) {
        let text = Self.spokenForm(of: raw)
        guard !text.isEmpty else { onFinish(); return }

        // A new question supersedes any in-flight one. Drop the old gate first so
        // its (about-to-arrive) didCancel can't fire the new caller's onFinish.
        if synth.isSpeaking {
            onSpeechEnd = nil
            pendingUtterance = nil
            synth.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        // System default voice/rate — matches whatever the user set in
        // System Settings ▸ Accessibility ▸ Spoken Content.
        utterance.prefersAssistiveTechnologySettings = true
        pendingUtterance = utterance
        onSpeechEnd = onFinish
        synth.speak(utterance)
    }

    /// Stop any in-flight speech WITHOUT firing the completion (the caller is
    /// tearing down, not advancing to capture). Used on session end so speech
    /// never runs into the next session.
    func stopSpeaking() {
        onSpeechEnd = nil
        pendingUtterance = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    // MARK: AVSpeechSynthesizerDelegate
    //
    // Delegate callbacks are not guaranteed on the main thread, so each hops back
    // to the main actor. Both didFinish and didCancel are terminal — treat either
    // as "speech is over". The utterance-identity check drops the stale didCancel
    // that a superseding speak() triggers for the previous utterance.

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.completeIfCurrent(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.completeIfCurrent(utterance) }
    }

    /// Fire the pending completion iff this is the utterance we're waiting on, then
    /// clear it so it can't run twice.
    private func completeIfCurrent(_ utterance: AVSpeechUtterance) {
        guard utterance === pendingUtterance else { return }
        let done = onSpeechEnd
        onSpeechEnd = nil
        pendingUtterance = nil
        done?()
    }

    /// First sentence of a prompt, trimmed and length-capped, for reading aloud.
    /// Keeps TTS short and answerable; the full text remains on the overlay.
    static func spokenForm(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Cut at the first sentence terminator (., !, ?) so we read one question,
        // not a wall of context. Keep the terminator for natural intonation.
        var firstSentence = trimmed
        if let idx = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            firstSentence = String(trimmed[...idx])
        }
        // Hard cap so a terminator-free run-on can't be read forever.
        let capped = firstSentence.count > 240
            ? String(firstSentence.prefix(240)) + "…"
            : firstSentence
        return capped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
