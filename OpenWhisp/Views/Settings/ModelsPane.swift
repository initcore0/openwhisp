import SwiftUI
import Cocoa

/// Models: one home for engine choice, model selection, downloads, and disk
/// usage. Absorbs the old Basic → Quality, Advanced → Engine, Advanced → Model,
/// and Advanced → Storage sections.
struct ModelsPane: View {
    @ObservedObject var appState: AppState
    /// Live engine readiness (real Parakeet download percentage / compile phase /
    /// mapped failure), for the status row under the variant picker.
    @ObservedObject private var readinessTracker = ModelReadinessTracker.shared

    // Model storage: the scanned list (refreshed on appear + after a delete) and
    // the item pending a delete confirmation.
    @State private var storageItems: [ModelStorage.Item] = []
    @State private var storageDeleteTarget: ModelStorage.Item?
    @State private var storageMessage: String = ""
    @State private var showAllWhisperModels = false
    /// Cached per-variant completeness verdicts, so the Parakeet variant rows
    /// never walk the directory during rendering (refreshed on appear and
    /// whenever a prefetch finishes, i.e. `parakeetInFlightVariants` changes).
    /// Verdict-based — a torn download reads "Not downloaded", never installed.
    @State private var parakeetVerdicts: [String: ParakeetModelIntegrity.Verdict] = [:]

    private var isWhisperCpp: Bool { appState.transcriptionEngine == "whisper" }
    private var isWhisperKit: Bool { appState.transcriptionEngine == "whisperKit" }
    private var isAppleSpeech: Bool { appState.transcriptionEngine == "appleSpeech" }
    private var isParakeet: Bool { appState.transcriptionEngine == "parakeet" }
    private var isSpeechAnalyzer: Bool { appState.transcriptionEngine == "speechAnalyzer" }

    /// SpeechAnalyzer (macOS 26, MAK-59) is offered only when the OS exposes the
    /// API — hidden entirely on macOS 15 so nothing regresses there.
    private var speechAnalyzerAvailable: Bool { SpeechAnalyzerAvailability.isSupportedOS }

    // The three recommended whisper.cpp tiers (redesign §4.3): one tier
    // vocabulary — Fast / Balanced / Accurate — with the model id and size as
    // metadata. large-v3-turbo stays the recommended tier (near large-v3
    // accuracy at ~2.3–4× the speed; see docs/ASR_ALTERNATIVES.md).
    private static let whisperCppTiers: [(tier: String, model: String, size: String, detail: String)] = [
        ("Fast",     "base",           "147 MB", "Quick notes; lower accuracy."),
        ("Balanced", "small",          "464 MB", "Good all-rounder."),
        ("Accurate", "large-v3-turbo", "1.5 GB", "Most accurate, still fast on Apple Silicon."),
    ]

    var body: some View {
        Form {
            engineSection
            modelSection
            storageSection
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshWhisperKitStagedModels()
            refreshStorage()
            refreshParakeetVerdicts()
        }
        // Sizes refresh automatically after downloads finish — no manual button.
        .onChange(of: appState.isModelDownloading) { refreshStorage() }
        .onChange(of: appState.whisperKitDownloadingModel) { refreshStorage() }
        .onChange(of: appState.isLLMModelDownloading) { refreshStorage() }
        // A Parakeet prefetch finishing flips the in-flight set — re-verify the
        // variants (and sizes) once, in event context, not per render.
        .onChange(of: appState.parakeetInFlightVariants) {
            refreshParakeetVerdicts()
            refreshStorage()
        }
        .confirmationDialog(
            "Remove this model?",
            isPresented: Binding(
                get: { storageDeleteTarget != nil },
                set: { if !$0 { storageDeleteTarget = nil } }
            ),
            presenting: storageDeleteTarget
        ) { item in
            Button("Remove \(ModelStorage.format(bytes: item.bytes))", role: .destructive) {
                if let error = appState.removeModel(item) {
                    storageMessage = error
                } else {
                    storageMessage = "Removed \(item.label)."
                }
                refreshStorage()
                storageDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) { storageDeleteTarget = nil }
        } message: { item in
            Text("\(item.label) (\(ModelStorage.format(bytes: item.bytes))) will be deleted from your Mac. It will be re-downloaded next time it's needed.")
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            // MAK-46: Parakeet is the recommended default (true streaming, ~0.3 s
            // latency with punctuation). Included in default builds; a lean
            // PARAKEET=0 build hides the row rather than showing one that errors.
            // The "Recommended" badge belongs to Parakeet ALONE — the whisper
            // family is de-recommended (kept for compatibility), so on a lean
            // build simply no row is badged rather than promoting a legacy engine.
            #if PARAKEET
            SelectableRow(
                title: "Parakeet Realtime (CoreML)",
                subtitle: "True streaming — words appear ~0.3 s behind your voice, with punctuation. English + multilingual variants. Fastest and most accurate on Apple Silicon.",
                badge: "Recommended",
                isSelected: isParakeet
            ) { appState.transcriptionEngine = "parakeet" }
            #endif

            SelectableRow(
                title: "WhisperKit (CoreML)",
                subtitle: "Legacy — slower; kept for compatibility.",
                isSelected: isWhisperKit
            ) { appState.transcriptionEngine = "whisperKit" }

            SelectableRow(
                title: "Whisper Local (whisper.cpp)",
                subtitle: "Legacy — widest model selection, custom GGML files. Supports live typing.",
                isSelected: isWhisperCpp
            ) { appState.transcriptionEngine = "whisper" }

            SelectableRow(
                title: "Apple Speech",
                subtitle: "Built into macOS. Instant, no downloads.",
                isSelected: isAppleSpeech
            ) { appState.transcriptionEngine = "appleSpeech" }

            // MAK-59: Apple SpeechAnalyzer (macOS 26). On-device, auto-punctuating,
            // ~2× faster than Whisper on files. Hidden on macOS 15 where the
            // API doesn't exist.
            if speechAnalyzerAvailable {
                SelectableRow(
                    title: "Apple SpeechAnalyzer",
                    subtitle: "macOS 26 on-device engine. Auto-punctuating, fast file transcription. No downloads.",
                    isSelected: isSpeechAnalyzer
                ) { appState.transcriptionEngine = "speechAnalyzer" }
            }

            // Never change state silently: switching to WhisperKit while "Type
            // live" was on snaps the output mode, and this says so.
            if let notice = appState.engineSwitchNotice {
                SettingsCallout(.info, notice, actionLabel: "OK") {
                    appState.engineSwitchNotice = nil
                }
            }
        } header: {
            Text("Engine")
        } footer: {
            SettingsFootnote("Everything transcribes on your Mac with any engine. Parakeet is the recommended default — a lean PARAKEET=0 build hides it and falls back to WhisperKit (or whisper.cpp).")
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        if isWhisperCpp {
            whisperCppModelSection
        } else if isWhisperKit {
            whisperKitModelSection
        } else if isParakeet {
            parakeetModelSection
        } else {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .foregroundColor(.secondary)
                    Text(isSpeechAnalyzer
                        ? "Apple SpeechAnalyzer uses the built-in macOS 26 speech models. The model for your language installs automatically on first use."
                        : "Apple Speech uses the macOS speech engine for the selected language. Nothing to download or configure.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Model")
            }
        }
    }

    /// Parakeet variant picker (MAK-46). FluidAudio stages the model itself on
    /// first use (HuggingFace → ~/Library/Application Support/FluidAudio);
    /// selecting a variant prefetches it in the background. Each row shows a
    /// verified state — "Not downloaded" / "Downloading…" / (installed → no
    /// badge) — and the status row underneath carries the live percentage,
    /// integrity result, and the Redownload repair for the selected variant.
    private var parakeetModelSection: some View {
        Section {
            ForEach(ParakeetCatalog.variants, id: \.id) { variant in
                let state = ParakeetDownloadStatePolicy.state(
                    forVariant: variant.id,
                    verdict: parakeetVerdicts[variant.id] ?? .notDownloaded,
                    inFlightVariants: appState.parakeetInFlightVariants
                )
                SelectableRow(
                    title: variant.name,
                    subtitle: parakeetSubtitle(for: variant, state: state),
                    isSelected: appState.parakeetVariant == variant.id
                ) { appState.parakeetVariant = variant.id }
            }

            parakeetStatusView
        } header: {
            Text("Model")
        } footer: {
            SettingsFootnote("Models download automatically the first time they're needed and are cached under Application Support/FluidAudio. Files are verified on disk; Redownload replaces a damaged copy. All transcription stays on your Mac.")
        }
    }

    /// Live status for the SELECTED variant: download percentage while fetching,
    /// the compile phase, a verified checkmark when complete, and — on failure
    /// or an incomplete cache — the explicit Redownload repair the menu-bar
    /// "Model unavailable" error previously had no answer to.
    @ViewBuilder private var parakeetStatusView: some View {
        let selectedVerdict =
            parakeetVerdicts[ParakeetCatalog.normalize(appState.parakeetVariant)] ?? .notDownloaded
        switch readinessTracker.readiness {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                if let progress, progress > 0 {
                    ProgressView(value: min(progress, 1)).frame(maxWidth: 280)
                    Text("Downloading… \(Int(min(progress, 1) * 100))%")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the model…").font(.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Button("Redownload Model") { redownloadSelectedParakeetVariant() }
            }
            .padding(.vertical, 4)
        default:
            switch selectedVerdict {
            case .complete:
                Label("Model files verified", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
            case .incomplete:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Model files are incomplete — redownload to repair.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("Redownload Model") { redownloadSelectedParakeetVariant() }
                }
                .padding(.vertical, 4)
            case .notDownloaded:
                EmptyView()
            }
        }
    }

    /// Purge the selected variant's repo folder and prefetch it again — the
    /// explicit repair for a damaged cache (also reachable implicitly: a failed
    /// load with files present triggers the engine's own purge-and-redownload).
    private func redownloadSelectedParakeetVariant() {
        let variant = ParakeetCatalog.normalize(appState.parakeetVariant)
        if let folder = ParakeetDownloadStatePolicy.repoFolder(forVariant: variant) {
            try? FluidAudioModelsLocator.removeRepoFolder(folder)
        }
        refreshParakeetVerdicts()
        refreshStorage()
        appState.prefetchParakeetVariant()
    }

    /// Re-verify every catalog variant's on-disk completeness (event context
    /// only — never during render).
    private func refreshParakeetVerdicts() {
        parakeetVerdicts = Dictionary(uniqueKeysWithValues: ParakeetCatalog.variants.map {
            ($0.id, FluidAudioModelsLocator.verdict(forVariant: $0.id))
        })
    }

    /// Variant subtitle with the coarse download-state badge appended (installed
    /// variants get no badge — the row is unadorned).
    private func parakeetSubtitle(
        for variant: ParakeetCatalog.Variant, state: ParakeetDownloadState
    ) -> String {
        let base = "\(variant.detail) (\(variant.size))"
        guard let badge = state.badge else { return base }
        return "\(base) · \(badge)"
    }

    private var whisperCppModelSection: some View {
        Section {
            ForEach(Self.whisperCppTiers, id: \.model) { tier in
                whisperCppModelRow(
                    name: tier.model,
                    title: tier.tier,
                    subtitle: "\(tier.model) · \(tier.detail)",
                    sizeText: tier.size
                )
            }

            DisclosureGroup("All models…", isExpanded: $showAllWhisperModels) {
                ForEach(nonTierWhisperModels, id: \.name) { model in
                    whisperCppModelRow(
                        name: model.name,
                        title: model.label,
                        subtitle: nil,
                        sizeText: model.size
                    )
                }

                // Custom model file: absorbs the old Model Path + Browse…
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom model file").font(.system(size: 13, weight: .medium))
                    HStack {
                        TextField("Model path", text: $appState.modelPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { browseModelPath() }
                        Button("Check") { appState.ensureModelExists() }
                    }
                }
                .padding(.vertical, 4)
            }

            modelDownloadStatusView
        } header: {
            Text("Model")
        } footer: {
            SettingsFootnote("Models download on first use and run entirely on your Mac. Multilingual models handle Russian and other languages; English-only (.en) models are fastest for English.")
        }
    }

    /// One selectable whisper.cpp model row: selecting it writes `modelName`
    /// and triggers a download if the file isn't on disk yet.
    private func whisperCppModelRow(name: String, title: String, subtitle: String?, sizeText: String?) -> some View {
        let isSelected = appState.modelName == name
        let installed = appState.isWhisperModelInstalled(name)
        let downloading = isSelected && appState.isModelDownloading

        let accessory: ModelRow.Accessory
        if downloading {
            accessory = .downloading(appState.modelDownloadProgress)
        } else if installed {
            accessory = isSelected ? .inUse : .installed
        } else {
            accessory = .download
        }

        return ModelRow(
            title: title,
            subtitle: subtitle,
            sizeText: sizeText,
            isSelected: isSelected,
            accessory: accessory,
            onSelect: {
                appState.modelName = name
                appState.ensureModelExists()
            },
            onDelete: { confirmDelete(pathSuffix: "ggml-\(name).bin") },
            deleteDisabled: isSelected,
            deleteDisabledReason: "The model in use can't be removed"
        )
    }

    /// Full catalog minus the three tier models shown above.
    private var nonTierWhisperModels: [(name: String, label: String, size: String)] {
        let tierNames = Set(Self.whisperCppTiers.map(\.model))
        return appState.availableModelsList().filter { !tierNames.contains($0.name) }
    }

    private var whisperKitModelSection: some View {
        Section {
            let staged = Set(appState.whisperKitStagedModels)
            let models = WhisperKitModelCatalog.selectableModels()

            ForEach(models, id: \.self) { model in
                whisperKitModelRow(model, installed: staged.contains(model))
            }

            if !appState.whisperKitDownloadStatus.isEmpty {
                SettingsFootnote(appState.whisperKitDownloadStatus)
            }
        } header: {
            Text("Model")
        } footer: {
            SettingsFootnote("WhisperKit runs Apple-native CoreML models on the GPU/Neural Engine, downloaded from Argmax's repo and stored locally. Russian needs a multilingual model (Balanced or Accurate).")
        }
    }

    /// Tier naming shared with whisper.cpp (§5): Fast / Balanced / Accurate,
    /// with the underlying model as metadata.
    private static func whisperKitTierInfo(_ model: String) -> (title: String, subtitle: String) {
        switch model {
        case "openai_whisper-small":
            return ("Balanced", "Small · multilingual — best balance for streaming.")
        case "openai_whisper-tiny.en":
            return ("Fast", "Tiny · English only — fastest, no Russian.")
        case "openai_whisper-large-v3-turbo", "openai_whisper-large-v3-v20240930_turbo_632MB":
            return ("Accurate", "Large v3 Turbo · most accurate; very slow first load.")
        default:
            let info = WhisperKitModelCatalog.displayInfo(for: model)
            return (info.label, info.hint ?? "")
        }
    }

    /// Selection and installation are the same list: uninstalled models show a
    /// Download accessory instead of a " — not installed" picker suffix.
    private func whisperKitModelRow(_ model: String, installed: Bool) -> some View {
        let info = Self.whisperKitTierInfo(model)
        let isSelected = appState.whisperKitModel == model
        let isDownloading = appState.whisperKitDownloadingModel == model

        let accessory: ModelRow.Accessory
        if isDownloading {
            accessory = .downloading(appState.whisperKitDownloadProgress)
        } else if installed {
            accessory = isSelected ? .inUse : .installed
        } else {
            accessory = .download
        }

        return ModelRow(
            title: info.title,
            subtitle: info.subtitle.isEmpty ? nil : info.subtitle,
            sizeText: nil,
            isSelected: isSelected,
            accessory: accessory,
            onSelect: { appState.whisperKitModel = model },
            onDownload: { appState.downloadWhisperKitModel(model) },
            downloadDisabled: appState.whisperKitDownloadingModel != nil,
            onDelete: { confirmDelete(pathSuffix: "/whisperkit-models/\(model)") },
            deleteDisabled: isSelected,
            deleteDisabledReason: "The model in use can't be removed"
        )
    }

    /// Shared download status row: determinate progress when a total size is
    /// known, indeterminate spinner otherwise, Retry on failure.
    @ViewBuilder
    private var modelDownloadStatusView: some View {
        if appState.isModelDownloading || appState.modelDownloadFailed {
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
    }

    private var downloadStatusColor: Color {
        if appState.modelDownloadFailed && !appState.isModelDownloading { return .red }
        return appState.isModelDownloading ? .orange : .secondary
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            HStack {
                Text("Downloaded models")
                Spacer()
                Text(ModelStorage.format(bytes: ModelStorage.totalBytes(storageItems)))
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Button("Open Models Folder") {
                    // Engine-aware: Parakeet models live in FluidAudio's own cache
                    // (~/Library/Application Support/FluidAudio/Models), not under
                    // OpenWhisp's folder — opening the wrong one reads as "where
                    // is my model?". Ensure the dir exists so Finder always opens.
                    let dir = isParakeet
                        ? AppState.fluidAudioModelsDirectory()
                        : WhisperKitModelCatalog.baseDir.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }

            if !storageItems.isEmpty {
                DisclosureGroup("All downloaded files") {
                    ForEach(storageItems) { item in
                        ModelRow(
                            title: item.label,
                            subtitle: item.kind.displayName,
                            sizeText: ModelStorage.format(bytes: item.bytes),
                            isSelected: false,
                            accessory: item.isActive ? .inUse : .installed,
                            onDelete: { storageDeleteTarget = item },
                            deleteDisabled: item.isActive,
                            deleteDisabledReason: "The model in use can't be removed"
                        )
                    }
                }
            }

            if !storageMessage.isEmpty {
                SettingsFootnote(storageMessage)
            }
        } header: {
            Text("Storage")
        } footer: {
            SettingsFootnote("Covers every engine, including the built-in AI model. Removed models re-download on demand.")
        }
    }

    private func refreshStorage() {
        storageItems = appState.installedModelStorage()
    }

    /// Route a model row's Remove through the storage list, so the confirmation
    /// dialog shows the real on-disk size.
    private func confirmDelete(pathSuffix: String) {
        refreshStorage()
        guard let item = storageItems.first(where: { $0.path.hasSuffix(pathSuffix) }) else {
            storageMessage = "That model isn't on disk."
            return
        }
        storageDeleteTarget = item
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
}
