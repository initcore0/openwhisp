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
        case welcome, microphone, accessibility, model, hotkey, tryIt
    }

    @State private var step: Step = .welcome
    // Live permission mirrors, refreshed by a poll timer while the window is open.
    @State private var micGranted = false
    @State private var accessibilityGranted = false

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
    }

    // MARK: - Content per step

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:       welcomeStep
        case .microphone:    microphoneStep
        case .accessibility: accessibilityStep
        case .model:         modelStep
        case .hotkey:        hotkeyStep
        case .tryIt:         tryItStep
        }
    }

    private var welcomeStep: some View {
        stepLayout(
            icon: "waveform",
            title: "Welcome to VoiceNote",
            subtitle: "Hold a key, speak, and your words appear wherever you're typing — transcribed locally on your Mac. Let's set it up; it takes about a minute."
        ) { EmptyView() }
    }

    private var microphoneStep: some View {
        stepLayout(
            icon: micGranted ? "checkmark.circle.fill" : "mic.fill",
            iconColor: micGranted ? .green : .accentColor,
            title: "Let VoiceNote hear you",
            subtitle: "VoiceNote needs your microphone to transcribe speech. Nothing is recorded or uploaded — transcription runs entirely on your Mac."
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
            title: "Let VoiceNote type for you",
            subtitle: "To insert text into other apps and detect your dictation hotkey, macOS needs you to enable VoiceNote under Accessibility."
        ) {
            if accessibilityGranted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                VStack(spacing: 8) {
                    Button("Enable in Accessibility Settings") {
                        appState.requestAccessibilityPermission()
                        appState.openAccessibilitySettings()
                    }
                    .controlSize(.large)
                    Text("After enabling VoiceNote in the list, return here — this updates automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var modelStep: some View {
        stepLayout(
            icon: appState.isModelDownloading ? "arrow.down.circle" : "checkmark.circle.fill",
            iconColor: appState.isModelDownloading ? .accentColor : .green,
            title: appState.isModelDownloading ? "Preparing your speech model" : "Your speech model is ready",
            subtitle: appState.isModelDownloading
                ? "Downloading the speech model. This is a one-time download and runs entirely on your Mac afterward."
                : "VoiceNote is ready to transcribe locally — no internet required from here on."
        ) {
            if appState.isModelDownloading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(appState.modelDownloadStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Label(appState.modelDownloadStatus, systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
                    Text("Fn / Globe key — one-handed, recommended").tag("fn")
                    Text("Control + Space").tag("controlSpace")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(appState.hotkeyHelpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tryItStep: some View {
        stepLayout(
            icon: "checkmark.seal.fill",
            iconColor: .green,
            title: "Give it a try",
            subtitle: "Hold \(triggerName) and say: “Hello, VoiceNote is working.” Release when you're done."
        ) {
            VStack(spacing: 10) {
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
        case .tryIt: return "Done"
        case .welcome: return "Get Started"
        default: return "Continue"
        }
    }

    private var primaryDisabled: Bool {
        // Don't hard-block on permissions (the user can grant later), but nudge:
        // only the model step waits, and only while actively downloading.
        false
    }

    private var triggerName: String {
        appState.triggerMode == "fn" ? "Fn" : "Control+Space"
    }

    private func advance() {
        if step == .tryIt {
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
