import SwiftUI
import AppKit

/// Stream Overlay — live subtitles for Twitch/OBS. Runs a local web server that
/// serves a transparent caption page; the streamer adds it to OBS as a Browser
/// source (or opens it in a browser) and every dictation shows up as subtitles.
///
/// The look (canvas, font, colors, line count) maps 1:1 onto
/// `StreamOverlayConfig`; edits apply LIVE to the running server (pushed to open
/// pages over SSE) so they can be tuned mid-stream without interrupting a
/// captions capture. Only the port restarts the server.
struct StreamOverlayPane: View {
    @ObservedObject var overlay: StreamOverlayCoordinator
    /// The dictation language setting — the best proxy for what a captions
    /// capture will hear, so the translation section can show a concrete
    /// asset-status row ("auto" shows the download-on-first-use note instead).
    var dictationLanguage: String = "auto"

    var body: some View {
        Form {
            introSection
            if overlay.enabled {
                captureSection
                serverSection
                voiceCommandsSection
                translationSection
                displaySection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Enable + explainer

    private var introSection: some View {
        Section {
            Text("Show your dictation as live subtitles in a stream. OpenWhisp serves a transparent caption page on this Mac; add it to OBS as a Browser source sized to your canvas, and everything you dictate appears as captions — all local, nothing leaves this machine.")
                .font(.callout)
                .foregroundColor(.secondary)

            Toggle("Enable stream overlay server", isOn: $overlay.enabled)
        } header: {
            Text("Stream Overlay")
        }
    }

    // MARK: Captions capture

    /// The mic → subtitles control. Separate from the server toggle: the server
    /// serves the (possibly idle) page; this starts/stops actually listening.
    private var captureSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(overlay.captureActive ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(overlay.captureActive ? "Capturing — speech becomes subtitles" : "Not capturing")
                Spacer()
                if overlay.captureActive {
                    Button {
                        overlay.stopCapture()
                    } label: {
                        Label("Stop Captions", systemImage: "stop.circle.fill")
                    }
                    .tint(.red)
                } else {
                    Button {
                        overlay.startCapture()
                    } label: {
                        Label("Start Captions", systemImage: "record.circle")
                    }
                    .disabled(!overlay.running)
                }
            }

            // Independent of the capture session: capture is "is the mic on",
            // this is "do the words show up as subtitles". Turning it off leaves
            // a working capture that only drives voice commands (below).
            Toggle("Show live transcription (subtitles) on the overlay", isOn: configBinding(\.captionsEnabled))
                .help("Off means the overlay shows no transcription/caption text at all — useful when you only want voice-command widgets like the counter.")
        } header: {
            Text("Captions")
        } footer: {
            Text("Runs hands-free until you stop it — nothing is typed into your apps, and the transcript only feeds the overlay. The floating dictation overlay stays hidden so it can't show up on your stream. Long silences don't end it. Esc or the dictation hotkey also stop it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Voice commands

    /// Voice commands drive overlay WIDGETS instead of captions: say a phrase on
    /// stream and something on the overlay reacts. The first (and for now only)
    /// command is a phrase counter — "I died again" → Deaths: 12.
    private var voiceCommandsSection: some View {
        Section {
            Toggle("Count a phrase", isOn: configBinding(\.counterEnabled))

            if overlay.config.counterEnabled {
                TextField("Trigger phrase", text: configBinding(\.counterPhrase),
                          prompt: Text("I died again"))
                    .help("Said on stream, this phrase bumps the counter. Capitalization and punctuation don't matter; any language works.")

                TextField("Counter label", text: configBinding(\.counterLabel),
                          prompt: Text("Deaths"))
                    .help("Shown next to the number on the overlay, e.g. “Deaths: 12”.")

                Picker(selection: configBinding(\.counterCorner)) {
                    ForEach(StreamOverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                } label: {
                    Label("Corner", systemImage: "square.on.square.dashed")
                }

                HStack {
                    Label("Current count", systemImage: "number.circle")
                    Spacer()
                    Text("\(overlay.counterCount)")
                        .font(.system(.title3, design: .rounded))
                        .monospacedDigit()
                    Button {
                        overlay.resetCounter()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(overlay.counterCount == 0)
                }

                if overlay.config.counterPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SettingsCallout(.warning, "Set a trigger phrase — an empty phrase never counts.")
                }
            }
        } header: {
            Text("Voice Commands")
        } footer: {
            Text("Say the phrase while captions are capturing and the counter ticks up. It counts when the sentence finishes, so there's a short delay after you speak, and saying it twice in one sentence counts twice. The count is kept when you restart OpenWhisp — use Reset to start a new stream at zero.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(overlay.running ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(overlay.running ? "Running" : "Starting…")
                Spacer()
                Text(overlay.url)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(overlay.url, forType: .string)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button {
                    if let url = URL(string: overlay.url) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Preview in Browser", systemImage: "safari")
                }
            }

            TextField("Port", value: portBinding, format: .number.grouping(.never))
                .frame(maxWidth: 120)
                .help("The overlay URL's port. Change it if something else on this Mac already uses it.")

            SettingsCallout(.info, "In OBS: add a “Browser” source, paste the URL, and set its width and height to the canvas size below.")
        } header: {
            Text("Server")
        }
    }

    /// Clamp typed ports into the user range once editing settles; the server
    /// restarts via the AppState observer.
    private var portBinding: Binding<Int> {
        Binding(
            get: { overlay.port },
            set: { overlay.port = min(max($0, 1_024), 65_535) })
    }

    // MARK: Translation

    /// Translated subtitles: each finalized caption line runs through Apple's
    /// on-device Translation framework (macOS 15+) into the chosen language
    /// before it is shown. Live partials stay in the spoken language (they
    /// change too fast to be worth a round trip), and a failed translation
    /// shows the original line — captions are never dropped. On macOS 14 the
    /// controls are replaced by an availability note.
    private var translationSection: some View {
        Section {
            if AppleTextTranslation.isSupported {
                Toggle("Translate subtitles", isOn: translationEnabledBinding)

                if overlay.config.translationEnabled {
                    Picker(selection: configBinding(\.targetLanguage)) {
                        ForEach(Self.targetLanguages, id: \.self) { code in
                            Text(LanguageResolver.displayName(for: code)).tag(code)
                        }
                    } label: {
                        Label("Subtitle language", systemImage: "captions.bubble")
                    }

                    TranslationAssetStatusView(
                        sourceTag: dictationLanguage,
                        targetTag: overlay.config.targetLanguage,
                        autoNote: "Auto Detect: the spoken language is detected per caption, and its translation pack downloads on first use — until then those lines show untranslated. Pick a dictation language in the Dictation pane to download ahead of time.")

                    SettingsCallout(.info, "Runs on-device with Apple's translation. Until a language pack is downloaded, subtitles show in the spoken language.")
                }
            } else {
                SettingsFootnote("Translated subtitles need macOS 15 or later.")
            }
        } header: {
            Text("Translation")
        }
    }

    /// Overlay subtitle languages offered (matches the app's language list).
    /// The config stores any BCP-47-ish tag; this picker just curates the
    /// common ones.
    private static let targetLanguages = [
        "en", "es", "fr", "de", "it", "pt", "ja", "zh", "ko", "ru", "ar",
    ]

    /// Enabling with no target yet picks English so the toggle visibly does
    /// something (the server treats an empty target as pass-through).
    private var translationEnabledBinding: Binding<Bool> {
        Binding(
            get: { overlay.config.translationEnabled },
            set: {
                overlay.config.translationEnabled = $0
                if $0 && overlay.config.targetLanguage.isEmpty {
                    overlay.config.targetLanguage = "en"
                }
            })
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            HStack {
                TextField("Width", value: configBinding(\.canvasWidth), format: .number.grouping(.never))
                    .frame(maxWidth: 90)
                Text("×").foregroundColor(.secondary)
                TextField("Height", value: configBinding(\.canvasHeight), format: .number.grouping(.never))
                    .frame(maxWidth: 90)
                Spacer()
                Button("1080p") { setCanvas(1920, 1080) }
                Button("1440p") { setCanvas(2560, 1440) }
                Button("4K") { setCanvas(3840, 2160) }
            }
            .help("Match the Browser source's width/height in OBS.")

            TextField("Font", text: configBinding(\.fontFamily),
                      prompt: Text("-apple-system, 'Helvetica Neue', sans-serif"))
                .help("Any CSS font-family list. The font must be available where OBS runs.")

            Stepper(value: configBinding(\.fontSize), in: 8...400, step: 2) {
                HStack {
                    Text("Font size")
                    Spacer()
                    Text("\(overlay.config.fontSize) px")
                        .foregroundColor(.secondary)
                }
            }

            colorRow("Text color", keyPath: \.textColor)
            colorRow("Background", keyPath: \.backgroundColor)
            Toggle("Transparent background", isOn: transparentBackgroundBinding)
                .help("What you want for OBS — only the captions render over your scene.")

            Stepper(value: configBinding(\.maxLines), in: 1...10) {
                HStack {
                    Text("Subtitle lines on screen")
                    Spacer()
                    Text("\(overlay.config.maxLines)")
                        .foregroundColor(.secondary)
                }
            }

            Stepper(value: configBinding(\.charsPerLine), in: 16...120, step: 2) {
                HStack {
                    Text("Characters per line")
                    Spacer()
                    Text("\(overlay.config.charsPerLine)")
                        .foregroundColor(.secondary)
                }
            }
            .help("Word-wrap budget per subtitle line. Broadcast captions use 32–42.")

            Stepper(value: configBinding(\.lingerSeconds), in: 1...30) {
                HStack {
                    Text("Hide after silence")
                    Spacer()
                    Text("\(overlay.config.lingerSeconds) s")
                        .foregroundColor(.secondary)
                }
            }
            .help("Captions disappear this many seconds after speech stops, like movie subtitles.")
        } header: {
            Text("Appearance")
        } footer: {
            Text("Behaves like movie subtitles: speech shows as up to the configured number of wrapped lines, older lines scroll off the top as you keep talking, and everything disappears after silence — when you speak again only the new words appear. These settings apply instantly, so you can tune them while captions are running.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Bindings

    private func configBinding<T>(_ keyPath: WritableKeyPath<StreamOverlayConfig, T>) -> Binding<T> {
        Binding(
            get: { overlay.config[keyPath: keyPath] },
            set: { overlay.config[keyPath: keyPath] = $0 })
    }

    private func setCanvas(_ w: Int, _ h: Int) {
        overlay.config.canvasWidth = w
        overlay.config.canvasHeight = h
    }

    /// A color-well row bridging SwiftUI `Color` ↔ the config's hex string.
    private func colorRow(_ label: String, keyPath: WritableKeyPath<StreamOverlayConfig, String>) -> some View {
        HStack {
            ColorPicker(label, selection: Binding(
                get: { Color(hex: overlay.config[keyPath: keyPath]) },
                set: { overlay.config[keyPath: keyPath] = $0.hexRGBA }
            ), supportsOpacity: true)
            Text(overlay.config[keyPath: keyPath])
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    /// Convenience for the common case: flips the background between fully
    /// transparent and opaque black, keeping the picker for anything custom.
    private var transparentBackgroundBinding: Binding<Bool> {
        Binding(
            get: { overlay.config.backgroundColor.hasSuffix("00")
                && overlay.config.backgroundColor.count == 9 },
            set: { overlay.config.backgroundColor = $0 ? "#00000000" : "#000000" })
    }
}

// MARK: - Color ↔ hex bridging

extension Color {
    /// Parse a `#RGB`/`#RRGGBB`/`#RRGGBBAA` hex string (the StreamOverlayConfig
    /// wire format). Falls back to white on garbage — the config sanitizer is
    /// the real gate; this just keeps the picker total.
    init(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        if digits.count == 6 { digits += "FF" }
        guard digits.count == 8, let value = UInt64(digits, radix: 16) else {
            self = .white
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            opacity: Double(value & 0xFF) / 255)
    }

    /// Serialize to `#RRGGBBAA` (drops to `#RRGGBB` when fully opaque, matching
    /// how users write colors by hand).
    var hexRGBA: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        let a = Int(round(ns.alphaComponent * 255))
        return a == 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
