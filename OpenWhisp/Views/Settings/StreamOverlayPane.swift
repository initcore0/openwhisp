import SwiftUI
import AppKit

/// Stream Overlay — live subtitles for Twitch/OBS. Runs a local web server that
/// serves a transparent caption page; the streamer adds it to OBS as a Browser
/// source (or opens it in a browser) and every dictation shows up as subtitles.
///
/// The look (canvas, font, colors, line count) maps 1:1 onto
/// `StreamOverlayConfig`; edits restart the server (debounced in AppState) so
/// the served page always matches what this pane shows.
struct StreamOverlayPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            introSection
            if appState.streamOverlayEnabled {
                captureSection
                serverSection
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

            Toggle("Enable stream overlay server", isOn: $appState.streamOverlayEnabled)
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
                    .fill(appState.streamOverlayCaptureActive ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(appState.streamOverlayCaptureActive ? "Capturing — speech becomes subtitles" : "Not capturing")
                Spacer()
                if appState.streamOverlayCaptureActive {
                    Button {
                        appState.stopStreamOverlayCapture()
                    } label: {
                        Label("Stop Captions", systemImage: "stop.circle.fill")
                    }
                    .tint(.red)
                } else {
                    Button {
                        appState.startStreamOverlayCapture()
                    } label: {
                        Label("Start Captions", systemImage: "record.circle")
                    }
                    .disabled(!appState.streamOverlayRunning)
                }
            }
        } header: {
            Text("Captions")
        } footer: {
            Text("Runs hands-free until you stop it — nothing is typed into your apps, and the transcript only feeds the overlay. Long silences don't end it. Esc or the dictation hotkey also stop it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(appState.streamOverlayRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(appState.streamOverlayRunning ? "Running" : "Starting…")
                Spacer()
                Text(appState.streamOverlayURL)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.streamOverlayURL, forType: .string)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button {
                    if let url = URL(string: appState.streamOverlayURL) {
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
            get: { appState.streamOverlayPort },
            set: { appState.streamOverlayPort = min(max($0, 1_024), 65_535) })
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
                    Text("\(appState.streamOverlayConfig.fontSize) px")
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
                    Text("\(appState.streamOverlayConfig.maxLines)")
                        .foregroundColor(.secondary)
                }
            }

            Stepper(value: configBinding(\.charsPerLine), in: 16...120, step: 2) {
                HStack {
                    Text("Characters per line")
                    Spacer()
                    Text("\(appState.streamOverlayConfig.charsPerLine)")
                        .foregroundColor(.secondary)
                }
            }
            .help("Word-wrap budget per subtitle line. Broadcast captions use 32–42.")

            Stepper(value: configBinding(\.lingerSeconds), in: 1...30) {
                HStack {
                    Text("Hide after silence")
                    Spacer()
                    Text("\(appState.streamOverlayConfig.lingerSeconds) s")
                        .foregroundColor(.secondary)
                }
            }
            .help("Captions disappear this many seconds after speech stops, like movie subtitles.")
        } header: {
            Text("Appearance")
        } footer: {
            Text("Behaves like movie subtitles: speech shows as up to the configured number of wrapped lines, older lines scroll off the top as you keep talking, and everything fades out after silence.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Bindings

    private func configBinding<T>(_ keyPath: WritableKeyPath<StreamOverlayConfig, T>) -> Binding<T> {
        Binding(
            get: { appState.streamOverlayConfig[keyPath: keyPath] },
            set: { appState.streamOverlayConfig[keyPath: keyPath] = $0 })
    }

    private func setCanvas(_ w: Int, _ h: Int) {
        appState.streamOverlayConfig.canvasWidth = w
        appState.streamOverlayConfig.canvasHeight = h
    }

    /// A color-well row bridging SwiftUI `Color` ↔ the config's hex string.
    private func colorRow(_ label: String, keyPath: WritableKeyPath<StreamOverlayConfig, String>) -> some View {
        HStack {
            ColorPicker(label, selection: Binding(
                get: { Color(hex: appState.streamOverlayConfig[keyPath: keyPath]) },
                set: { appState.streamOverlayConfig[keyPath: keyPath] = $0.hexRGBA }
            ), supportsOpacity: true)
            Text(appState.streamOverlayConfig[keyPath: keyPath])
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    /// Convenience for the common case: flips the background between fully
    /// transparent and opaque black, keeping the picker for anything custom.
    private var transparentBackgroundBinding: Binding<Bool> {
        Binding(
            get: { appState.streamOverlayConfig.backgroundColor.hasSuffix("00")
                && appState.streamOverlayConfig.backgroundColor.count == 9 },
            set: { appState.streamOverlayConfig.backgroundColor = $0 ? "#00000000" : "#000000" })
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
