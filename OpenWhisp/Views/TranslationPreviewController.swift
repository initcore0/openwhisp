import AppKit
import Combine
import SwiftUI

/// EXPERIMENTAL — the live translation-preview panel.
///
/// A second, small, DISPLAY-ONLY floating panel below the dictation overlay
/// that shows a near-real-time English translation of what's being dictated, so
/// the user can watch translation happen and judge its quality while speaking
/// instead of discovering it at paste time.
///
/// Why it exists: with an ASR-only engine (Parakeet / Apple Speech /
/// SpeechAnalyzer) and "Translate to English" on, the shipped TEXT path
/// (`TextTranslationPolicy.shouldTranslateFinal`) translates only the FINAL
/// transcript — the overlay streams the SPOKEN language the whole way. This
/// panel arms on exactly that condition.
///
/// **It never writes into the document.** The final paste keeps flowing through
/// the shipped text path untouched; this is a window that reads
/// `AppState.streamingText` and nothing more. It observes AppState via Combine
/// rather than being fed by it, so AppState gains no lines (MAK-32 ratchet), and
/// its experimental toggle lives in its own UserDefaults key here rather than as
/// an AppState property for the same reason.
///
/// Throttling is delegated to the pure, unit-tested `TranslationPreviewPolicy`:
/// one translator request in flight at a time, fired on a sentence boundary in
/// the new text or after ~1.2s of quiet, with latest-wins re-fire when a result
/// lands for text the transcript has already outgrown.
@MainActor
final class TranslationPreviewController {

    /// UserDefaults key for the experimental opt-in. Owned here, NOT on
    /// AppState — see the MAK-32 ratchet note above. The Settings row in
    /// DictationPane reads/writes it through the accessors below.
    static let defaultsKey = "translationPreviewEnabled"

    /// Off by default: this is an experiment, and each session it's on costs
    /// on-device translator calls while you speak.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Polling cadence for the quiet-debounce arm of the policy. The transcript
    /// itself arrives via Combine; this tick only exists so "the text has been
    /// unchanged for 1.2s" can become true without a new partial to notice it.
    private static let tick: TimeInterval = 0.25

    private let appState: AppState
    private let model = TranslationPreviewModel()
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    /// The live partial we're tracking, and when it last changed — the policy's
    /// `secondsSinceTextChanged` input.
    private var currentText = ""
    private var textChangedAt = Date()
    /// Source string of the most recent request (in flight or completed): the
    /// text whose translation is on screen. Empty before the first request.
    private var lastTranslatedSource = ""
    private var inFlight = false
    /// Bumped on every session end. A request that resolves after its session
    /// finished still clears `inFlight` (so the next session isn't wedged) but
    /// must NOT paint its stale translation into the new session's panel.
    private var generation = 0

    init(appState: AppState) {
        self.appState = appState
        observe()
    }

    // MARK: - Observation

    /// Watch the live transcript and the session flags. Deliberately one-way:
    /// AppState publishes, this controller listens.
    private func observe() {
        appState.$streamingText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.transcriptChanged(text) }
            .store(in: &cancellables)

        // Session end (both flags false) tears the panel down; the FINAL paste
        // is the shipped text path's business, not the preview's.
        Publishers.CombineLatest(appState.$isRecording, appState.$isTranscribing)
            .receive(on: RunLoop.main)
            .sink { [weak self] recording, transcribing in
                self?.sessionStateChanged(active: recording || transcribing)
            }
            .store(in: &cancellables)
    }

    private func transcriptChanged(_ text: String) {
        guard text != currentText else { return }
        currentText = text
        textChangedAt = Date()
        refresh()
    }

    private func sessionStateChanged(active: Bool) {
        if active {
            startTicking()
        } else {
            stopTicking()
            reset()
        }
        refresh()
    }

    /// Clear per-session state so the next dictation starts blank rather than
    /// flashing the previous session's translation.
    private func reset() {
        generation += 1
        currentText = ""
        lastTranslatedSource = ""
        model.sourceText = ""
        model.translatedText = ""
        model.isTranslating = false
        // `inFlight` is deliberately NOT cleared: a request from the finished
        // session is still out, and its completion handler must remain the only
        // thing that clears the flag, or the next session could run two at once.
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Policy → panel + translator

    /// The single decision point: is the preview armed, and does the policy want
    /// a translation right now?
    private func refresh() {
        let sessionActive = appState.isRecording || appState.isTranscribing
        let armed = TranslationPreviewPolicy.shouldShowPreview(
            enabled: Self.isEnabled,
            sessionActive: sessionActive,
            text: currentText,
            translateToEnglish: appState.translateToEnglish,
            language: appState.language,
            transcriptionEngine: appState.transcriptionEngine,
            textTranslationAvailable: AppleTextTranslation.isSupported)

        guard armed else {
            hide()
            return
        }
        show()
        model.sourceText = currentText

        guard TranslationPreviewPolicy.shouldFire(
            currentText: currentText,
            lastTranslatedSource: lastTranslatedSource,
            secondsSinceTextChanged: Date().timeIntervalSince(textChangedAt),
            translationInFlight: inFlight) else { return }

        fireTranslation(for: currentText)
    }

    /// Issue one request. Serialized by `inFlight`; when it lands we re-run
    /// `refresh()` so a transcript that moved on in the meantime immediately
    /// gets its own request (latest-wins).
    private func fireTranslation(for text: String) {
        inFlight = true
        lastTranslatedSource = text
        model.isTranslating = true
        let issuedGeneration = generation
        Task { @MainActor [weak self] in
            let translated = await AppleTextTranslation.translate(
                text, from: self?.appState.language, to: "en")
            guard let self else { return }
            // Always release the serialization flag, even for a late result
            // from a finished session — otherwise the next session never fires.
            self.inFlight = false
            guard issuedGeneration == self.generation else { return }
            self.model.isTranslating = false
            if let translated, !translated.isEmpty {
                self.model.translatedText = translated
            } else if self.model.translatedText.isEmpty {
                // Never blank the panel on a failure that follows a good
                // result — a stale translation beats an empty box. With nothing
                // to keep, say why (missing assets is the common case).
                self.model.translatedText = AppleTextTranslation.lastError.map { "— \($0)" } ?? ""
            }
            // The transcript may have advanced while this was out.
            self.refresh()
        }
    }

    // MARK: - Panel

    private func show() {
        if panel == nil {
            let size = NSSize(width: 460, height: 132)
            let host = NSHostingController(rootView: TranslationPreviewView(model: model))
            host.view.frame = NSRect(origin: .zero, size: size)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.contentViewController = host
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            // Same dark-glass commitment as the dictation overlay: the view's
            // colors are hand-tuned for it, so don't let the system theme flip
            // the material light under white text.
            panel.appearance = NSAppearance(named: .vibrantDark)
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            // Display-only: clicks pass straight through to whatever the user
            // is dictating into.
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel?.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.contentViewController = nil
            }
        }
    }

    /// Bottom-center, BELOW the dictation overlay (which sits 140pt up), so the
    /// two panels stack instead of overlapping.
    private func position() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - View

/// Panel contents. Observed rather than passed so the controller can mutate
/// fields without rebuilding the hosting controller.
@MainActor
final class TranslationPreviewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var isTranslating = false
}

/// Source line over the English translation, in the same dark-glass idiom as
/// the dictation overlay but quieter — this is a secondary, informational
/// surface, so caption type and dimmed chrome.
private struct TranslationPreviewView: View {
    @ObservedObject var model: TranslationPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                // SF Symbol, never an emoji (project rule). Non-actionable
                // label, but the panel still reads as a translation surface.
                Image(systemName: "character.bubble")
                    .font(.system(size: 10, weight: .semibold))
                Text("Translation preview (beta)")
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 4)
                if model.isTranslating {
                    Text("Translating…")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.white.opacity(0.5))

            if !model.sourceText.isEmpty {
                Text(model.sourceText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.translatedText.isEmpty ? "…" : model.translatedText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.12), value: model.translatedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        )
    }
}
