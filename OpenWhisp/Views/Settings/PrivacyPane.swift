import SwiftUI
import Cocoa

/// Privacy & Permissions: the trust anchor. The dynamic privacy indicator up
/// top, uniform permission rows, troubleshooting tools, and transcription
/// history — the most sensitive data the app writes to disk.
struct PrivacyPane: View {
    @ObservedObject var appState: AppState

    @State private var screenContextAddMessage: String?

    var body: some View {
        Form {
            summarySection
            permissionsSection
            screenContextSection
            troubleshootingSection
            historySection
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshPermissionLabels() }
    }

    // MARK: - Screen context (MAK-34)

    private var screenContextSection: some View {
        Section {
            SubtitledToggle(
                "Read screen context (advanced)",
                subtitle: "When on, at dictation start OpenWhisp reads the focused field's existing text on this Mac to (1) bias transcription toward the names and identifiers already on screen and (2) — with a local AI cleanup provider only — give the cleanup model the surrounding text so it matches the thread. Off by default. Never reads password fields. Surrounding text is NEVER sent to a cloud or agent-CLI provider, and nothing read is saved to disk.",
                isOn: $appState.screenContext.enabled
            )

            if appState.screenContext.enabled {
                Toggle("Bias transcription with on-screen terms", isOn: $appState.screenContext.biasTermsEnabled)
                Toggle("Give surrounding text to local AI cleanup", isOn: $appState.screenContext.llmContextEnabled)

                Divider()

                Text("Allowed apps")
                    .font(.subheadline).bold()
                Text("Screen context is only ever read in apps you list here. Nothing happens until you add at least one.")
                    .font(.caption).foregroundColor(.secondary)

                if appState.screenContext.allowedBundleIDs.isEmpty {
                    Text("No apps allowed yet — add one below.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(appState.screenContext.allowedBundleIDs, id: \.self) { bid in
                        HStack {
                            Text(displayName(for: bid))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                removeAllowedApp(bid)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove \(displayName(for: bid))")
                        }
                    }
                }

                Button("Add Last-Used App") { addAllowedFrontmostApp() }
                if let msg = screenContextAddMessage {
                    Text(msg).font(.caption).foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Screen Context")
        } footer: {
            SettingsFootnote("Requires Accessibility permission (granted above). Bias terms only prime the on-device transcription engine and never leave your Mac — note they currently apply on the whisper.cpp engine only (WhisperKit ignores the term prompt today). Surrounding text is gated to local cleanup providers (Built-in or your own local LLM) — with OpenAI or an agent CLI selected, no surrounding text is shared. Agent-initiated dictations never read screen context.")
        }
    }

    /// Friendly name for a bundle ID from a running app, else the bundle ID.
    private func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        return bundleID
    }

    private func removeAllowedApp(_ bundleID: String) {
        appState.screenContext.allowedBundleIDs.removeAll { $0 == bundleID }
        screenContextAddMessage = "Removed \(displayName(for: bundleID))."
    }

    /// Add the last-used regular app (the one focused before Settings opened), so
    /// the user can allowlist "the app I was just typing in" in one click.
    private func addAllowedFrontmostApp() {
        let candidate = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !$0.isActive
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard let app = candidate, let bid = app.bundleIdentifier else {
            screenContextAddMessage = "Couldn't determine the last-used app."
            return
        }
        let name = app.localizedName ?? bid
        if appState.screenContext.allowedBundleIDs.contains(bid) {
            screenContextAddMessage = "“\(name)” is already allowed."
            return
        }
        appState.screenContext.allowedBundleIDs.append(bid)
        screenContextAddMessage = "Allowed “\(name)”."
    }

    // MARK: - Privacy summary

    private var summarySection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: appState.sendsTextToCloud ? "wifi" : "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(appState.sendsTextToCloud ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.privacyStatusText)
                        .font(.headline)
                        .foregroundColor(appState.sendsTextToCloud ? .orange : .green)
                    Text(appState.sendsTextToCloud
                         ? "Final transcripts are sent to OpenAI for AI cleanup. Change the provider in Cleanup › AI Cleanup to keep everything local."
                         : "Transcription and cleanup run entirely on this Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            PermissionRow(
                name: "Microphone",
                statusLabel: appState.microphonePermissionLabel,
                actionLabel: "Open Settings…",
                action: { appState.openMicrophonePrivacySettings() }
            )
            PermissionRow(
                name: "Speech Recognition",
                statusLabel: appState.speechPermissionLabel,
                actionLabel: "Open Settings…",
                action: { appState.openSpeechRecognitionPrivacySettings() }
            )
            PermissionRow(
                name: "Accessibility",
                statusLabel: appState.accessibilityPermissionLabel,
                actionLabel: appState.accessibilityPermissionLabel == "Granted" ? nil : "Request",
                action: {
                    appState.requestAccessibilityPermission()
                    appState.openAccessibilitySettings()
                }
            )
            PermissionRow(
                name: "Input Monitoring",
                statusLabel: appState.inputMonitoringPermissionLabel,
                actionLabel: "Open Settings…",
                action: { appState.openInputMonitoringSettings() }
            )
        } header: {
            Text("Permissions")
        } footer: {
            SettingsFootnote("Input Monitoring (the “OpenWhisp would like to receive keystrokes” prompt) lets OpenWhisp detect your push-to-talk key. Keystrokes are only checked against your chosen hotkey — never logged, stored, or sent anywhere.")
        }
    }

    // MARK: - Troubleshooting

    /// Recovery tools, not permissions — a small row beneath.
    private var troubleshootingSection: some View {
        Section {
            LabeledContent("Hotkey monitor") {
                Button("Retry") { appState.retryHotkeyMonitor() }
            }
            LabeledContent("Running app") {
                HStack(spacing: 8) {
                    Text(appState.runningBundlePath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Reveal in Finder") { appState.revealRunningApp() }
                }
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            SettingsFootnote("If the hotkey stopped responding after granting Input Monitoring, click Retry. macOS ties permissions to the app's location on disk — if you moved OpenWhisp, re-grant them for the copy shown above.")
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            SubtitledToggle(
                "Keep transcription history",
                subtitle: "Stores your recent transcriptions on this Mac (history.json); the list shows the last 15. When AI cleanup changed your words, use the revert button to restore the original. Nothing is recorded while a password field is focused.",
                isOn: $appState.historyEnabled
            )

            // MAK-40: opt-in raw-audio retention + on-device retention policy.
            SubtitledToggle(
                "Keep raw audio for re-transcription",
                subtitle: "Opt-in. Saves each dictation's audio on this Mac so you can re-transcribe it later (e.g. after switching models). Audio never leaves this device. Turning this off deletes every saved clip.",
                isOn: $appState.retainRawAudioEnabled
            )
            if appState.retainRawAudioEnabled {
                Stepper(
                    "Keep at most \(appState.audioRetentionMaxClips) clips",
                    value: $appState.audioRetentionMaxClips,
                    in: 0...500,
                    step: 10
                )
                Stepper(
                    appState.audioRetentionDays == 0
                        ? "Delete audio + history after: never"
                        : "Delete audio + history after: \(appState.audioRetentionDays) days",
                    value: $appState.audioRetentionDays,
                    in: 0...365,
                    step: 1
                )
            }

            if appState.history.isEmpty {
                Text("No transcriptions yet. Recent dictations will appear here.")
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
                        // MAK-35: revert to the raw pre-cleanup words. Shown only
                        // when the AI pass actually changed the text (revertTarget
                        // != nil) — copies the originals to the clipboard.
                        if entry.revertTarget != nil {
                            Button {
                                appState.revertHistoryEntry(entry)
                            } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless)
                            .help("Revert to original — restore the exact words you dictated (before AI cleanup)")
                        }
                        // MAK-40: re-transcribe from stored audio — shown only when a
                        // retained clip for this entry still exists on disk.
                        if appState.retainedAudioURL(for: entry) != nil {
                            Button {
                                appState.reTranscribeHistoryEntry(entry)
                            } label: { Image(systemName: "waveform.badge.magnifyingglass") }
                            .buttonStyle(.borderless)
                            .help("Re-transcribe — run the saved audio through the current engine again")
                        }
                        Button {
                            appState.copyHistoryEntry(entry)
                        } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                }
                Button("Clear History", role: .destructive) {
                    appState.clearHistory()
                }
            }
        } header: {
            Text("History")
        }
    }

    private func historySubtitle(_ entry: TranscriptionEntry) -> String {
        let when = entry.date.formatted(date: .abbreviated, time: .shortened)
        if let app = entry.appName, !app.isEmpty { return "\(app) · \(when)" }
        return when
    }
}
