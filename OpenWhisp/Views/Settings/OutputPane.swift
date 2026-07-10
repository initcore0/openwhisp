import SwiftUI
import Cocoa

/// Output: where and how text lands. Absorbs the old Text Output section and
/// the Script Post-processor (a script that mutates the final transcript is an
/// output-stage hook, not generic "advanced").
struct OutputPane: View {
    @ObservedObject var appState: AppState

    private var isWhisperKit: Bool { appState.transcriptionEngine == "whisperKit" }

    /// Shortcuts enumerated from `shortcuts list` for the Shortcut picker, loaded
    /// lazily when the Shortcut target is shown. Empty until loaded / if none exist.
    @State private var availableShortcuts: [String] = []
    @State private var shortcutsLoaded = false

    var body: some View {
        Form {
            outputTargetSection
            deliverySection
            insertionSection
            scriptSection
        }
        .formStyle(.grouped)
        .onAppear {
            if appState.outputTargetKind == .shortcut { loadShortcuts() }
        }
        .onChange(of: appState.outputTargetKind) { kind in
            if kind == .shortcut { loadShortcuts() }
        }
    }

    // MARK: - Output target (MAK-11..14)

    /// Where a finished dictation is DELIVERED: the focused app (default), a file, a
    /// macOS Shortcut, or a webhook. A global choice for v1 — one destination for
    /// every app. Config fields for the chosen target appear below the picker; the
    /// chosen target only takes effect once it's fully configured (else dictation
    /// keeps typing into the focused app, and any target failure falls back to it).
    private var outputTargetSection: some View {
        Section {
            SelectableRow(
                title: "Focused app",
                subtitle: "Type or paste the transcript into whatever app you're in. The default.",
                badge: "Default",
                isSelected: appState.outputTargetKind == .focusedApp
            ) { appState.outputTargetKind = .focusedApp }

            SelectableRow(
                title: "File",
                subtitle: "Append (or overwrite) each dictation to a Markdown/text file — e.g. an Obsidian daily note.",
                isSelected: appState.outputTargetKind == .file
            ) { appState.outputTargetKind = .file }

            SelectableRow(
                title: "Shortcut",
                subtitle: "Run a macOS Shortcut with the transcript as its input (Things, Reminders, an HTTP request…).",
                isSelected: appState.outputTargetKind == .shortcut
            ) { appState.outputTargetKind = .shortcut }

            SelectableRow(
                title: "Webhook",
                subtitle: "POST the transcript as JSON to a URL you configure (Notion, Zapier, n8n, a self-hosted endpoint).",
                isSelected: appState.outputTargetKind == .webhook
            ) { appState.outputTargetKind = .webhook }

            switch appState.outputTargetKind {
            case .focusedApp: EmptyView()
            case .file:       fileTargetConfig
            case .shortcut:   shortcutTargetConfig
            case .webhook:    webhookTargetConfig
            }
        } header: {
            Text("Output target")
        } footer: {
            if appState.outputTargetKind != .focusedApp {
                SettingsFootnote("If the target isn't fully configured, or a delivery fails, your words are still typed into the focused app — never dropped. Live-typing (\u{201C}Type live as you speak\u{201D}) always goes to the focused app.")
            }
        }
    }

    // MARK: File target config

    @ViewBuilder
    private var fileTargetConfig: some View {
        HStack {
            Text(appState.fileOutputPath.isEmpty ? "No file chosen" : appState.fileOutputPath)
                .font(.caption)
                .foregroundColor(appState.fileOutputPath.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseOutputFile() }
            if !appState.fileOutputPath.isEmpty {
                Button("Clear") { appState.fileOutputPath = "" }
            }
        }

        Picker("Write mode", selection: fileModeBinding) {
            Text("Append").tag(FileOutputMode.append)
            Text("Overwrite").tag(FileOutputMode.overwrite)
        }

        VStack(alignment: .leading, spacing: 4) {
            TextField("Heading template (optional)", text: fileTemplateBinding)
                .textFieldStyle(.roundedBorder)
            Text("Rendered above each entry. Tokens: {{date}}, {{time}}, {{datetime}} — e.g. \u{201C}## {{datetime}}\u{201D}.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Shortcut target config

    @ViewBuilder
    private var shortcutTargetConfig: some View {
        if availableShortcuts.isEmpty {
            HStack {
                TextField("Shortcut name", text: shortcutNameBinding)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh") { loadShortcuts(force: true) }
            }
            Text(shortcutsLoaded
                 ? "No Shortcuts found (or Shortcuts access not granted). Type a name, or create one in Shortcuts.app and Refresh."
                 : "Loading your Shortcuts…")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Picker("Shortcut", selection: shortcutNameBinding) {
                Text("None").tag("")
                ForEach(availableShortcuts, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            HStack {
                Spacer()
                Button("Refresh") { loadShortcuts(force: true) }
            }
            Text("OpenWhisp runs \u{201C}shortcuts run <name>\u{201D} with the transcript on stdin. Build a Shortcut that receives text input.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Webhook target config

    @ViewBuilder
    private var webhookTargetConfig: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("https://example.com/webhook", text: webhookURLBinding)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
            Text("POSTs { text, language, appBundleID, timestamp } as JSON.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if !appState.outputTargetSettings.webhook.headers.isEmpty {
            ForEach(appState.outputTargetSettings.webhook.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack {
                    Text(key).font(.caption).fontWeight(.medium)
                    Spacer()
                    Text(value).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                    Button {
                        appState.outputTargetSettings.webhook.headers.removeValue(forKey: key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        HStack {
            TextField("Header name (e.g. Authorization)", text: $newHeaderName)
                .textFieldStyle(.roundedBorder)
            TextField("Value", text: $newHeaderValue)
                .textFieldStyle(.roundedBorder)
            Button("Add") { addWebhookHeader() }
                .disabled(newHeaderName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("Optional headers applied verbatim (e.g. an Authorization token). Content-Type: application/json is always set.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    @State private var newHeaderName = ""
    @State private var newHeaderValue = ""

    // MARK: Bindings + actions

    private var fileModeBinding: Binding<FileOutputMode> {
        Binding(get: { appState.fileOutputMode }, set: { appState.fileOutputMode = $0 })
    }
    private var fileTemplateBinding: Binding<String> {
        Binding(get: { appState.fileOutputTemplate }, set: { appState.fileOutputTemplate = $0 })
    }
    private var shortcutNameBinding: Binding<String> {
        Binding(get: { appState.shortcutOutputName }, set: { appState.shortcutOutputName = $0 })
    }
    private var webhookURLBinding: Binding<String> {
        Binding(get: { appState.webhookURL }, set: { appState.webhookURL = $0 })
    }

    private func chooseOutputFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "Choose File"
        panel.message = "Choose the file to write dictations to (created if it doesn't exist)"
        panel.nameFieldStringValue = "dictations.md"
        if !appState.fileOutputPath.isEmpty {
            let url = URL(fileURLWithPath: (appState.fileOutputPath as NSString).expandingTildeInPath)
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.fileOutputPath = url.path
    }

    private func addWebhookHeader() {
        let name = newHeaderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        appState.outputTargetSettings.webhook.headers[name] = newHeaderValue
        newHeaderName = ""
        newHeaderValue = ""
    }

    /// Enumerate the user's Shortcuts off the main thread (the CLI blocks). Runs once
    /// when the Shortcut target is shown, or on an explicit Refresh.
    private func loadShortcuts(force: Bool = false) {
        if shortcutsLoaded && !force { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let names = ShortcutOutputTarget.listShortcuts()
            DispatchQueue.main.async {
                availableShortcuts = names
                shortcutsLoaded = true
            }
        }
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

            SubtitledToggle(
                "Spoken edit commands",
                subtitle: appState.outputMode == "preview"
                    ? "Say \u{201C}scratch that\u{201D}, \u{201C}delete last word\u{201D}, \u{201C}delete last sentence\u{201D}, \u{201C}new paragraph\u{201D}, \u{201C}new line\u{201D}, or \u{201C}undo\u{201D} on its own and it edits the pending text instead of being typed. Recognized only when the whole phrase is spoken alone."
                    : "Only works with \u{201C}Preview, then insert\u{201D} above — the text is held until you release the key, so an edit can still change it.",
                isOn: $appState.voiceEditingEnabled
            )
            .disabled(appState.outputMode != "preview")
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

            SelectableRow(
                title: "AppleScript keystroke",
                subtitle: "Types the text via System Events. For apps that mangle ⌘V and direct insert — Electron, remote desktop (VNC), or non-QWERTY layouts.",
                isSelected: appState.insertionMode == "appleScript"
            ) { appState.insertionMode = "appleScript" }

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
