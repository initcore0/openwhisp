import SwiftUI
import Cocoa

// MARK: - Settings View

struct SettingsView: View {
    
    @ObservedObject var appState: AppState
    
    @State private var availableMics: [AudioDevice] = []
    @State private var selectedMicIndex: Int = 0
    @State private var selectedModel: String = "base"

    // OpenAI model picker support: preset models plus a synthetic "Custom" option.
    private static let presetOpenAIModels = ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1-nano"]
    private static let customOpenAIModelTag = "__custom__"

    // Tracks whether the user explicitly chose the Custom option, so the text field
    // stays revealed even while the field is empty (which would otherwise look like a preset).
    @State private var openAIModelIsCustom: Bool = false

    // New-substitution draft fields for the vocabulary editor.
    @State private var newSubFrom: String = ""
    @State private var newSubTo: String = ""

    private var isCustomOpenAIModel: Bool {
        openAIModelIsCustom || !SettingsView.presetOpenAIModels.contains(appState.openAIModel)
    }

    // Drives the Picker so a free-form custom model never produces an invalid selection.
    private var openAIModelPickerSelection: Binding<String> {
        Binding(
            get: {
                isCustomOpenAIModel ? SettingsView.customOpenAIModelTag : appState.openAIModel
            },
            set: { newValue in
                if newValue == SettingsView.customOpenAIModelTag {
                    openAIModelIsCustom = true
                } else {
                    openAIModelIsCustom = false
                    appState.openAIModel = newValue
                }
            }
        )
    }
    
    var body: some View {
        TabView {
            basicTab
                .tabItem { Label("Basic", systemImage: "slider.horizontal.3") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .onAppear {
            selectedModel = appState.modelName
            refreshDevices()
        }
        .frame(minWidth: 640, minHeight: 600)
    }

    /// What 95% of users ever need: how to talk to it and how text comes out.
    private var basicTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                generalSection
                hotkeySection
                microphoneSection
                languageSection
                qualitySection
                formattingSection
                vocabularySection
                translationSection
                outputSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Power-user / developer controls: engine, raw model + paths, live-chunk
    /// plumbing, whisper.cpp backend, permissions, diagnostics.
    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                engineSection
                modelSection
                liveChunkAdvancedSection
                whisperSection
                permissionsSection
                statusSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var generalSection: some View {
        settingsSection("General") {
            Toggle("Launch VoiceNote at login", isOn: $appState.launchAtLogin)

            Text("Automatically start VoiceNote after you log in or reboot. If macOS asks you to approve it, enable VoiceNote under System Settings > General > Login Items.")
                .font(.caption)
                .foregroundColor(.secondary)

            if LaunchAtLogin.requiresApproval {
                Button("Open Login Items Settings") {
                    LaunchAtLogin.openLoginItemsSettings()
                }
            }
        }
    }

    // Friendly quality tiers mapped to whisper models. "Custom" appears only
    // when the active model isn't one of the tiers (e.g. set via Advanced).
    private static let qualityTiers: [(label: String, model: String)] = [
        ("Faster — quick notes", "base"),
        ("Balanced — recommended", "small"),
        ("Best — most accurate, slowest", "large-v3-turbo")
    ]
    private static let customQualityTag = "__custom_model__"

    private var qualityPickerSelection: Binding<String> {
        Binding(
            get: {
                Self.qualityTiers.first(where: { $0.model == appState.modelName })?.model
                    ?? Self.customQualityTag
            },
            set: { newValue in
                guard newValue != Self.customQualityTag else { return }
                appState.modelName = newValue
                selectedModel = newValue
                appState.ensureModelExists()
            }
        )
    }

    private var qualitySection: some View {
        settingsSection("Quality") {
            Picker("Transcription Quality", selection: qualityPickerSelection) {
                ForEach(Self.qualityTiers, id: \.model) { tier in
                    Text(tier.label).tag(tier.model)
                }
                // Only shows when a non-tier model is active (chosen in Advanced).
                if Self.qualityTiers.allSatisfy({ $0.model != appState.modelName }) {
                    Text("Custom (\(appState.modelName))").tag(Self.customQualityTag)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

            HStack(spacing: 10) {
                if appState.isModelDownloading {
                    ProgressView().controlSize(.small)
                }
                Text(appState.modelDownloadStatus)
                    .font(.caption)
                    .foregroundColor(appState.isModelDownloading ? .orange : .secondary)
            }

            Text("Higher quality is more accurate but slower and uses more memory. Models download automatically on first use and run entirely on your Mac. For specific models or paths, see Advanced.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var engineSection: some View {
        settingsSection("Engine") {
            Picker("Transcription Engine", selection: $appState.transcriptionEngine) {
                Text("Whisper Local").tag("whisper")
                Text("Apple Speech Streaming").tag("appleSpeech")
            }
            
            Text("Apple Speech gives native streaming partials. Whisper remains available for local file-based transcription and higher-quality model control.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var modelSection: some View {
        settingsSection("Model") {
            Picker("Whisper Model", selection: $selectedModel) {
                ForEach(appState.availableModelsList(), id: \.name) { model in
                    Text("\(model.label) (\(model.size))").tag(model.name)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .onChange(of: selectedModel) {
                appState.modelName = selectedModel
                appState.ensureModelExists()
            }
            
            Text("Use multilingual Whisper models for Russian or Whisper translation. English-only models are fastest for English dictation.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 10) {
                if appState.isModelDownloading {
                    ProgressView()
                        .controlSize(.small)
                }
                
                Text(appState.modelDownloadStatus)
                    .font(.caption)
                    .foregroundColor(appState.isModelDownloading ? .orange : .secondary)
            }
            
            TextField("Model Path", text: $appState.modelPath)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Download / Check Model") {
                    appState.ensureModelExists()
                }
                
                Button("Reveal Models Folder") {
                    appState.revealModelsFolder()
                }
                
                Button("Browse...") {
                    browseModelPath()
                }
            }
        }
    }
    
    private var microphoneSection: some View {
        settingsSection("Microphone") {
            Picker("Input Device", selection: $selectedMicIndex) {
                ForEach(availableMics.indices, id: \.self) { index in
                    Text(availableMics[index].name).tag(index)
                }
            }
            .onChange(of: selectedMicIndex) {
                if selectedMicIndex < availableMics.count {
                    appState.microphoneID = availableMics[selectedMicIndex].uid
                }
            }
            
            Button("Refresh Devices") {
                refreshDevices()
            }
        }
    }
    
    private var languageSection: some View {
        settingsSection("Language") {
            Picker("Transcription Language", selection: $appState.language) {
                Text("Auto Detect").tag("auto")
                Text("English - Whisper translate to English").tag("en")
                Text("Russian").tag("ru")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Japanese").tag("ja")
                Text("Chinese").tag("zh")
                Text("Korean").tag("ko")
                Text("Arabic").tag("ar")
            }

            Text("Whisper can translate non-English speech into English when English is selected. Auto Detect transcribes in the spoken language.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var formattingSection: some View {
        settingsSection("Smart Formatting") {
            Toggle("Clean up dictation automatically", isOn: $appState.smartFormattingEnabled)

            if appState.smartFormattingEnabled {
                Toggle("Apply spoken punctuation (\"new line\", \"comma\", \"period\")", isOn: $appState.spokenPunctuationEnabled)
                Toggle("Remove filler words (\"um\", \"uh\")", isOn: $appState.fillerRemovalEnabled)
            }

            Text("Runs entirely on your Mac — no internet required. Capitalizes sentences, tidies spacing and punctuation, and optionally applies spoken punctuation and removes fillers.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // Comma-separated editing of the bias-terms list.
    private var vocabularyTermsText: Binding<String> {
        Binding(
            get: { appState.vocabulary.terms.joined(separator: ", ") },
            set: { newValue in
                let terms = newValue
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                appState.vocabulary.terms = terms
            }
        )
    }

    private var vocabularySection: some View {
        settingsSection("Custom Vocabulary") {
            Toggle("Use custom vocabulary", isOn: $appState.customVocabularyEnabled)

            Text("Bias terms (names, jargon, acronyms) help Whisper recognize words it usually gets wrong. Comma-separated.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("e.g. Claude, Anthropic, kubectl, VoiceNote", text: vocabularyTermsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .disabled(!appState.customVocabularyEnabled)

            Divider()

            Text("Replacements fix recurring mishearings (\"heard\" → \"correct\"). Applied locally after transcription.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(appState.vocabulary.substitutions) { sub in
                HStack {
                    Text(sub.from).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    Text(sub.to).frame(maxWidth: .infinity, alignment: .leading)
                    Button(role: .destructive) {
                        appState.vocabulary.substitutions.removeAll { $0.id == sub.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("heard", text: $newSubFrom)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundColor(.secondary)
                TextField("correct", text: $newSubTo)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let from = newSubFrom.trimmingCharacters(in: .whitespacesAndNewlines)
                    let to = newSubTo.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !from.isEmpty, !to.isEmpty else { return }
                    appState.vocabulary.substitutions.append(.init(from: from, to: to))
                    newSubFrom = ""
                    newSubTo = ""
                }
                .disabled(newSubFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newSubTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(!appState.customVocabularyEnabled)
        }
    }

    private var translationSection: some View {
        settingsSection("AI Post-processing") {
            Toggle("Clean up text with AI after transcription", isOn: $appState.openAIEnhancementEnabled)

            Picker("Provider", selection: $appState.llmProvider) {
                Text("OpenAI (cloud)").tag("openai")
                Text("Local server (private)").tag("local")
            }

            Picker("Mode", selection: $appState.openAIEnhancementMode) {
                Text("Rephrase in same language").tag("rephrase")
                Text("Improve Whisper translation").tag("improveTranslation")
            }

            if appState.openAIEnhancementMode == "improveTranslation" {
                Picker("Translation Language", selection: $appState.translationTargetLanguage) {
                    Text("English").tag("en")
                    Text("Russian").tag("ru")
                }
            }

            if appState.llmProvider == "local" {
                localLLMFields
            } else {
                openAIFields
            }

            HStack {
                Button(appState.llmProvider == "local" ? "Test Connection" : "Validate OpenAI Key") {
                    appState.validateOpenAIKey()
                }

                Spacer()

                Text(appState.translationStatus)
                    .foregroundColor(translationStatusIsGood ? .green : .secondary)
            }

            Divider()

            Toggle("Voice commands (say an instruction at the end)", isOn: $appState.voiceCommandsEnabled)

            if appState.voiceCommandsEnabled {
                TextField("Wake word (optional, e.g. \"voice note\")", text: $appState.voiceCommandWakeWord)
                    .textFieldStyle(.roundedBorder)
                Text("End a dictation with an instruction and it's applied to the rest: \"…ship it tomorrow. Make this formal.\" Recognized commands (make this/it…, rewrite/translate/summarize this…) are stripped and the text is transformed by the AI. Works in Final paste and Preview modes; needs an AI provider above.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(appState.llmProvider == "local"
                 ? "Local server keeps everything on your machine / LAN — no data leaves to the cloud. Any OpenAI-compatible server works (llama.cpp llama-server, Ollama). Only edits final text, never live chunks."
                 : "Whisper handles default translation locally through the language picker. OpenAI is optional and only edits final text, never live chunks.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var translationStatusIsGood: Bool {
        ["OpenAI key valid", "Local LLM reachable", "Rephrased", "Improved"].contains(appState.translationStatus)
    }

    @ViewBuilder private var openAIFields: some View {
        Picker("OpenAI Model", selection: openAIModelPickerSelection) {
            Text("GPT-4o mini").tag("gpt-4o-mini")
            Text("GPT-4.1 mini").tag("gpt-4.1-mini")
            Text("GPT-4.1 nano").tag("gpt-4.1-nano")
            Text("Custom…").tag(SettingsView.customOpenAIModelTag)
        }

        if isCustomOpenAIModel {
            TextField("Custom OpenAI model", text: $appState.openAIModel)
                .textFieldStyle(.roundedBorder)
        }

        SecureField("OpenAI API Key", text: $appState.openAIAPIKey)
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var localLLMFields: some View {
        TextField("Server URL (e.g. http://192.168.68.52:8080/v1)", text: $appState.localLLMBaseURL)
            .textFieldStyle(.roundedBorder)
        TextField("Model (leave blank to use the server default)", text: $appState.localLLMModel)
            .textFieldStyle(.roundedBorder)
    }
    
    private var hotkeySection: some View {
        settingsSection("Hotkey") {
            Picker("Push-to-talk", selection: $appState.triggerMode) {
                Text("Control + Space").tag("controlSpace")
                Text("Fn / Globe (experimental)").tag("fn")
            }
            
            Text(appState.hotkeyHelpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var outputSection: some View {
        settingsSection("Text Output") {
            Picker("Insertion Method", selection: $appState.insertionMode) {
                Text("Automatic (keep clipboard)").tag("auto")
                Text("Direct insert only").tag("directAX")
                Text("Paste (Cmd+V)").tag("paste")
            }

            Text("Automatic inserts text directly into the focused app (preserving your clipboard) and falls back to paste when an app doesn't support it.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Output Mode", selection: $appState.outputMode) {
                Text("Final paste only").tag("finalOnly")
                Text("Live chunks (experimental)").tag("liveChunks")
                Text("Preview & polish").tag("preview")
            }

            Toggle("Show overlay while recording", isOn: $appState.showOverlay)
            Toggle("Add trailing space after paste", isOn: $appState.addTrailingSpace)
            Toggle("Restore clipboard after paste", isOn: $appState.restoreClipboard)
                .disabled(appState.insertionMode == "directAX")

            Text("Final paste inserts everything at once when you finish. Live chunks paste as you speak. Preview & polish shows the transcript in the overlay while you talk, then inserts it once when you stop — cleaned up (and rephrased, if OpenAI is enabled) before pasting.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Clipboard restore only applies to the paste method — and reads your clipboard, which may trigger macOS privacy prompts. With Automatic or Direct insert, your clipboard is left untouched.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var liveChunkAdvancedSection: some View {
        settingsSection("Live Chunks (Advanced)") {
            Picker("Live Chunk Duration", selection: $appState.liveChunkDuration) {
                Text("1.0 sec - fastest").tag(1.0)
                Text("1.5 sec").tag(1.5)
                Text("2.0 sec - balanced").tag(2.0)
                Text("3.0 sec - accurate").tag(3.0)
            }
            .disabled(appState.pauseBasedLiveChunksEnabled)

            Toggle("Pause-based live chunks", isOn: $appState.pauseBasedLiveChunksEnabled)
                .onChange(of: appState.pauseBasedLiveChunksEnabled) {
                    if appState.pauseBasedLiveChunksEnabled {
                        appState.outputMode = "liveChunks"
                    }
                }

            Text("Only applies to the Live chunks output mode. Pause-based chunks finalize when speech stops; timer chunks use the selected duration. Chunks transcribe up to two at a time and paste in order.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var permissionsSection: some View {
        settingsSection("Permissions") {
            permissionRow("Microphone", value: appState.microphonePermissionLabel)
            permissionRow("Speech Recognition", value: appState.speechPermissionLabel)
            permissionRow("Accessibility", value: appState.accessibilityPermissionLabel)
            permissionRow("Input Monitoring", value: appState.inputMonitoringPermissionLabel)
            
            HStack {
                Button("Request Accessibility") { appState.requestAccessibilityPermission() }
                Button("Open Accessibility") { appState.openAccessibilitySettings() }
                Button("Open Input Monitoring") { appState.openInputMonitoringSettings() }
                Button("Retry Hotkey") { appState.retryHotkeyMonitor() }
            }
            
            Text("Running app: \(appState.runningBundlePath)")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            
            Button("Reveal Running App") {
                appState.revealRunningApp()
            }
        }
    }
    
    private var whisperSection: some View {
        settingsSection("whisper.cpp") {
            Picker("Whisper Backend", selection: $appState.whisperBackend) {
                Text("CLI - reliable").tag("cli")
                Text("Server API - warm model").tag("serverAPI")
            }
            
            HStack {
                Text("Server API")
                Spacer()
                Text(appState.whisperWorkerStatus)
                    .foregroundColor(appState.whisperWorkerStatus.hasPrefix("Loaded") ? .green : .secondary)
            }
            
            Text("CLI runs whisper-cli per recording. Server API starts whisper-server and sends audio over HTTP; failures are shown explicitly and do not silently switch back to CLI.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Log: \(appState.whisperLogPath)")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            
            TextField("Binary Path", text: $appState.whisperBinaryPath)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Browse...") {
                    browseWhisperBinary()
                }
                
                Button("Verify") {
                    verifySetup()
                }
                
                Button("Stop Server API") {
                    appState.stopWhisperServer()
                }
                
                Button("Reveal Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appState.whisperLogPath)])
                }
            }
        }
    }
    
    private var statusSection: some View {
        settingsSection("Status") {
            HStack {
                Text("Status:")
                Spacer()
                Text(appState.statusMessage)
                    .foregroundColor(statusColor)
                    .frame(width: 180, alignment: .trailing)
            }
            
            if let error = appState.error, !error.isEmpty {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            if let last = appState.lastTranscription, !last.isEmpty {
                Text("Last: \"\(last.prefix(80))\(last.count > 80 ? "..." : "")\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
    
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func permissionRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(value == "Granted" ? .green : .orange)
        }
    }
    
    private func refreshDevices() {
        availableMics = AudioDevice.availableInputs()
        if !availableMics.isEmpty {
            if !appState.microphoneID.isEmpty {
                if let index = availableMics.firstIndex(where: { $0.uid == appState.microphoneID }) {
                    selectedMicIndex = index
                }
            }
        }
    }
    
    private func browseModelPath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.modelPath = url.path
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
