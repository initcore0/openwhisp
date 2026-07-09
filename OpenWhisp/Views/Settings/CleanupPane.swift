import SwiftUI

/// Cleanup: everything that transforms the transcript, in pipeline order —
/// deterministic formatting → vocabulary → AI rewrite → spoken refine.
/// Absorbs the old Smart Formatting, Custom Vocabulary, AI Post-processing
/// sections and the Refine key from Hotkey.
struct CleanupPane: View {
    @ObservedObject var appState: AppState

    // OpenAI model picker support: preset models plus a synthetic "Custom" option.
    private static let presetOpenAIModels = ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1-nano"]
    private static let customOpenAIModelTag = "__custom__"

    // Tracks whether the user explicitly chose the Custom option, so the text
    // field stays revealed even while it's empty (which would otherwise look
    // like a preset).
    @State private var openAIModelIsCustom: Bool = false

    // Substitutions table selection (for the − footer button).
    @State private var selectedSubstitutionID: UUID?

    // Draft of the OpenAI API key; committed to the Keychain on submit/focus
    // loss rather than per keystroke (each write is a blocking SecItem call).
    @State private var openAIKeyDraft: String = ""
    @State private var openAIKeyDraftSeeded = false
    @FocusState private var openAIKeyFocused: Bool

    // When the last Test result arrived, for the persistent result line.
    @State private var testResultTime: Date?

    var body: some View {
        Form {
            formattingSection
            vocabularySection
            aiModelSection
            autoCleanupSection
            refineSection
        }
        .formStyle(.grouped)
        .onAppear {
            openAIKeyDraft = appState.openAIAPIKey
            openAIKeyDraftSeeded = true
        }
        .onChange(of: appState.translationStatus) {
            testResultTime = Date()
        }
        // The Settings window is retained after close (isReleasedWhenClosed =
        // false), so focus-loss never fires when it's closed via the title-bar
        // button. Commit the pending key draft when THIS window closes — scoped
        // to the hosting window, and on every close since the retained window
        // reopens.
        .background(WindowCloseObserver(firesOnce: false) {
            commitOpenAIKey()
        })
    }

    // MARK: - Formatting

    private var formattingSection: some View {
        Section {
            Toggle("Clean up dictation automatically", isOn: $appState.smartFormattingEnabled)

            if appState.smartFormattingEnabled {
                SubtitledToggle(
                    "Apply spoken punctuation",
                    subtitle: "“new line”, “comma”, “period”",
                    isOn: $appState.spokenPunctuationEnabled
                )
                .padding(.leading, 16)
                SubtitledToggle(
                    "Remove filler words",
                    subtitle: "“um”, “uh”",
                    isOn: $appState.fillerRemovalEnabled
                )
                .padding(.leading, 16)
                SubtitledToggle(
                    "Numbers and years",
                    subtitle: "“twenty twenty six” → 2026",
                    isOn: $appState.normalizeNumbers
                )
                .padding(.leading, 16)
                SubtitledToggle(
                    "Currency",
                    subtitle: "“five dollars” → $5",
                    isOn: $appState.normalizeCurrency
                )
                .padding(.leading, 16)
                SubtitledToggle(
                    "Spoken lists",
                    subtitle: "“bullet buy milk” → - buy milk",
                    isOn: $appState.spokenListsEnabled
                )
                .padding(.leading, 16)
                SubtitledToggle(
                    "Markdown commands",
                    subtitle: "“heading intro”, “bold ship it”",
                    isOn: $appState.basicMarkdownEnabled
                )
                .padding(.leading, 16)
            }

            // File-tagging is independent of smart formatting (it's a niche dev
            // aid, not part of the baseline quality pass) — shown at the section
            // level, on only in known code editors even when toggled on.
            SubtitledToggle(
                "Enable file tagging in code editors",
                subtitle: "In Cursor and Windsurf only, turn spoken filenames into @-mentions: “main dot t s” → @main.ts, “at main” → @main. Off everywhere else, so it never touches ordinary dictation.",
                isOn: $appState.fileTaggingEnabled
            )
        } header: {
            Text("Formatting")
        } footer: {
            SettingsFootnote("Free, instant, on-device: capitalizes sentences and tidies spacing and punctuation. No internet required. Numbers, currency, lists, and markdown are off by default so they never touch ordinary prose.")
        }
    }

    // MARK: - Vocabulary

    private var vocabularySection: some View {
        Section {
            Toggle("Use custom vocabulary", isOn: $appState.customVocabularyEnabled)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bias terms")
                SettingsFootnote("Names, jargon, and acronyms Whisper usually gets wrong. Press Return to add each term.")
                TokenField(
                    tokens: $appState.vocabulary.terms,
                    placeholder: "e.g. Claude, Anthropic, kubectl, OpenWhisp",
                    isEnabled: appState.customVocabularyEnabled
                )
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Substitutions")
                SettingsFootnote("Fix recurring mishearings — applied locally after transcription.")
                substitutionsTable
            }
            .padding(.vertical, 2)
            .disabled(!appState.customVocabularyEnabled)
        } header: {
            Text("Vocabulary")
        }
    }

    /// Standard macOS table + ± footer, same pattern as Per-App Profiles.
    private var substitutionsTable: some View {
        VStack(spacing: 0) {
            Table(appState.vocabulary.substitutions, selection: $selectedSubstitutionID) {
                TableColumn("Heard") { sub in
                    TextField("heard", text: substitutionBinding(sub.id, keyPath: \.from))
                        .textFieldStyle(.plain)
                }
                TableColumn("Replace with") { sub in
                    TextField("correct", text: substitutionBinding(sub.id, keyPath: \.to))
                        .textFieldStyle(.plain)
                }
            }
            .frame(minHeight: 90, maxHeight: 160)

            HStack(spacing: 0) {
                Button {
                    let new = Vocabulary.Substitution(from: "", to: "")
                    appState.vocabulary.substitutions.append(new)
                    selectedSubstitutionID = new.id
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add substitution")

                Divider().frame(height: 14)

                Button {
                    if let id = selectedSubstitutionID {
                        appState.vocabulary.substitutions.removeAll { $0.id == id }
                        selectedSubstitutionID = nil
                    }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedSubstitutionID == nil)
                .accessibilityLabel("Remove selected substitution")

                Spacer()
            }
            .background(Color.secondary.opacity(0.05))
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }

    /// Edit-in-place binding for one substitution field, looked up by id (Table
    /// rows don't carry bindings).
    private func substitutionBinding(_ id: UUID, keyPath: WritableKeyPath<Vocabulary.Substitution, String>) -> Binding<String> {
        Binding(
            get: {
                appState.vocabulary.substitutions.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard let idx = appState.vocabulary.substitutions.firstIndex(where: { $0.id == id }) else { return }
                appState.vocabulary.substitutions[idx][keyPath: keyPath] = newValue
            }
        )
    }

    // MARK: - AI model (shared by automatic cleanup and Refine)

    private var aiModelSection: some View {
        Section {
            // Consistent, privacy-honest labels on one axis: where it runs.
            Picker("Provider", selection: $appState.llmProvider) {
                Text("On this Mac (built-in)").tag("bundled")
                Text("OpenAI (cloud)").tag("openai")
                Text("Your server (self-hosted)").tag("local")
            }

            SettingsFootnote(providerDescription)

            // Provider fields shown directly — required configuration never
            // hides behind a disclosure.
            switch appState.llmProvider {
            case "bundled": bundledLLMFields
            case "local":   localLLMFields
            default:        openAIFields
            }

            HStack {
                Button("Test") {
                    // Clicking a button needn't unfocus the key field; commit
                    // the draft so the test uses what's typed.
                    commitOpenAIKey()
                    appState.testLLMProvider()
                }
                Spacer()
                TestResultLine(
                    text: appState.translationStatus,
                    isGood: translationStatusIsGood,
                    timestamp: testResultTime
                )
            }
        } header: {
            Text("AI Model")
        } footer: {
            SettingsFootnote("One model powers both features below: the automatic pass on every dictation, and on-demand Refine.")
        }
    }

    // MARK: - Automatic cleanup

    private var autoCleanupSection: some View {
        Section {
            SubtitledToggle(
                "Improve every dictation automatically",
                subtitle: "Runs each final transcript through the AI model, with nothing to do while dictating. Only edits final text, never live chunks.",
                isOn: $appState.openAIEnhancementEnabled
            )

            Picker("Mode", selection: $appState.openAIEnhancementMode) {
                Text("Rephrase in the same language").tag("rephrase")
                // Meaningless unless translation is on — shown contextually.
                if appState.translateToEnglish || appState.openAIEnhancementMode == "improveTranslation" {
                    Text("Improve English translation").tag("improveTranslation")
                }
            }

            if !appState.translateToEnglish && appState.openAIEnhancementMode != "improveTranslation" {
                SettingsFootnote("Turn on “Translate to English” in Dictation › Language to also get a translation-improvement mode.")
            }

            if appState.openAIEnhancementMode == "improveTranslation" {
                Picker("Target language", selection: $appState.translationTargetLanguage) {
                    Text("English").tag("en")
                    Text("Russian").tag("ru")
                }
            }
        } header: {
            Text("Automatic Cleanup")
        }
    }

    private var translationStatusIsGood: Bool {
        ["Built-in model working", "Server reachable", "OpenAI key valid",
         "Local LLM reachable", "Rephrased", "Improved"].contains(appState.translationStatus)
    }

    private var providerDescription: String {
        switch appState.llmProvider {
        case "bundled":
            return "Runs a small model fully on-device — nothing leaves your Mac, no setup or server needed. The model downloads once."
        case "local":
            return "Any OpenAI-compatible server on your machine or LAN (llama.cpp llama-server, Ollama). No data leaves to the cloud."
        default:
            return "Sends the final transcript to OpenAI for cleanup. Needs an API key."
        }
    }

    private var isCustomOpenAIModel: Bool {
        openAIModelIsCustom || !Self.presetOpenAIModels.contains(appState.openAIModel)
    }

    // Drives the Picker so a free-form custom model never produces an invalid selection.
    private var openAIModelPickerSelection: Binding<String> {
        Binding(
            get: {
                isCustomOpenAIModel ? Self.customOpenAIModelTag : appState.openAIModel
            },
            set: { newValue in
                if newValue == Self.customOpenAIModelTag {
                    openAIModelIsCustom = true
                } else {
                    openAIModelIsCustom = false
                    appState.openAIModel = newValue
                }
            }
        )
    }

    @ViewBuilder private var openAIFields: some View {
        Picker("Model", selection: openAIModelPickerSelection) {
            Text("GPT-4o mini").tag("gpt-4o-mini")
            Text("GPT-4.1 mini").tag("gpt-4.1-mini")
            Text("GPT-4.1 nano").tag("gpt-4.1-nano")
            Text("Custom…").tag(Self.customOpenAIModelTag)
        }

        if isCustomOpenAIModel {
            TextField("Custom OpenAI model", text: $appState.openAIModel)
                .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 4) {
            SecureField("API key", text: $openAIKeyDraft)
                .textFieldStyle(.roundedBorder)
                .focused($openAIKeyFocused)
                .onSubmit { commitOpenAIKey() }
                .onChange(of: openAIKeyFocused) {
                    if !openAIKeyFocused { commitOpenAIKey() }
                }
                .onDisappear { commitOpenAIKey() }
            SettingsFootnote("Stored in your Keychain, never in preferences.")
        }
    }

    /// Persists the API-key draft (a changed empty draft still commits, which
    /// deletes the stored secret). Committing per keystroke would do a blocking
    /// Keychain write per character and store every partial prefix of the key.
    private func commitOpenAIKey() {
        guard openAIKeyDraftSeeded else { return }
        if openAIKeyDraft != appState.openAIAPIKey {
            appState.openAIAPIKey = openAIKeyDraft
        }
    }

    @ViewBuilder private var localLLMFields: some View {
        TextField("Server URL", text: $appState.localLLMBaseURL, prompt: Text("http://localhost:8080/v1"))
            .textFieldStyle(.roundedBorder)
        TextField("Model", text: $appState.localLLMModel, prompt: Text("Leave blank for server default"))
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var bundledLLMFields: some View {
        // Not user-fixable in Settings: the app itself was packaged without the
        // llama runtime. Say so up front instead of letting the model download
        // succeed and every use fail with a vague error.
        if !appState.bundledLLMRuntimeAvailable {
            SettingsCallout(
                .error,
                "This copy of OpenWhisp was built without the built-in AI runtime, so this provider can't run. Update to a release that includes it, or choose another provider."
            )
        }

        Picker("Built-in model", selection: $appState.bundledLLMModel) {
            ForEach(appState.bundledLLMModelsList(), id: \.id) { model in
                Text("\(model.label) · \(model.size)").tag(model.id)
            }
        }

        if appState.isLLMModelDownloading {
            HStack(spacing: 10) {
                ProgressView(value: appState.llmModelDownloadProgress ?? 0)
                    .frame(maxWidth: 240)
                Text(appState.llmModelDownloadStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if appState.llmModelDownloadFailed {
            SettingsCallout(.warning, "Download failed.", actionLabel: "Retry") {
                appState.retryLLMModelDownload()
            }
        } else if appState.bundledLLMModelInstalled && appState.bundledLLMRuntimeAvailable {
            TestResultLine(text: "Active — ready (offline)", isGood: true)
        } else {
            HStack {
                Button("Download") { appState.ensureLLMModelExists() }
                SettingsFootnote("Downloads once, then runs fully offline.")
            }
        }

        if appState.bundledLLMHasMemoryCaution {
            SettingsCallout(.warning, "You're running whisper.cpp's server engine and the built-in LLM together. On an 8 GB Mac that's tight — the Apple Speech or WhisperKit engine pairs more lightly with built-in refinement.")
        }

        #if OPENWHISP_INSTRUMENTATION
        BundledLLMDebugStatus(appState: appState)
        #endif
    }

    // MARK: - Refine

    private var refineSection: some View {
        Section {
            SubtitledToggle(
                "Refine with a spoken instruction",
                subtitle: "Nothing runs automatically — refine happens only when you ask: tap the refine key mid-dictation and speak an instruction (“make it formal”, “turn into bullet points”). On release, the AI rewrites what you dictated before the tap.",
                isOn: $appState.instructionChainEnabled
            )

            Picker("Refine key", selection: $appState.refineKey) {
                ForEach(RefineKey.allCases, id: \.rawValue) { key in
                    Text(key.label).tag(key.rawValue)
                }
            }

            // Control+Space matches either Control key, so a Control refine key
            // would fire on every dictation start; the monitor suppresses the
            // combination — tell the user instead of failing silently.
            if RefineKey.from(id: appState.refineKey).conflictsWithTrigger(appState.triggerMode) {
                SettingsCallout(
                    .warning,
                    "Control can't be the refine key while Control + Space is the push-to-talk key — pick another refine key, or switch push-to-talk to Fn."
                )
            }

            // Refine depends on the AI MODEL above (not on the automatic-cleanup
            // toggle). Offer the direct fix when there is one.
            if appState.instructionChainEnabled && !appState.llmConfigured {
                if appState.llmProvider == "bundled",
                   appState.bundledLLMRuntimeAvailable,
                   !appState.bundledLLMModelInstalled {
                    SettingsCallout(
                        .warning,
                        "Refine needs the AI model above — the built-in model isn't downloaded yet.",
                        actionLabel: "Download model"
                    ) {
                        appState.ensureLLMModelExists()
                    }
                } else {
                    SettingsCallout(
                        .warning,
                        "Refine needs the AI model above to be set up first."
                    )
                }
            }
        } header: {
            Text("Refine (On Demand)")
        } footer: {
            SettingsFootnote("No fixed phrases — say what you want in plain language, any language. Works in the Preview and Insert-at-end output modes, whether or not automatic cleanup is on.")
        }
    }
}

#if OPENWHISP_INSTRUMENTATION
/// Dev-only: shows which built-in model is selected vs. actually loaded in the
/// running llama-server. `refreshTick` forces a re-read since the status is a
/// plain computed value, not an @Published one.
private struct BundledLLMDebugStatus: View {
    @ObservedObject var appState: AppState
    @State private var debugRefreshTick: Int = 0

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "ladybug")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Runtime (debug)")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Text(appState.bundledLLMRuntimeStatus)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .id(debugRefreshTick)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                debugRefreshTick &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh runtime status")
        }
        .onAppear { debugRefreshTick &+= 1 }
    }
}
#endif
