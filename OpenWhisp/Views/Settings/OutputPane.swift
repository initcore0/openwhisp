import SwiftUI
import Cocoa

/// Output: where and how text lands. Absorbs the old Text Output section and
/// the Script Post-processor (a script that mutates the final transcript is an
/// output-stage hook, not generic "advanced").
struct OutputPane: View {
    @ObservedObject var appState: AppState

    private var isWhisperKit: Bool { appState.transcriptionEngine == "whisperKit" }

    var body: some View {
        Form {
            deliverySection
            insertionSection
            scriptSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section {
            SelectableRow(
                title: "Preview, then insert",
                subtitle: "Text streams into the on-screen overlay as you speak; inserted once when you release the key.",
                badge: "Recommended",
                isSelected: appState.outputMode == "preview"
            ) { appState.outputMode = "preview" }

            SelectableRow(
                title: "Insert at end",
                subtitle: "Like Preview, but without the live overlay text; inserts once on release.",
                isSelected: appState.outputMode == "finalOnly"
            ) { appState.outputMode = "finalOnly" }

            // Shown disabled under WhisperKit instead of hidden — users should
            // learn the option exists and what unlocks it (spec principle 4).
            SelectableRow(
                title: "Type live as you speak",
                subtitle: isWhisperKit
                    ? "Requires the whisper.cpp engine (Models › Engine)."
                    : "Each phrase is inserted into the app as you speak.",
                isSelected: appState.outputMode == "liveChunks",
                isEnabled: !isWhisperKit
            ) { appState.outputMode = "liveChunks" }
        } header: {
            Text("Delivery")
        } footer: {
            if isWhisperKit {
                SettingsFootnote("WhisperKit streams partials in real time with built-in silence skipping, so live typing isn't used with it.")
            }
        }
    }

    // MARK: - Insertion

    private var insertionSection: some View {
        Section {
            SelectableRow(
                title: "Automatic",
                subtitle: "Inserts directly when the app allows it, otherwise pastes.",
                badge: "Recommended",
                isSelected: appState.insertionMode == "auto"
            ) { appState.insertionMode = "auto" }

            SelectableRow(
                title: "Direct insert only",
                subtitle: "Never touches the clipboard; some apps don't support it.",
                isSelected: appState.insertionMode == "directAX"
            ) { appState.insertionMode = "directAX" }

            SelectableRow(
                title: "Paste",
                subtitle: "Always uses ⌘V.",
                isSelected: appState.insertionMode == "paste"
            ) { appState.insertionMode = "paste" }

            SubtitledToggle(
                "Restore clipboard after pasting",
                subtitle: appState.insertionMode == "directAX"
                    ? "Not needed — Direct insert never touches the clipboard."
                    : "Puts back whatever was on your clipboard once the text is pasted. Reading the clipboard may trigger a macOS privacy prompt.",
                isOn: $appState.restoreClipboard
            )
            .disabled(appState.insertionMode == "directAX")

            Toggle("Add a space after inserted text", isOn: $appState.addTrailingSpace)
        } header: {
            Text("Insertion")
        }
    }

    // MARK: - Script

    private var scriptSection: some View {
        Section {
            SubtitledToggle(
                "Run my script on the final transcript",
                subtitle: "Pipes the final transcript through an executable you choose — your text on stdin, the result on stdout. Runs with a ~2 s timeout and falls back to the original text on any error.",
                isOn: $appState.scriptPostProcessorEnabled
            )

            if appState.scriptPostProcessorEnabled {
                HStack {
                    Text(appState.scriptPostProcessorPath.isEmpty ? "No script chosen" : appState.scriptPostProcessorPath)
                        .font(.caption)
                        .foregroundColor(appState.scriptPostProcessorPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseScript() }
                    if !appState.scriptPostProcessorPath.isEmpty {
                        Button("Clear") { appState.scriptPostProcessorPath = "" }
                    }
                }

                if let warning = scriptPathWarning {
                    SettingsCallout(
                        .warning,
                        warning,
                        actionLabel: FileManager.default.fileExists(atPath: appState.scriptPostProcessorPath) ? "Reveal in Finder" : nil
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: appState.scriptPostProcessorPath)]
                        )
                    }
                }
            }
        } header: {
            Text("Script")
        } footer: {
            if appState.scriptPostProcessorEnabled {
                SettingsFootnote("This does run code you point it at — only use a script you trust.")
            }
        }
    }

    /// Inline validation of the chosen script path (pure validator + FileManager).
    private var scriptPathWarning: String? {
        let path = appState.scriptPostProcessorPath
        switch ScriptPathValidator.validate(
            path,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) {
        case .ok, .empty: return nil
        case .notFound: return "That file doesn't exist."
        case .notExecutable: return "That file isn't executable (chmod +x it)."
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose Script"
        panel.message = "Choose an executable script to post-process the final transcript"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.scriptPostProcessorPath = url.path
    }
}
