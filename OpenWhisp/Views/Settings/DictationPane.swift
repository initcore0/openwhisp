import SwiftUI

/// Dictation: how you start speaking and what you speak into — activation key,
/// microphone, and spoken language.
struct DictationPane: View {
    @ObservedObject var appState: AppState

    @State private var availableMics: [AudioDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Trigger key", selection: $appState.triggerMode) {
                    Text("Fn (Globe)").tag("fn")
                    Text("Control + Space").tag("controlSpace")
                }

                Picker("Activation style", selection: $appState.hotkeyMode) {
                    Text("Hold to talk").tag("hold")
                    Text("Hands-free (tap to lock)").tag("toggle")
                }

                if appState.hotkeyMode == "toggle" {
                    SubtitledToggle(
                        "Auto-stop after long silence",
                        subtitle: "Safety net for hands-free mode: ends a locked session after a long stretch of silence, so a forgotten session doesn't keep recording. A normal pause to think won't stop it.",
                        isOn: $appState.handsFreeSilenceAutoStop
                    )
                }

                if RefineKey.from(id: appState.refineKey).conflictsWithTrigger(appState.triggerMode) {
                    SettingsCallout(
                        .warning,
                        "Your refine key is Control, which clashes with Control + Space — refine is disabled until you change one of them (Cleanup › Refine)."
                    )
                }
            } header: {
                Text("Activation")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFootnote(appState.hotkeyHelpText + ". Some apps intercept the Fn key — switch to Control + Space if it doesn't respond.")
                    if appState.hotkeyMode == "toggle" {
                        SettingsFootnote("Hands-free: tap the key to start dictating, tap again (or press Esc) to stop. The mic stays live in between.")
                    } else {
                        SettingsFootnote("Hold to talk: dictate while the key is held. Double-tap it to lock the mic open hands-free without changing this setting.")
                    }
                    SettingsFootnote("The Refine key is configured in Cleanup › Refine.")
                }
            }

            Section {
                // Tagged by device UID (the persisted value), not list index, so the
                // highlighted row always reflects what recording actually uses —
                // even when the saved device is unplugged or the list changes.
                Picker("Input device", selection: $appState.microphoneID) {
                    Text("System Default").tag("")
                    ForEach(availableMics, id: \.uid) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                    // Saved device not currently connected: show that honestly
                    // (recording falls back to the default input) instead of
                    // highlighting a device that isn't actually selected.
                    if !appState.microphoneID.isEmpty,
                       !availableMics.contains(where: { $0.uid == appState.microphoneID }) {
                        Text("Saved microphone (disconnected)").tag(appState.microphoneID)
                    }
                }

                SubtitledToggle(
                    "Auto-boost quiet microphone",
                    subtitle: "Raises the level of soft microphones on this Mac before transcribing. Turn off if your mic is already loud or picks up background noise.",
                    isOn: $appState.autoGainEnabled
                )
            } header: {
                Text("Microphone")
            } footer: {
                if !appState.microphoneID.isEmpty,
                   !availableMics.contains(where: { $0.uid == appState.microphoneID }) {
                    SettingsFootnote("Your saved microphone is disconnected — the system default is used until it reconnects automatically.")
                }
            }

            Section {
                Picker("Spoken language", selection: $appState.language) {
                    Text("Auto Detect").tag("auto")
                    Text("English").tag("en")
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

                // Whisper engines only — Apple Speech doesn't translate.
                if appState.transcriptionEngine != "appleSpeech" {
                    SubtitledToggle(
                        "Translate to English",
                        subtitle: "Speech in any language comes out as English text.",
                        isOn: $appState.translateToEnglish
                    )
                }
            } header: {
                Text("Language")
            } footer: {
                SettingsFootnote("Auto Detect transcribes in the language you speak. Choosing a language helps accuracy when you always dictate in the same one.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .openWhispAudioDevicesChanged)) { _ in
            refreshDevices()
        }
    }

    private func refreshDevices() {
        availableMics = AudioDevice.availableInputs()
    }
}
