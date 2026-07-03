import SwiftUI
import Cocoa

/// Advanced: genuinely operational internals only — whisper.cpp runtime,
/// live-typing tuning, diagnostics, and (in instrumentation builds) the LLM Lab.
struct AdvancedPane: View {
    @ObservedObject var appState: AppState

    private var isWhisperCpp: Bool { appState.transcriptionEngine == "whisper" }

    var body: some View {
        Form {
            if isWhisperCpp {
                whisperRuntimeSection
                liveTypingSection
            } else {
                Section {
                    Text("whisper.cpp runtime and live-typing tuning appear here when the Whisper Local engine is selected (Models › Engine).")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            diagnosticsSection

            #if OPENWHISP_INSTRUMENTATION
            Section {
                LLMLabView(appState: appState)
            } header: {
                Text("Developer — LLM Lab")
            }
            #endif
        }
        .formStyle(.grouped)
    }

    // MARK: - whisper.cpp runtime

    private var whisperRuntimeSection: some View {
        Section {
            // Axis-consistent labels: what it does, not how it's built.
            Picker("Backend", selection: $appState.whisperBackend) {
                Text("Background server — keeps the model loaded (faster)").tag("serverAPI")
                Text("Command line — starts fresh each dictation (simpler)").tag("cli")
            }

            LabeledContent("Server status") {
                Text(appState.whisperWorkerStatus)
                    .foregroundColor(appState.whisperWorkerStatus.hasPrefix("Loaded") ? .green : .secondary)
            }

            LabeledContent("Log") {
                HStack(spacing: 8) {
                    Text(appState.whisperLogPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: appState.whisperLogPath)]
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Binary path")
                HStack {
                    TextField("Binary path", text: $appState.whisperBinaryPath)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button("Choose…") { browseWhisperBinary() }
                    Button("Verify") { verifySetup() }
                }
            }

            Button("Stop Server") { appState.stopWhisperServer() }
        } header: {
            Text("whisper.cpp Runtime")
        } footer: {
            SettingsFootnote("Server failures are reported explicitly and never silently switch back to the command line.")
        }
    }

    // MARK: - Live typing tuning

    private var liveTypingSection: some View {
        Section {
            Picker("Chunk duration", selection: $appState.liveChunkDuration) {
                Text("1.0 s — fastest").tag(1.0)
                Text("1.5 s").tag(1.5)
                Text("2.0 s — balanced").tag(2.0)
                Text("3.0 s — most accurate").tag(3.0)
            }
            .disabled(appState.pauseBasedLiveChunksEnabled)

            // The subtitle surfaces the side effect — no silent mode-forcing.
            SubtitledToggle(
                "Pause-based chunking",
                subtitle: "Splits on natural pauses instead of the timer. Turns on “Type live” output.",
                isOn: $appState.pauseBasedLiveChunksEnabled
            )
            .onChange(of: appState.pauseBasedLiveChunksEnabled) {
                if appState.pauseBasedLiveChunksEnabled {
                    appState.outputMode = "liveChunks"
                }
            }
        } header: {
            Text("Live Typing Tuning")
        } footer: {
            SettingsFootnote("Only applies to the “Type live” output mode. Chunks transcribe up to two at a time and insert in order. Chunk duration is ignored while pause-based chunking is on.")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Status") {
                Text(appState.statusMessage)
                    .foregroundColor(statusColor)
            }

            if let error = appState.error, !error.isEmpty {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if let last = appState.lastTranscription, !last.isEmpty {
                LabeledContent("Last transcription") {
                    Text("\(last.prefix(80))\(last.count > 80 ? "…" : "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("Diagnostics")
        }
    }

    private var statusColor: Color {
        switch appState.statusMessage {
        case "Ready", "Done": return .green
        case "Recording...": return .red
        default:
            if appState.statusMessage.hasPrefix("Transcribing") || appState.statusMessage == "Finalizing..." { return .orange }
            if appState.error != nil { return .red }
            return .gray
        }
    }

    private func browseWhisperBinary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.executable]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.whisperBinaryPath = url.path
        }
    }

    private func verifySetup() {
        let binaryExists = FileManager.default.fileExists(atPath: appState.whisperBinaryPath)
        let modelExists = FileManager.default.fileExists(atPath: appState.modelPath)

        if binaryExists && modelExists {
            appState.statusMessage = "Setup verified ✓"
            appState.error = nil
        } else {
            var msg = "Setup incomplete.\n"
            if !binaryExists { msg += "✗ whisper.cpp binary not found\n" }
            if !modelExists { msg += "✗ Model file not found\n" }
            appState.error = msg
        }
    }
}
