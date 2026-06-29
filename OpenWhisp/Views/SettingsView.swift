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

    // New-profile draft fields.
    @State private var newProfileBundleID: String = ""
    @State private var newProfileName: String = ""
    @State private var profileAddMessage: String = ""

    // Config import/export feedback.
    @State private var configMessage: String = ""
    // Built-in config packs (loaded from the app bundle on appear).
    @State private var configPacks: [ConfigPack] = []

    // MARK: - Backend awareness
    //
    // The active transcription backend decides which settings are even meaningful.
    // We HIDE irrelevant sections (state is preserved, so switching back restores
    // it) rather than greying them out, to keep the UI honest and uncluttered.

    private var isWhisperCpp: Bool { appState.transcriptionEngine == "whisper" }
    private var isWhisperKit: Bool { appState.transcriptionEngine == "whisperKit" }
    private var isAppleSpeech: Bool { appState.transcriptionEngine == "appleSpeech" }

    /// whisper.cpp uses GGML models + its own server/CLI backend. WhisperKit and
    /// Apple Speech do not.
    private var usesWhisperModels: Bool { isWhisperCpp }

    /// Output-mode options available for the active backend. WhisperKit streams via
    /// its own pipeline, so it offers Preview / Paste-at-end but NOT "Type live".
    private var outputModeOptions: [(tag: String, label: String)] {
        var opts: [(String, String)] = [
            ("preview", "Preview, then paste (recommended)"),
            ("finalOnly", "Paste at end, no preview"),
        ]
        if !isWhisperKit {
            opts.append(("liveChunks", "Type live as you speak"))
        }
        return opts
    }

    /// Help text under Output Mode, tailored to the active backend.
    private var outputModeHelp: String {
        var lines = [
            "How your words reach the app while you hold the hotkey:",
            "• Preview, then paste — text streams into the on‑screen overlay as you speak; nothing is inserted until you release, then it's pasted once (cleaned up, and rephrased if AI is on).",
            "• Paste at end — like Preview, but without the live overlay text; inserts once on release.",
        ]
        if isWhisperKit {
            lines.append("WhisperKit streams partials in real time with built-in silence skipping; “Type live” isn't used with it.")
        } else {
            lines.append("• Type live — each phrase is pasted into the app as you speak.")
        }
        return lines.joined(separator: "\n")
    }

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
                qualitySection            // backend-aware (tiers / WhisperKit picker / info)
                translationSection
                outputSection
                appearanceSection
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
                formattingSection
                vocabularySection
                engineSection
                if usesWhisperModels { modelSection }          // GGML model + path (whisper.cpp)
                if isWhisperCpp { liveChunkAdvancedSection }    // live-chunk tuning (whisper.cpp)
                profilesSection
                scriptSection
                historySection
                backupSection
                if isWhisperCpp { whisperSection }              // CLI/server backend (whisper.cpp)
                permissionsSection
                statusSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var generalSection: some View {
        settingsSection("General") {
            Toggle("Launch OpenWhisp at login", isOn: $appState.launchAtLogin)

            Text("Automatically start OpenWhisp after you log in or reboot. If macOS asks you to approve it, enable OpenWhisp under System Settings > General > Login Items.")
                .font(.caption)
                .foregroundColor(.secondary)

            if appState.launchAtLoginService.requiresApproval {
                Button("Open Login Items Settings") {
                    appState.launchAtLoginService.openSettings()
                }
            }
        }
    }

    // Friendly quality tiers mapped to whisper models. "Custom" appears only
    // when the active model isn't one of the tiers (e.g. set via Advanced).
    private static let qualityTiers: [(label: String, model: String)] = [
        ("Faster — quick notes", "base"),
        ("Balanced — good all-rounder", "small"),
        // large-v3-turbo is the recommended tier: near large-v3 accuracy at
        // ~2.3–4× the speed (it's faster than large-v3, not slower). See
        // docs/ASR_ALTERNATIVES.md.
        ("Best — most accurate, recommended", "large-v3-turbo")
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

    /// Shared download status row used by both the Quality and Model sections.
    /// Shows a determinate ProgressView when a total size is known, falls back to
    /// an indeterminate spinner otherwise, and offers a Retry button on failure.
    @ViewBuilder
    private var modelDownloadStatusView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if appState.isModelDownloading {
                    if let progress = appState.modelDownloadProgress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 240)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }

                Text(appState.modelDownloadStatus)
                    .font(.caption)
                    .foregroundColor(downloadStatusColor)
            }

            if appState.modelDownloadFailed && !appState.isModelDownloading {
                Button("Retry Download") {
                    appState.retryModelDownload()
                }
            }
        }
    }

    private var downloadStatusColor: Color {
        if appState.modelDownloadFailed && !appState.isModelDownloading { return .red }
        return appState.isModelDownloading ? .orange : .secondary
    }

    @ViewBuilder
    private var qualitySection: some View {
        if isWhisperKit {
            whisperKitModelSection
        } else if isAppleSpeech {
            appleSpeechModelSection
        } else {
            whisperCppQualitySection
        }
    }

    /// whisper.cpp: friendly GGML quality tiers.
    private var whisperCppQualitySection: some View {
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

            modelDownloadStatusView

            Text("“Best” (Large v3 Turbo) is the recommended choice — near top accuracy and still fast on Apple Silicon, with full multilingual + translate. Larger models use more memory and download on first use; everything runs entirely on your Mac. For specific models or paths, see Advanced.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// WhisperKit: pick from the locally-staged CoreML models (only loadable ones).
    private var whisperKitModelSection: some View {
        settingsSection("Quality") {
            let staged = WhisperKitModelCatalog.stagedModels()
            if staged.isEmpty {
                Text("No WhisperKit models are installed yet. Stage one under Application Support → OpenWhisp/whisperkit-models (see docs/WHISPERKIT_PILOT.md).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("WhisperKit Model", selection: $appState.whisperKitModel) {
                    ForEach(staged, id: \.self) { model in
                        Text(WhisperKitModelCatalog.displayInfo(for: model).label).tag(model)
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)

                if let hint = WhisperKitModelCatalog.displayInfo(for: appState.whisperKitModel).hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text("WhisperKit runs Apple-native CoreML models on the GPU/Neural Engine. Models are stored locally; only installed models are shown. Russian needs a multilingual model (Small).")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Apple Speech: no model choice — it uses the system recognizer.
    private var appleSpeechModelSection: some View {
        settingsSection("Quality") {
            Text("Apple Speech uses the built-in macOS dictation model for the selected language. There's no model to choose or download — accuracy and language support come from the system.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var engineSection: some View {
        settingsSection("Engine") {
            Picker("Transcription Engine", selection: $appState.transcriptionEngine) {
                Text("WhisperKit (CoreML)").tag("whisperKit")
                Text("Whisper Local (whisper.cpp)").tag("whisper")
                Text("Apple Speech Streaming").tag("appleSpeech")
            }

            Text("WhisperKit (CoreML/ANE) is the default — in a live mode (Preview or Type-live) it streams partials in real time with built-in silence skipping; in Paste-at-end mode it transcribes the whole recording. Whisper Local (whisper.cpp) and Apple Speech (native streaming partials) are the alternatives. WhisperKit requires a build that includes it (the default; a lean WHISPERKIT=0 build falls back to whisper.cpp and reports WhisperKit as unavailable — see docs/WHISPERKIT_PILOT.md).")
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
            
            modelDownloadStatusView

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

            Toggle("Auto‑boost quiet microphone", isOn: $appState.autoGainEnabled)
            Text("Automatically raises the volume of soft or low‑output mics before transcription, so quiet speech is recognized better. Runs locally and won't distort loud audio. Turn off if your mic is already loud or you hear it picking up background noise.")
                .font(.caption)
                .foregroundColor(.secondary)
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

            TextField("e.g. Claude, Anthropic, kubectl, OpenWhisp", text: vocabularyTermsText, axis: .vertical)
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
            // Always visible: whether AI runs at all, and where text goes (privacy).
            Toggle("Clean up text with AI after transcription", isOn: $appState.openAIEnhancementEnabled)

            Picker("Provider", selection: $appState.llmProvider) {
                Text("OpenAI (cloud)").tag("openai")
                Text("Local server (private)").tag("local")
            }

            Text(appState.llmProvider == "local"
                 ? "Local server keeps everything on your machine / LAN — no data leaves to the cloud. Any OpenAI-compatible server works (llama.cpp llama-server, Ollama). Only edits final text, never live chunks."
                 : "Whisper handles default translation locally through the language picker. OpenAI is optional and only edits final text, never live chunks.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Provider details (mode, key/model, connection test) — collapsed.
            DisclosureGroup("Provider details") {
                VStack(alignment: .leading, spacing: 10) {
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
                }
                .padding(.top, 4)
            }

            Divider()

            Toggle("Refine with a follow-up instruction (double-tap)", isOn: $appState.instructionChainEnabled)

            Text("""
            Dictate, release, then quickly DOUBLE-TAP the hotkey (release and press \
            again) and speak an instruction — the AI applies it to what you just said. \
            For example: dictate "hello team, I'm on vacation and all is great", \
            double-tap, then say "make it a Telegram post". It's a deliberate gesture \
            you can do by feel; no need to watch the screen. The double-tap is an \
            explicit command, so it overrides the rephrase/translate setting above. No \
            fixed phrases — say what you want in plain language (any language). Needs an \
            AI provider above; works in Preview and Paste-at-end modes.
            """)
                .font(.caption)
                .foregroundColor(.secondary)

            if appState.instructionChainEnabled && !appState.llmConfigured {
                Text("Set up an AI provider above to use follow-up instructions.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
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
        TextField("Server URL (e.g. http://localhost:8080/v1)", text: $appState.localLLMBaseURL)
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
                ForEach(outputModeOptions, id: \.tag) { opt in
                    Text(opt.label).tag(opt.tag)
                }
            }

            Toggle("Add trailing space after paste", isOn: $appState.addTrailingSpace)
            Toggle("Restore clipboard after paste", isOn: $appState.restoreClipboard)
                .disabled(appState.insertionMode == "directAX")

            Text(outputModeHelp)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Clipboard restore only applies to the paste method — and reads your clipboard, which may trigger macOS privacy prompts. With Automatic or Direct insert, your clipboard is left untouched.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Styles available to pick this build. Grows as later phases land (orb).
    private var availableIndicatorStyles: [VoiceIndicatorStyle] { [.bars, .waveform] }

    private var appearanceSection: some View {
        settingsSection("Appearance") {
            Toggle("Show overlay while recording", isOn: $appState.showOverlay)

            if appState.showOverlay {
                Picker("Voice indicator", selection: $appState.voiceIndicatorStyle) {
                    ForEach(availableIndicatorStyles) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .frame(maxWidth: 360, alignment: .leading)

                Text(appState.voiceIndicatorStyle.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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

            Text("Input Monitoring (the “OpenWhisp would like to receive keystrokes” prompt) lets OpenWhisp detect your push-to-talk key. Keystrokes are only checked against your chosen hotkey — they are never logged, stored, or sent anywhere. If you denied it, enable OpenWhisp under Input Monitoring above and click Retry Hotkey.")
                .font(.caption)
                .foregroundColor(.secondary)

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
    
    private var profilesSection: some View {
        settingsSection("Per-App Modes") {
            Toggle("Apply per-app profiles", isOn: $appState.perAppModesEnabled)

            Text("When you start dictation, OpenWhisp can apply overrides based on the app you're typing into. Add the current app with the button below, then set its overrides.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach($appState.profiles) { $profile in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(profile.displayName.isEmpty ? profile.appBundleID : profile.displayName)
                            .fontWeight(.medium)
                        Spacer()
                        Button(role: .destructive) {
                            appState.profiles.removeAll { $0.id == profile.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    Text(profile.appBundleID).font(.caption).foregroundColor(.secondary)
                    HStack {
                        Picker("Language", selection: profileLanguageBinding($profile)) {
                            Text("Inherit").tag("__inherit__")
                            Text("Auto").tag("auto")
                            Text("English").tag("en")
                            Text("Russian").tag("ru")
                        }
                        Picker("Output", selection: profileOutputBinding($profile)) {
                            Text("Inherit").tag("__inherit__")
                            Text("Preview").tag("preview")
                            Text("Final").tag("finalOnly")
                            Text("Live").tag("liveChunks")
                        }
                    }
                    Picker("AI cleanup", selection: profileAIBinding($profile)) {
                        Text("Inherit").tag("__inherit__")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }

            HStack {
                Button("Choose App…") {
                    chooseAppForProfile()
                }
                Button("Add Last‑Used App") {
                    addProfileForFrontmostApp()
                }
                Spacer()
            }

            if !profileAddMessage.isEmpty {
                Text(profileAddMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var historySection: some View {
        settingsSection("History") {
            Toggle("Keep transcription history", isOn: $appState.historyEnabled)

            if appState.history.isEmpty {
                Text("No transcriptions yet. Recent dictations will appear here (stored locally).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(appState.history.prefix(15)) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                                .font(.system(size: 12))
                                .lineLimit(2)
                            Text(historySubtitle(entry))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.copyHistoryEntry(entry)
                        } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                    Divider()
                }
                Button("Clear History", role: .destructive) {
                    appState.clearHistory()
                }
            }
        }
    }

    private func historySubtitle(_ entry: TranscriptionEntry) -> String {
        let when = entry.date.formatted(date: .abbreviated, time: .shortened)
        if let app = entry.appName, !app.isEmpty { return "\(app) · \(when)" }
        return when
    }

    private var scriptSection: some View {
        settingsSection("Script Post‑processor") {
            Toggle("Run my script on the final transcript", isOn: $appState.scriptPostProcessorEnabled)

            Text("Advanced: pipe the final transcript through an executable you choose (your text on stdin, the result on stdout). Runs only at the end, with a ~2s timeout, and falls back to the original text on any error — but it does run code you point it at, so only use a script you trust.")
                .font(.caption)
                .foregroundColor(.secondary)

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
                    Text(warning).font(.caption).foregroundColor(.orange)
                }
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
        panel.message = "Choose an executable script to post‑process the final transcript"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.scriptPostProcessorPath = url.path
    }

    private var backupSection: some View {
        settingsSection("Backup & Sharing") {
            Text("Export your per‑app profiles, vocabulary, and command prompts to a JSON file you can back up, edit, or share. Import replaces only the sections present in the file.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("Export Config…") { exportConfig() }
                Button("Import Config…") { importConfig() }
                Spacer()
            }

            if !configPacks.isEmpty {
                Divider()
                Text("Packs")
                    .font(.subheadline).fontWeight(.medium)
                Text("One‑click config bundles. Applying a pack changes only the sections it contains.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(configPacks) { pack in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name).fontWeight(.medium)
                            Text(pack.packDescription)
                                .font(.caption).foregroundColor(.secondary)
                            Text("Applies: \(pack.contentsSummary)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Apply") {
                            let summary = appState.applyPack(pack)
                            configMessage = "Applied “\(pack.name)” (\(summary))."
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }

            if !configMessage.isEmpty {
                Text(configMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if configPacks.isEmpty {
                configPacks = appState.bundledConfigPacks()
            }
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "openwhisp-config.json"
        panel.prompt = "Export"
        panel.message = "Save your OpenWhisp config (profiles, vocabulary, prompts)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportConfig(to: url)
            configMessage = "Exported \(appState.exportConfig().summary) to \(url.lastPathComponent)."
        } catch {
            configMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Choose an OpenWhisp config file to import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try appState.importConfig(from: url)
            configMessage = "Imported \(summary)."
        } catch let ConfigBundle.DecodeError.unsupportedVersion(found, supported) {
            configMessage = "This file needs a newer OpenWhisp (config v\(found); this app supports up to v\(supported))."
        } catch ConfigBundle.DecodeError.malformed {
            configMessage = "Couldn't read that file — it doesn't look like an OpenWhisp config."
        } catch {
            configMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // Inherit-aware bindings mapping the synthetic "__inherit__" tag to nil.
    private func profileLanguageBinding(_ profile: Binding<AppProfile>) -> Binding<String> {
        Binding(get: { profile.wrappedValue.language ?? "__inherit__" },
                set: { profile.wrappedValue.language = $0 == "__inherit__" ? nil : $0 })
    }
    private func profileOutputBinding(_ profile: Binding<AppProfile>) -> Binding<String> {
        Binding(get: { profile.wrappedValue.outputMode ?? "__inherit__" },
                set: { profile.wrappedValue.outputMode = $0 == "__inherit__" ? nil : $0 })
    }
    private func profileAIBinding(_ profile: Binding<AppProfile>) -> Binding<String> {
        Binding(
            get: {
                guard let v = profile.wrappedValue.aiCleanupEnabled else { return "__inherit__" }
                return v ? "on" : "off"
            },
            set: {
                switch $0 {
                case "on": profile.wrappedValue.aiCleanupEnabled = true
                case "off": profile.wrappedValue.aiCleanupEnabled = false
                default: profile.wrappedValue.aiCleanupEnabled = nil
                }
            }
        )
    }

    /// Pick any app from /Applications and add a profile for it. Reliable way to
    /// target a specific app (vs. guessing "frontmost", which is OpenWhisp itself
    /// while Settings is open).
    private func chooseAppForProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Profile"
        panel.message = "Choose an app to create a per‑app profile for"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else {
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        addProfile(bundleID: bid, name: name)
    }

    /// Convenience: add a profile for the most recently used regular app (the one
    /// you were in before opening Settings).
    private func addProfileForFrontmostApp() {
        let candidate = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !$0.isActive
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard let app = candidate, let bid = app.bundleIdentifier else {
            profileAddMessage = "Couldn't determine the last‑used app. Use “Choose App…” instead."
            return
        }
        addProfile(bundleID: bid, name: app.localizedName ?? bid)
    }

    /// Shared add path with explicit feedback (instead of a silent no‑op).
    private func addProfile(bundleID: String, name: String) {
        if appState.profiles.contains(where: { $0.appBundleID == bundleID }) {
            profileAddMessage = "A profile for “\(name)” already exists."
            return
        }
        appState.profiles.append(AppProfile(appBundleID: bundleID, displayName: name))
        profileAddMessage = "Added profile for “\(name)”."
    }

    private var statusSection: some View {
        settingsSection("Status") {
            // Privacy indicator — makes "local-first" visible at a glance.
            HStack(spacing: 6) {
                Image(systemName: appState.sendsTextToCloud ? "wifi" : "lock.shield.fill")
                    .foregroundColor(appState.sendsTextToCloud ? .orange : .green)
                Text(appState.privacyStatusText)
                    .font(.callout)
                    .foregroundColor(appState.sendsTextToCloud ? .orange : .green)
                Spacer()
            }

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
