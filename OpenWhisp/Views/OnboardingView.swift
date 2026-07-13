import SwiftUI
import AVFoundation
import ApplicationServices

/// First-run onboarding: a short guided flow that gets the user from install to
/// a working dictation in under a minute — permissions, model readiness, hotkey
/// choice, and a live test. Shown once (gated by AppState.didCompleteOnboarding).
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    /// Called when the user finishes or skips; the host closes the window.
    var onClose: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, model, hotkey, ai, tryIt, whatsNext
    }

    @State private var step: Step = .welcome
    // Live permission mirrors, refreshed by a poll timer while the window is open.
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    // Live Input-Monitoring status, refreshed by the same poll timer. Drives the
    // hotkey step's readiness and the "try it" hotkey-is-dead guard (MAK-24).
    @State private var inputMonitoringStatus: OnboardingHotkeyGate.InputMonitoringStatus = .unknown
    // FluidAudio repo folders on disk, so the model step can tell whether the
    // (default) Parakeet model has finished downloading. Refreshed by the poll
    // timer — cheap dir listing — so "downloading…" flips to "ready" on its own.
    @State private var parakeetInstalledFolders: Set<String> = []

    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(36)

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 520, height: 460)
        .onAppear(perform: refresh)
        .onReceive(pollTimer) { _ in refresh() }
        // The host keeps the window (isReleasedWhenClosed = false) and only
        // releases it via onClose. Catch every close path — including the red
        // title-bar button — so this view and its 1 Hz poll timer don't outlive
        // the window.
        .background(WindowCloseObserver(onWillClose: onClose))
    }

    // MARK: - Content per step

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:       welcomeStep
        case .microphone:    microphoneStep
        case .accessibility: accessibilityStep
        case .model:         modelStep
        case .hotkey:        hotkeyStep
        case .ai:            aiStep
        case .tryIt:         tryItStep
        case .whatsNext:     whatsNextStep
        }
    }

    private var welcomeStep: some View {
        stepLayout(
            icon: "waveform",
            title: "Welcome to OpenWhisp",
            subtitle: "Hold a key, speak, and your words appear wherever you're typing — transcribed locally on your Mac. Let's set it up; it takes about a minute."
        ) { EmptyView() }
    }

    private var microphoneStep: some View {
        stepLayout(
            icon: micGranted ? "checkmark.circle.fill" : "mic.fill",
            iconColor: micGranted ? .green : .accentColor,
            title: "Let OpenWhisp hear you",
            subtitle: "OpenWhisp needs your microphone to transcribe speech. Nothing is recorded or uploaded — transcription runs entirely on your Mac."
        ) {
            if micGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                VStack(spacing: 8) {
                    Button("Allow Microphone") {
                        appState.requestMicrophoneAccess { granted in
                            micGranted = granted
                            if !granted { appState.openPrivacySettings() }
                        }
                    }
                    .controlSize(.large)
                    Button("Open System Settings") { appState.openPrivacySettings() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var accessibilityStep: some View {
        stepLayout(
            icon: accessibilityGranted ? "checkmark.circle.fill" : "keyboard.fill",
            iconColor: accessibilityGranted ? .green : .accentColor,
            title: "Let OpenWhisp type for you",
            subtitle: "To insert text into other apps and detect your dictation hotkey, macOS needs you to enable OpenWhisp under Accessibility."
        ) {
            VStack(spacing: 10) {
                if accessibilityGranted {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Button("Enable in Accessibility Settings") {
                        appState.requestAccessibilityPermission()
                        appState.openAccessibilitySettings()
                    }
                    .controlSize(.large)
                    Text("After enabling OpenWhisp in the list, return here — this updates automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Explain the separate "Keystroke Receiving" / Input Monitoring
                // prompt up front so it isn't alarming when macOS shows it.
                Label {
                    Text("macOS may also ask to let OpenWhisp “receive keystrokes.” That's how it detects your push-to-talk key — keystrokes are **never logged, stored, or sent anywhere**. Allow it (or enable OpenWhisp under Privacy & Security → Input Monitoring).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            }
        }
    }

    /// Readiness of whichever engine is active — the model step is engine-aware
    /// so a Parakeet (default) or WhisperKit first-launch download shows real
    /// progress instead of a false "ready". Recomputed on each render (the 1 Hz
    /// poll refreshes the underlying signals).
    private var modelStatus: OnboardingModelStatus.State {
        let variant = ParakeetCatalog.normalize(appState.parakeetVariant)
        let parakeetState = ParakeetDownloadStatePolicy.state(
            forVariant: variant,
            installedFolders: parakeetInstalledFolders,
            inFlightVariants: appState.parakeetInFlightVariants
        )
        return OnboardingModelStatus.state(
            engine: appState.transcriptionEngine,
            parakeetInstalled: parakeetState == .installed,
            parakeetInFlight: parakeetState == .downloading,
            parakeetFailed: appState.parakeetPrefetchFailed,
            whisperCppDownloading: appState.isModelDownloading,
            whisperCppProgress: appState.modelDownloadProgress,
            whisperCppFailed: appState.modelDownloadFailed,
            whisperKitStaged: WhisperKitModelCatalog.isStaged(appState.whisperKitModel),
            whisperKitDownloading: appState.whisperKitDownloadingModel != nil,
            whisperKitProgress: appState.whisperKitDownloadProgress
        )
    }

    private var modelStep: some View {
        let status = modelStatus
        let downloading = status != .ready && status != .failed
        return stepLayout(
            icon: status == .failed ? "exclamationmark.triangle.fill"
                : (downloading ? "arrow.down.circle" : "checkmark.circle.fill"),
            iconColor: status == .failed ? .orange : (downloading ? .accentColor : .green),
            title: status == .failed ? "Couldn't download the speech model"
                : (downloading ? "Preparing your speech model" : "Your speech model is ready"),
            subtitle: status == .failed
                ? "The download didn't complete. Check your internet connection and try again — it runs entirely on your Mac once installed."
                : (downloading
                    ? "Downloading the speech model. This is a one-time download and runs entirely on your Mac afterward."
                    : "OpenWhisp is ready to transcribe locally — no internet required from here on.")
        ) {
            switch status {
            case .downloading(let progress):
                VStack(spacing: 8) {
                    if let progress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 280)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(modelDownloadCaption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .failed:
                VStack(spacing: 10) {
                    Text(modelFailureDetail)
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("Retry Download") { retryModelDownload() }
                        .controlSize(.large)
                }
            case .ready:
                Label("Ready — runs offline", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Progress caption during a download. whisper.cpp publishes a rich status
    /// string (bytes/percent); the streaming engines (Parakeet / WhisperKit
    /// preload) don't, so fall back to a plain one-liner for them.
    private var modelDownloadCaption: String {
        if appState.transcriptionEngine == "whisper", !appState.modelDownloadStatus.isEmpty {
            return appState.modelDownloadStatus
        }
        if !appState.whisperKitDownloadStatus.isEmpty,
           appState.transcriptionEngine == "whisperKit" {
            return appState.whisperKitDownloadStatus
        }
        return "Downloading the speech model…"
    }

    /// Failure caption. whisper.cpp carries a specific status string; the
    /// streaming engines (Parakeet) don't, so fall back to a plain one-liner.
    private var modelFailureDetail: String {
        if appState.transcriptionEngine == "whisper", !appState.modelDownloadStatus.isEmpty {
            return appState.modelDownloadStatus
        }
        return "Couldn't reach the model server. Check your connection and retry."
    }

    /// Engine-aware retry: whisper.cpp re-runs its GGML download; Parakeet
    /// re-kicks its FluidAudio prefetch (which also clears the failure flag).
    private func retryModelDownload() {
        if appState.transcriptionEngine == "parakeet" {
            appState.prefetchParakeetVariant()
        } else {
            appState.retryModelDownload()
        }
    }

    private var hotkeyStep: some View {
        stepLayout(
            icon: "command",
            title: "Choose your dictation key",
            subtitle: "Hold this key while you speak, release to insert your text."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $appState.triggerMode) {
                    Text("Fn (Globe) — one-handed, recommended").tag("fn")
                    Text("Control + Space").tag("controlSpace")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(appState.hotkeyHelpText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                inputMonitoringStatusBlock
            }
        }
    }

    /// Live Input-Monitoring status for the hotkey step. Without this grant the
    /// global push-to-talk CGEventTap never fires, so the very first hotkey — and
    /// the "try it" test — silently do nothing (MAK-24). We surface the state and
    /// an inline fix; the 1 Hz poll re-checks so it clears the moment the user
    /// enables OpenWhisp in System Settings and returns.
    @ViewBuilder private var inputMonitoringStatusBlock: some View {
        switch OnboardingHotkeyGate.readiness(inputMonitoring: inputMonitoringStatus) {
        case .ready:
            Label("Input Monitoring granted — your hotkey is ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .blocked:
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Input Monitoring is off — your dictation hotkey **won't work** until you enable OpenWhisp. Keystrokes are never logged, stored, or sent anywhere.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                Button("Open System Settings → Input Monitoring") {
                    appState.openInputMonitoringSettings()
                }
                .controlSize(.large)
                Text("After enabling OpenWhisp in the list, return here — this updates automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        case .unconfirmed:
            EmptyView()
        }
    }

    private var aiStep: some View {
        stepLayout(
            icon: "wand.and.stars",
            iconColor: .accentColor,
            title: "Polish your words with AI (optional)",
            subtitle: "After transcribing, AI can fix punctuation, capitalization, and filler words. You can also refine while dictating: keep holding the dictation key, tap the Refine key, and speak an instruction like “make it a Telegram post.” The built-in option runs fully on your Mac; nothing leaves your machine."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Automatically polish every dictation with AI", isOn: $appState.openAIEnhancementEnabled)

                if appState.openAIEnhancementEnabled {
                    Picker("", selection: $appState.llmProvider) {
                        Text("On this Mac (built-in) — offline, no setup").tag("bundled")
                        Text("OpenAI (cloud) — needs an API key").tag("openai")
                        Text("Your server (self-hosted) — any OpenAI-compatible server").tag("local")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if appState.llmProvider == "bundled" {
                        bundledModelControls
                    } else if appState.llmProvider == "openai" {
                        Text("Add your OpenAI API key in Settings → Cleanup → AI Cleanup. Your text is sent to OpenAI for cleanup.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Point OpenWhisp at your OpenAI-compatible server in Settings → Cleanup → AI Cleanup.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("You can turn this on anytime from the menu bar or Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 380)
        }
    }

    @ViewBuilder private var bundledModelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: $appState.bundledLLMModel) {
                ForEach(appState.bundledLLMModelsList(), id: \.id) { model in
                    Text("\(model.label) · \(model.size)").tag(model.id)
                }
            }
            .pickerStyle(.menu)

            if appState.isLLMModelDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: appState.llmModelDownloadProgress ?? 0).frame(maxWidth: 280)
                    Text(appState.llmModelDownloadStatus).font(.caption).foregroundColor(.secondary)
                }
            } else if appState.llmModelDownloadFailed {
                HStack {
                    Text("Download failed").font(.caption).foregroundColor(.orange)
                    Button("Retry") { appState.retryLLMModelDownload() }
                }
            } else if appState.bundledLLMModelInstalled {
                Label("Ready — runs offline", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button("Download model") { appState.ensureLLMModelExists() }
                Text("One-time download (\(selectedBundledModelSize)); then it runs entirely on your Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var selectedBundledModelSize: String {
        appState.bundledLLMModelsList().first(where: { $0.id == appState.bundledLLMModel })?.size ?? "~0.5 GB"
    }

    private var tryItStep: some View {
        stepLayout(
            icon: "checkmark.seal.fill",
            iconColor: .green,
            title: "Give it a try",
            subtitle: "Hold \(triggerName) and say: “Hello, OpenWhisp is working.” Release when you're done."
        ) {
            VStack(spacing: 10) {
                // Don't present a hotkey that's guaranteed dead: if Input Monitoring
                // is confirmed denied, the push-to-talk key can't fire and the test
                // would silently wait forever. Warn + offer the inline fix (MAK-24).
                if OnboardingHotkeyGate.shouldWarnHotkeyDead(inputMonitoring: inputMonitoringStatus) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text("Your **\(triggerName)** hotkey can't fire yet — Input Monitoring is off, so nothing will happen when you hold it. Enable it, then try again.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                        Button("Open System Settings → Input Monitoring") {
                            appState.openInputMonitoringSettings()
                        }
                        .controlSize(.large)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                }
                if !appState.streamingText.isEmpty || appState.lastTranscription?.isEmpty == false {
                    Text(appState.streamingText.isEmpty ? (appState.lastTranscription ?? "") : appState.streamingText)
                        .font(.body)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                    Label("It works — you're all set!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Text("Waiting for your voice…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// The closing "What's next" card (MAK-25): 2–3 features to explore now that
    /// setup is done, each with its real Settings path. Content is `TipsCatalog.whatsNext`.
    private var whatsNextStep: some View {
        stepLayout(
            icon: "sparkles",
            iconColor: .accentColor,
            title: "You're set — here's what to try next",
            subtitle: "A few features worth discovering once you've got the basics. Find the full list anytime under “Tips & Commands” in the menu."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(TipsCatalog.whatsNext.enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.headline)
                        Text(step.pitch)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(step.settingsPath, systemImage: "gearshape")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Footer / navigation

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Skip setup") { finish() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Button(primaryButtonTitle) { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .whatsNext: return "Done"
        case .welcome: return "Get Started"
        default: return "Continue"
        }
    }

    private var primaryDisabled: Bool {
        // Never hard-block: permissions can be granted later, and the model can
        // finish downloading after setup — the user can always advance.
        false
    }

    private var triggerName: String {
        appState.triggerMode == "fn" ? "Fn" : "Control+Space"
    }

    private func advance() {
        if step == .whatsNext {
            finish()
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    private func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            step = prev
        }
    }

    private func finish() {
        appState.finishOnboarding()
        onClose()
    }

    private func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringStatus = appState.liveInputMonitoringStatus
        // Only the Parakeet path needs the on-disk folder scan; skip the listing
        // for the other engines so the poll stays cheap.
        if appState.transcriptionEngine == "parakeet" {
            parakeetInstalledFolders = AppState.installedFluidAudioFolders()
        }
        appState.refreshPermissionLabels()
    }

    // MARK: - Layout helper

    @ViewBuilder
    private func stepLayout<Body: View>(
        icon: String,
        iconColor: Color = .accentColor,
        title: String,
        subtitle: String,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(iconColor)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            body()
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
