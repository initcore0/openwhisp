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

    // FROZEN display order for the substitutions table (MAK-41). The frequency sort
    // key includes `from`, so recomputing it every render would re-sort the list
    // under the cursor while you type into "Heard" (row jumps, focus lost), and a
    // usageCount bump from a dictation-while-Settings-open would shuffle rows too.
    // We snapshot the ORDER (ids) once on appear + on explicit refresh; in-place
    // edits, the star toggle, and "used N×" still read live from appState.vocabulary.
    @State private var displayedOrder: [UUID] = []

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

            // Bias terms steer the transcription engine itself, so they only
            // exist on engines that can act on them — whisper.cpp (all paths)
            // and Parakeet (batch paths, MAK-71). Offering the field on an
            // engine that discards it is the #175 bug again: the user types
            // terms, nothing happens, nothing says why. Show it disabled with
            // the reason rather than hiding it, so the capability stays
            // discoverable. Substitutions below are a local post-pass and keep
            // working on every engine.
            if EngineCapabilities.supportsVocabularyBiasing(transcriptionEngine: appState.transcriptionEngine) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bias terms")
                    // Say which paths actually honor the terms. Parakeet biases
                    // finished audio (files/meetings) but not live dictation, and
                    // a user typing names in deserves to know that up front rather
                    // than infer it from terms that "sometimes work".
                    if EngineCapabilities.vocabularySupport(
                        transcriptionEngine: appState.transcriptionEngine) == .batchOnly {
                        SettingsFootnote("Names, jargon, and acronyms the engine usually gets wrong. Applied to files, meetings, and re-transcribes — not to live dictation on this engine. Press Return to add each term.")
                    } else {
                        SettingsFootnote("Names, jargon, and acronyms the engine usually gets wrong. Press Return to add each term.")
                    }
                    TokenField(
                        tokens: $appState.vocabulary.terms,
                        placeholder: "e.g. Claude, Anthropic, kubectl, OpenWhisp",
                        isEnabled: appState.customVocabularyEnabled
                    )
                }
                .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bias terms")
                        .foregroundStyle(.secondary)
                    SettingsFootnote("Bias terms don't apply to \(EngineCapabilities.displayName(transcriptionEngine: appState.transcriptionEngine)) yet — whisper.cpp (everywhere) and Parakeet (files and meetings) steer recognition toward specific words today. Switch engine in Models to use them, or use Substitutions below, which work on every engine.")
                }
                .padding(.vertical, 2)
            }

            // Self-learning dictionary (MAK-41 Part C): correction proposals the app
            // captured from your type-overs, shown here for you to accept or reject.
            // Nothing is ever added to your rules without an explicit accept.
            if !appState.correctionProposals.pending.isEmpty {
                suggestedCorrections
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Substitutions")
                SettingsFootnote("Fix recurring mishearings — applied locally after transcription. Ordered starred-first, then most-used; “Sort by use” reorders on demand so rows don't jump while you type.")
                substitutionsTable
            }
            .padding(.vertical, 2)
            .disabled(!appState.customVocabularyEnabled)

            SubtitledToggle(
                "Learn corrections as I type over them",
                subtitle: "When you fix a single misheard word right after dictating, OpenWhisp proposes it as a rule here — on your Mac, never uploaded. You always approve before it takes effect.",
                isOn: $appState.correctionLearningEnabled
            )
            .disabled(!appState.customVocabularyEnabled)
        } header: {
            Text("Vocabulary")
        }
    }

    // MARK: - Suggested corrections (accept / reject)

    /// The pending learned-correction proposals: one row each with the from → to fix
    /// and Add / Dismiss buttons. Accepting folds it into the Substitutions table;
    /// dismissing suppresses that exact fix from being re-proposed.
    private var suggestedCorrections: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Suggested corrections", systemImage: "wand.and.stars")
                .font(.callout.weight(.semibold))
            SettingsFootnote("You corrected these words right after dictating. Add the ones you want to learn.")

            ForEach(appState.correctionProposals.pending) { proposal in
                HStack(spacing: 8) {
                    Text(proposal.from)
                        .foregroundColor(.secondary)
                        .strikethrough()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(proposal.to)
                        .fontWeight(.medium)
                    Spacer()
                    Button("Add") { appState.acceptCorrectionProposal(proposal.id) }
                        .controlSize(.small)
                    Button("Dismiss") { appState.rejectCorrectionProposal(proposal.id) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .padding(.vertical, 2)
    }

    // MARK: - Substitutions table

    /// The rows to render, in the FROZEN `displayedOrder` (ids), resolved to LIVE
    /// substitution values so each cell shows current from/to/star/usage. Any rule
    /// not yet in the snapshot (e.g. a just-added blank row, or one accepted from a
    /// proposal) is appended at the END so it appears next to the + button rather
    /// than jumping into a frequency slot mid-list. The order only changes on appear
    /// or an explicit "Sort by use" — never on a keystroke or a background bump.
    private var orderedSubstitutions: [Vocabulary.Substitution] {
        let byID = Dictionary(uniqueKeysWithValues: appState.vocabulary.substitutions.map { ($0.id, $0) })
        var rows = displayedOrder.compactMap { byID[$0] }
        let shown = Set(displayedOrder)
        rows.append(contentsOf: appState.vocabulary.substitutions.filter { !shown.contains($0.id) })
        return rows
    }

    /// Recompute the frozen order from the current frequency sort (starred first,
    /// then most-used). Called on appear and when the user asks to re-sort.
    private func refreshDisplayedOrder() {
        displayedOrder = appState.vocabulary.substitutionsByFrequency().map(\.id)
    }

    /// Standard macOS table + ± footer, same pattern as Per-App Profiles, now with a
    /// star toggle and a "used N×" count so the self-learning is visible.
    private var substitutionsTable: some View {
        VStack(spacing: 0) {
            Table(orderedSubstitutions, selection: $selectedSubstitutionID) {
                TableColumn("★") { sub in
                    Button {
                        toggleStar(sub.id)
                    } label: {
                        Image(systemName: starredState(sub.id) ? "star.fill" : "star")
                            .foregroundColor(starredState(sub.id) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(starredState(sub.id) ? "Starred — kept at the top" : "Star to keep at the top")
                    .accessibilityLabel(starredState(sub.id) ? "Unstar substitution" : "Star substitution")
                }
                .width(24)
                TableColumn("Heard") { sub in
                    TextField("heard", text: substitutionBinding(sub.id, keyPath: \.from))
                        .textFieldStyle(.plain)
                }
                TableColumn("Replace with") { sub in
                    TextField("correct", text: substitutionBinding(sub.id, keyPath: \.to))
                        .textFieldStyle(.plain)
                }
                TableColumn("Used") { sub in
                    Text(usageLabel(sub.id))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .width(52)
            }
            .frame(minHeight: 90, maxHeight: 180)

            HStack(spacing: 0) {
                Button {
                    let new = Vocabulary.Substitution(from: "", to: "")
                    appState.vocabulary = appState.vocabulary.addingSubstitution(new)
                    // Show the new row now, at the end (next to +), without re-sorting
                    // the rest — it's blank so a frequency slot would hide it mid-list.
                    displayedOrder.append(new.id)
                    selectedSubstitutionID = new.id
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add substitution")

                Divider().frame(height: 14)

                Button {
                    if let id = selectedSubstitutionID {
                        appState.vocabulary = appState.vocabulary.removingSubstitution(id)
                        displayedOrder.removeAll { $0 == id }
                        selectedSubstitutionID = nil
                    }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedSubstitutionID == nil)
                .accessibilityLabel("Remove selected substitution")

                Divider().frame(height: 14)

                Button("Sort by use") { refreshDisplayedOrder() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .help("Reorder: starred first, then most-used")

                Spacer()
            }
            .background(Color.secondary.opacity(0.05))
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        .onAppear { refreshDisplayedOrder() }
    }

    /// Whether the substitution with `id` is currently starred.
    private func starredState(_ id: UUID) -> Bool {
        appState.vocabulary.substitutions.first(where: { $0.id == id })?.starred ?? false
    }

    /// Flip the starred flag on the substitution with `id` (persists via didSet).
    private func toggleStar(_ id: UUID) {
        appState.vocabulary = appState.vocabulary.editingSubstitution(id) {
            $0.starred.toggle()
        }
    }

    /// A compact "used N×" label, or an em-dash when never used yet.
    private func usageLabel(_ id: UUID) -> String {
        let count = appState.vocabulary.substitutions.first(where: { $0.id == id })?.usageCount ?? 0
        return count == 0 ? "—" : "\(count)×"
    }

    /// Edit-in-place binding for one substitution field, looked up by id (Table
    /// rows don't carry bindings).
    private func substitutionBinding(_ id: UUID, keyPath: WritableKeyPath<Vocabulary.Substitution, String>) -> Binding<String> {
        Binding(
            get: {
                appState.vocabulary.substitutions.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                appState.vocabulary = appState.vocabulary.editingSubstitution(id) {
                    $0[keyPath: keyPath] = newValue
                }
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
                Text("Agent CLI (Claude / Codex)").tag("agentCLI")
            }

            SettingsFootnote(providerDescription)

            // Provider fields shown directly — required configuration never
            // hides behind a disclosure.
            switch appState.llmProvider {
            case "bundled":  bundledLLMFields
            case "local":    localLLMFields
            case "agentCLI": agentCLIFields
            default:         openAIFields
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
            // MAK-35: the cleanup INTENSITY dial replaces the old on/off toggle +
            // mode picker as the single control for the automatic AI pass. "None"
            // skips the LLM entirely (highest fidelity); Low/Medium/High feed
            // progressively stronger preset prompts. It is the one source of truth —
            // the legacy on/off toggle (tray, onboarding) now derives from it.
            Picker("Automatic AI cleanup", selection: $appState.cleanupIntensity) {
                ForEach(CleanupIntensity.allCases, id: \.self) { tier in
                    Text(tier.displayLabel).tag(tier)
                }
            }
            .pickerStyle(.segmented)

            SettingsFootnote(cleanupIntensityDescription(appState.cleanupIntensity))

            // Translation-improvement mode stays available while any cleanup tier
            // runs, so users who translate keep that path. The intensity's prompt
            // drives same-language cleanup; the translation mode is the distinct
            // "polish my English translation" flow.
            //
            // There is deliberately NO target-language picker: the transcription
            // engine's translate task ONLY ever produces English (see
            // LanguageResolver.outputLanguageForCleaning), so the only coherent polish
            // target is English. A user-settable target (the old en/ru picker) could
            // be left stale on "Russian" and then silently turn an English dictation
            // Russian — the reported regression. The polish target is now pinned to
            // English at the source.
            if appState.cleanupIntensity != .none {
                if appState.translateToEnglish || appState.openAIEnhancementMode == "improveTranslation" {
                    Picker("Mode", selection: $appState.openAIEnhancementMode) {
                        Text("Rephrase in the same language").tag("rephrase")
                        Text("Improve English translation").tag("improveTranslation")
                    }
                } else {
                    SettingsFootnote("Turn on “Translate to English” in Dictation › Language to also get a translation-improvement mode.")
                }
            }
        } header: {
            Text("Automatic Cleanup")
        } footer: {
            SettingsFootnote("Runs each final transcript through the AI model above — nothing to do while dictating. Only edits final text, never live chunks. Higher intensity means more polish but less literal fidelity to your exact words; you can always revert an entry to the original in Privacy › History.")
        }
    }

    /// One-line description of what a cleanup tier does, shown under the dial.
    /// Mirrors the tier semantics in `CleanupIntensity.systemPrompt`.
    private func cleanupIntensityDescription(_ intensity: CleanupIntensity) -> String {
        switch intensity {
        case .none:
            return "Off — insert the raw transcript exactly as dictated. No AI pass; highest fidelity and fully offline."
        case .low:
            return "Fix only capitalization, punctuation, and obvious typos. Your wording and filler words are kept verbatim."
        case .medium:
            return "Everything in Low, plus remove filler words (“um”, “uh”) and lightly rephrase awkward wording for readability."
        case .high:
            return "Everything in Medium, plus resolve spoken self-corrections (“3, no wait, 4” → “4”) and tighten into concise prose."
        }
    }

    private var translationStatusIsGood: Bool {
        ["Built-in model working", "Server reachable", "OpenAI key valid",
         "Local LLM reachable", "Rephrased", "Improved",
         "Agent CLI working"].contains(appState.translationStatus)
    }

    private var providerDescription: String {
        switch appState.llmProvider {
        case "bundled":
            return "Runs a small model fully on-device — nothing leaves your Mac, no setup or server needed. The model downloads once."
        case "local":
            return "Any OpenAI-compatible server on your machine or LAN (llama.cpp llama-server, Ollama). No data leaves to the cloud."
        case "agentCLI":
            return "Pipes the final transcript through a coding-agent CLI you already have installed (Claude Code, Codex, or your own command). Reuses that CLI's login — no API key here. Where the text goes depends on which CLI you pick."
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

    @ViewBuilder private var agentCLIFields: some View {
        Picker("Agent CLI", selection: $appState.agentCLIPreset) {
            ForEach(AgentCLIProvider.presets, id: \.id) { preset in
                Text(preset.name).tag(preset.id)
            }
        }

        // The chosen preset's one-line description (what it actually runs).
        if let preset = AgentCLIProvider.preset(id: appState.agentCLIPreset) {
            SettingsFootnote(preset.detail)
        }

        // Custom preset: the user supplies the command + fixed args themselves.
        if appState.agentCLIPreset == AgentCLIProvider.customPresetID {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Command", text: $appState.agentCLICustomCommand,
                          prompt: Text("e.g. claude, codex, or /opt/homebrew/bin/pi"))
                    .textFieldStyle(.roundedBorder)
                SettingsFootnote("A command on your PATH, or an absolute path. It must read the transcript on stdin and write the cleaned text to stdout.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments")
                SettingsFootnote("One argument per line, passed verbatim before the transcript. The transcript is never placed here — it's piped in on stdin.")
                TextEditor(text: $appState.agentCLICustomArgsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
            .padding(.vertical, 2)
        }

        // Timeout applies to every preset.
        HStack {
            Text("Timeout")
            Spacer()
            TextField("Timeout", value: $appState.agentCLITimeout, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            Text("seconds")
                .foregroundColor(.secondary)
        }

        SettingsCallout(
            .info,
            "Uses the CLI already installed on your Mac and its own login — no API key here. On any failure (CLI missing, timeout, error) your original transcript is kept."
        )
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
