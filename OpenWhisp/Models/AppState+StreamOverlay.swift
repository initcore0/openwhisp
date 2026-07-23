import Foundation

// MARK: - Stream overlay lifecycle (live subtitles for OBS/Twitch)
//
// Owns the StreamOverlayServer that serves the browser-source page + SSE caption
// stream on loopback. The pipeline feeds it from exactly two seams in
// AppState.swift: `streamingText.didSet` (live partial, every dictation path) and
// `completeFinalText` (the cleaned final transcript). Settings changes land here
// via the property observers on streamOverlayEnabled/Port/Config.

extension AppState {

    /// Default overlay port. Fixed (not ephemeral) because the OBS browser-source
    /// URL must survive restarts; outside the whisper (8178–8677) and llama
    /// (8678–9177) loopback bands so the engines' port probing can never collide
    /// with it.
    static let streamOverlayDefaultPort = 9280

    /// The URL streamers paste into OBS ("Browser" source) or a browser tab.
    var streamOverlayURL: String { "http://127.0.0.1:\(streamOverlayPort)/" }

    /// Start the overlay server if the user has enabled it. Called once at
    /// launch (property observers don't fire during init).
    func startStreamOverlayIfEnabled() {
        guard streamOverlayEnabled else { return }
        startStreamOverlayServer()
    }

    /// React to a settings change: stop when disabled; when enabled, restart
    /// with the current config after a short debounce (a color-picker drag fires
    /// dozens of updates — one listener bounce, not thirty). The overlay page
    /// auto-reconnects: EventSource retries on its own, so a restart costs a
    /// sub-second caption gap, not a dead OBS source.
    func refreshStreamOverlayServer() {
        streamOverlayRestartTimer?.invalidate()
        streamOverlayRestartTimer = nil
        guard streamOverlayEnabled else {
            stopStreamOverlayServer()
            return
        }
        streamOverlayRestartTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startStreamOverlayServer() }
        }
    }

    /// (Re)start the server with the current settings. Tearing down first is
    /// deliberate: the served HTML embeds the config, so a live server always
    /// matches the saved look.
    private func startStreamOverlayServer() {
        stopStreamOverlayServer()
        let server = StreamOverlayServer(config: streamOverlayConfig)
        server.onFailure = { [weak self] message in
            guard let self, self.streamOverlayServer === server else { return }
            self.streamOverlayServer = nil
            self.streamOverlayRunning = false
            self.error = "Stream overlay stopped: \(message)"
        }
        do {
            try server.start(port: UInt16(clamping: streamOverlayPort))
            streamOverlayServer = server
            streamOverlayRunning = true
        } catch {
            streamOverlayServer = nil
            streamOverlayRunning = false
            self.error = "Stream overlay failed to start on port \(streamOverlayPort): \(error.localizedDescription)"
        }
    }

    private func stopStreamOverlayServer() {
        streamOverlayServer?.stop()
        streamOverlayServer = nil
        streamOverlayRunning = false
    }
}
