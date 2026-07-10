import SwiftUI
import Cocoa

/// Privacy & Permissions: the trust anchor. The dynamic privacy indicator up
/// top, uniform permission rows, troubleshooting tools, and transcription
/// history — the most sensitive data the app writes to disk.
struct PrivacyPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            summarySection
            permissionsSection
            troubleshootingSection
            historySection
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshPermissionLabels() }
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
