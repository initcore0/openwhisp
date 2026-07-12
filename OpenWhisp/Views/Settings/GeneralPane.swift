import SwiftUI
import Cocoa

/// General: startup, the recording overlay, settings import/export, and reset.
struct GeneralPane: View {
    @ObservedObject var appState: AppState

    // Config import/export feedback.
    @State private var configMessage: String = ""
    // Built-in config packs (loaded from the app bundle on appear).
    @State private var configPacks: [ConfigPack] = []
    // Reset-all confirmation.
    @State private var confirmingReset = false
    // Software-update toggle mirror (Sparkle lives in the AppKit UpdaterManager,
    // not AppState; seed from its live value on appear).
    @State private var autoUpdateEnabled = UpdaterManager.shared.automaticallyChecksForUpdates

    /// Styles available to pick this build. Grows as later phases land (orb).
    private var availableIndicatorStyles: [VoiceIndicatorStyle] { [.bars, .waveform] }

    var body: some View {
        Form {
            Section {
                Toggle("Launch OpenWhisp at login", isOn: $appState.launchAtLogin)
                if appState.launchAtLoginService.requiresApproval {
                    Button("Open Login Items Settings…") {
                        appState.launchAtLoginService.openSettings()
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                SettingsFootnote("Automatically start OpenWhisp after you log in or reboot. If macOS asks you to approve it, enable OpenWhisp under System Settings › General › Login Items.")
            }

            // Software Update (Sparkle, MAK-56). Hidden entirely on a SPARKLE=0
            // lean build where the updater is a no-op stand-in.
            if UpdaterManager.shared.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: $autoUpdateEnabled)
                        .onChange(of: autoUpdateEnabled) { newValue in
                            UpdaterManager.shared.automaticallyChecksForUpdates = newValue
                        }
                    Button("Check for Updates…") {
                        UpdaterManager.shared.checkForUpdates()
                    }
                } header: {
                    Text("Software Update")
                } footer: {
                    SettingsFootnote("The update check is the only network request OpenWhisp makes on its own. It sends just your app and macOS version to fetch the release feed — no analytics, no system profile. Updates are EdDSA-signed (and, in official builds, notarized by Apple) before they install. Turn this off to check manually only.")
                }
            }

            Section {
                Toggle("Show overlay while recording", isOn: $appState.showOverlay)

                if appState.showOverlay {
                    Picker("Indicator style", selection: $appState.voiceIndicatorStyle) {
                        ForEach(availableIndicatorStyles) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }
            } header: {
                Text("Recording Overlay")
            } footer: {
                if appState.showOverlay {
                    SettingsFootnote(appState.voiceIndicatorStyle.detail)
                }
            }

            Section {
                HStack {
                    Button("Export Settings…") { exportConfig() }
                    Button("Import Settings…") { importConfig() }
                }

                if !configPacks.isEmpty {
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
                    }
                }

                if !configMessage.isEmpty {
                    SettingsFootnote(configMessage)
                }
            } header: {
                Text("Configuration")
            } footer: {
                SettingsFootnote("Export your per-app profiles, vocabulary, and command prompts to a JSON file you can back up, edit, or share. Import replaces only the sections present in the file. Packs are one-click bundles that change only what they contain.")
            }
            Section {
                Button("Reset All Settings…", role: .destructive) {
                    confirmingReset = true
                }
                .confirmationDialog(
                    "Reset all settings to their defaults?",
                    isPresented: $confirmingReset
                ) {
                    Button("Reset All Settings", role: .destructive) {
                        appState.resetAllSettings()
                        configMessage = "All settings were reset to their defaults."
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every preference goes back to its default, and per-app profiles, vocabulary, and history are cleared. Your OpenAI API key and downloaded models are kept.")
                }
            } header: {
                Text("Reset")
            } footer: {
                SettingsFootnote("A way back to a known-good state if something got misconfigured.")
            }
        }
        .formStyle(.grouped)
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
        panel.message = "Save your OpenWhisp settings (profiles, vocabulary, prompts)"
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
        panel.message = "Choose an OpenWhisp settings file to import"
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
}
