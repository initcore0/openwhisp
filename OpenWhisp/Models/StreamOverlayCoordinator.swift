import Foundation

/// Stream overlay coordinator — live subtitles for Twitch/OBS (browser source).
///
/// Owns everything about the feature EXCEPT the dictation pipeline itself:
/// the persisted settings (enabled/port/config), the `StreamOverlayServer`
/// lifecycle (start at launch, debounced restart on config edits, failure
/// surfacing), and the captions-capture intent. AppState's involvement is
/// deliberately thin — per the MAK-32 decomposition ratchet, the god-object
/// only carries the seams a session already flows through:
///
///   * `publishPartial` from `streamingText.didSet` (live text, every path)
///   * `publishFinal` from `completeFinalText` (the cleaned transcript)
///   * `sessionDidBegin()` / `sessionDidEnd()` from the session funnel
///   * the `captureRequested`/`captureActive` reads in the routing + safety gates
///
/// The capture session is a normal locked dictation session started through
/// `AppState.startDictation(locked:)`; `captureRequested` marks the next
/// `beginSession` captions-only (suppressed output, silence-safety exempt).
@MainActor
final class StreamOverlayCoordinator: ObservableObject {

    /// Default overlay port. Fixed (not ephemeral) because the OBS browser-source
    /// URL must survive restarts; outside the whisper (8178–8677) and llama
    /// (8678–9177) loopback bands so the engines' port probing can never collide
    /// with it.
    static let defaultPort = 9280

    /// Master switch for the loopback subtitle server. Off by default; when on,
    /// the server starts at launch and follows the toggle live.
    @Published var enabled: Bool {
        didSet {
            store.set(enabled, forKey: "streamOverlayEnabled")
            refresh()
        }
    }
    /// Fixed port for the overlay URL (OBS browser sources want a stable URL).
    @Published var port: Int {
        didSet {
            store.set(port, forKey: "streamOverlayPort")
            refresh()
        }
    }
    /// Display parameters of the overlay page (canvas, font, colors, lines,
    /// wrap budget, linger). Persisted as JSON; every change restarts the
    /// server (debounced) so the served page always reflects the saved look.
    @Published var config: StreamOverlayConfig {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                store.set(String(decoding: data, as: UTF8.self), forKey: "streamOverlayConfig")
            }
            refresh()
        }
    }
    /// True while the overlay web server is up (drives the pane's status row).
    @Published private(set) var running = false
    /// True while the captions CAPTURE session (mic → subtitles) is live.
    /// Distinct from `running`: the server can serve an idle page while nothing
    /// is being captured.
    @Published private(set) var captureActive = false
    /// Set by `startCapture()` for the next `beginSession` to mark that session
    /// captions-only. Consumed by `sessionDidBegin()`; read by the live-routing
    /// gate in `startDictation`.
    private(set) var captureRequested = false

    private var server: StreamOverlayServer?
    /// Debounce for config-driven restarts (a color-picker drag fires dozens of
    /// updates; restarting the listener per tick would drop SSE clients).
    private var restartTimer: Timer?
    private let store: SettingsStore
    private weak var app: AppState?

    init(store: SettingsStore, app: AppState) {
        self.store = store
        self.app = app
        enabled = store.bool(forKey: "streamOverlayEnabled")
        port = store.object(forKey: "streamOverlayPort") as? Int ?? Self.defaultPort
        if let json = store.string(forKey: "streamOverlayConfig"),
           let saved = try? JSONDecoder().decode(StreamOverlayConfig.self, from: Data(json.utf8)) {
            config = saved.sanitized()
        } else {
            config = StreamOverlayConfig()
        }
    }

    /// The URL streamers paste into OBS ("Browser" source) or a browser tab.
    var url: String { "http://127.0.0.1:\(port)/" }

    // MARK: - Server lifecycle

    /// Start the overlay server if the user has enabled it. Called once at
    /// launch (property observers don't fire during init).
    func startIfEnabled() {
        guard enabled else { return }
        startServer()
    }

    /// React to a settings change: stop when disabled; when enabled, restart
    /// with the current config after a short debounce. The overlay page
    /// auto-reconnects (EventSource retries on its own), so a restart costs a
    /// sub-second caption gap, not a dead OBS source.
    private func refresh() {
        restartTimer?.invalidate()
        restartTimer = nil
        guard enabled else {
            stopServer()
            return
        }
        restartTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startServer() }
        }
    }

    /// (Re)start the server with the current settings. Tearing down first is
    /// deliberate: the served HTML embeds the config, so a live server always
    /// matches the saved look.
    private func startServer() {
        stopServer()
        let server = StreamOverlayServer(config: config)
        server.onFailure = { [weak self] message in
            guard let self, self.server === server else { return }
            self.server = nil
            self.running = false
            self.app?.error = "Stream overlay stopped: \(message)"
        }
        do {
            try server.start(port: UInt16(clamping: port))
            self.server = server
            running = true
        } catch {
            self.server = nil
            running = false
            app?.error = "Stream overlay failed to start on port \(port): \(error.localizedDescription)"
        }
    }

    private func stopServer() {
        // Capture without a server is pointless — stop it too (sessionDidEnd
        // then hides any lingering subtitles).
        if captureActive { stopCapture() }
        server?.stop()
        server = nil
        running = false
    }

    // MARK: - Captions capture (mic → subtitles, no typing)

    /// Start the captions capture session from the pane: a locked (hands-free)
    /// dictation session whose transcript goes ONLY to the overlay — output is
    /// suppressed, the hands-free silence safety stop is disarmed (a streamer's
    /// quiet stretch must not end it), and it runs until `stopCapture()` (or
    /// Esc / the dictation hotkey / an agent preempt, which end the session
    /// through the normal funnel).
    func startCapture() {
        guard enabled, server != nil, let app else { return }
        guard !app.sessionActive, !app.meetingInProgress else {
            app.statusMessage = app.meetingInProgress
                ? "Stop the meeting before starting captions"
                : "Finish the current dictation before starting captions"
            return
        }
        captureRequested = true
        app.startDictation(locked: true)
        // startDictation has synchronous refusal paths (secure field, meeting,
        // TTS gating) that never reach beginSession — don't leave the request
        // armed to hijack the user's NEXT normal dictation.
        if !app.sessionActive { captureRequested = false }
    }

    /// Stop the captions capture session (the pane's Stop button).
    func stopCapture() {
        guard captureActive else { return }
        app?.stopDictation()
    }

    // MARK: - Session-funnel hooks (called from AppState)

    /// True once a translated segment was published in the current session —
    /// marks it a dual-runtime translation session for final-routing above.
    private var translatedThisSession = false

    /// `beginSession` consumes the pending capture request; returns whether the
    /// session that is starting is a captions capture (→ suppressed output).
    func sessionDidBegin() -> Bool {
        translatedThisSession = false
        captureActive = captureRequested
        captureRequested = false
        return captureActive
    }

    /// `finishSessionUI` — every session terminal. Ends capture (Stop button,
    /// Esc, error, and preempts all funnel here) and hides lingering subtitles.
    func sessionDidEnd() {
        captureRequested = false
        guard captureActive else { return }
        captureActive = false
        server?.publishClear()
    }

    /// Live text from the pipeline ("" on session reset hides the captions).
    func publishPartial(_ text: String) {
        server?.publishPartial(text)
    }

    /// The session's cleaned final transcript. In a dual-runtime translation
    /// session the text arriving here IS the drained English translation
    /// (AppState swapped it in completeFinalText) — route it to the TRANSLATED
    /// track so English never lands on the original-language track at session
    /// end. `translatedThisSession` is the tell: only dual sessions publish
    /// translated segments.
    func publishFinal(_ text: String) {
        if translatedThisSession {
            server?.publishTranslatedFinal(text)
        } else {
            server?.publishFinal(text)
        }
    }

    /// A translated English segment for the overlay's second caption track
    /// (dual-runtime translation). No-op when the server isn't running.
    func publishTranslatedFinal(_ text: String) {
        translatedThisSession = true
        server?.publishTranslatedFinal(text)
    }
}
