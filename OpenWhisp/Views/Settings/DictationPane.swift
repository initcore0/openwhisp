import SwiftUI

/// Dictation: how you start speaking and what you speak into — activation key,
/// microphone, and spoken language.
struct DictationPane: View {
    @ObservedObject var appState: AppState

    @State private var availableMics: [AudioDevice] = []

    /// EXPERIMENTAL translation-preview opt-in. Mirrors
    /// `TranslationPreviewController.isEnabled` (its own UserDefaults key, owned
    /// by the controller) rather than living on AppState — AppState is under the
    /// MAK-32 LOC ratchet and may not grow.
    @State private var translationPreviewEnabled = TranslationPreviewController.isEnabled

    var body: some View {
        Form {
            Section {
                // Quick picks for the two built-in presets plus the recorded
                // custom trigger; "Custom" is offered only once something is
                // recorded (or already selected), so the row can't dead-end.
                Picker("Trigger key", selection: $appState.triggerMode) {
                    Text("Fn (Globe)").tag("fn")
                    Text("Control + Space").tag("controlSpace")
                    if appState.triggerMode == "custom" || appState.customTrigger.isBindable {
                        Text("Custom: \(appState.customTrigger.displayName)").tag("custom")
                    }
                }

                HotkeyCaptureField(
                    current: appState.customTrigger,
                    isActive: appState.triggerMode == "custom",
                    onCapture: { keyCode, modifiers in
                        appState.setCustomTrigger(keyCode: keyCode, modifiers: modifiers)
                    },
                    // Pause the global monitor while recording, so pressing the
                    // CURRENT trigger to rebind it can't start dictation and the
                    // recording's Esc-cancel can't fire the session cancel.
                    onRecordingChanged: { recording in
                        appState.hotkeyMonitor?.isSuspendedForCapture = recording
                    }
                )

                if appState.triggerMode == "custom",
                   let conflict = appState.customTrigger.conflict(refineKey: RefineKey.from(id: appState.refineKey)) {
                    SettingsCallout(.warning, Self.conflictMessage(conflict))
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
                    SettingsFootnote("Record any key or combo above to set your own trigger, or keep a quick pick. The Refine key is configured in Cleanup › Refine. A mouse-button trigger lives in Advanced › Dictation extras.")
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
                VStack(alignment: .leading, spacing: 4) {
                    if !appState.microphoneID.isEmpty,
                       !availableMics.contains(where: { $0.uid == appState.microphoneID }) {
                        SettingsFootnote("Your saved microphone is disconnected — the system default is used until it reconnects automatically.")
                    }
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

                // Pick-time language gate (MAK-69): if the chosen engine can't
                // produce output in the fixed language the user picked, say so HERE
                // rather than at speak-time. Today only an English-only engine
                // trips this (the coarse capability table declares the shipping
                // multilingual/locale engines permissive; Parakeet's English-only
                // streaming variants are refused at start-time by
                // ParakeetLanguageGate, which knows the variant). The gate is
                // capability-driven — no engine name is hardcoded here — so a
                // future engine that narrows its coverage surfaces automatically.
                if !EngineCapabilities.allowsLanguagePick(
                    languageCode: appState.language,
                    transcriptionEngine: appState.transcriptionEngine
                ) {
                    SettingsFootnote("\(EngineCapabilities.displayName(transcriptionEngine: appState.transcriptionEngine)) only recognizes English. Choose English or Auto here, or switch engine in Models.")
                        .foregroundStyle(.orange)
                }

                // The on-device text path (Apple Translation) covers EVERY
                // engine, so with the macOS 15 floor this is effectively always
                // offered. The SAME predicate as the menu-bar row
                // (`translationOffered`), so the two surfaces can't disagree.
                if appState.translationOffered {
                    SubtitledToggle(
                        "Translate to English",
                        subtitle: "Speech in any language comes out as English text.",
                        isOn: $appState.translateToEnglish
                    )
                    // Every translated session is a text-path session now, so
                    // whenever the toggle is on the pair's language assets must
                    // be on disk. This row shows their state and owns the
                    // download (dictations never pop the consent sheet
                    // themselves).
                    if appState.translateToEnglish {
                        TranslationAssetStatusView(sourceTag: appState.language, targetTag: "en")

                        // EXPERIMENTAL. Shown under exactly the conditions the
                        // text path arms (translate on), which is precisely when
                        // the live overlay shows the SPOKEN language and English
                        // appears only at paste — the gap this preview fills.
                        // Display-only: it never writes into the document.
                        SubtitledToggle(
                            "Live translation preview (experimental)",
                            subtitle: "The dictation overlay shows a running English translation while you speak — your spoken words stay visible as a single line above it. Display-only — what gets pasted is unchanged. Needs the language assets above.",
                            isOn: $translationPreviewEnabled
                        )
                        .onChange(of: translationPreviewEnabled) {
                            TranslationPreviewController.isEnabled = translationPreviewEnabled
                        }
                    }
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

    /// User-facing warning for a custom-trigger conflict.
    static func conflictMessage(_ conflict: DictationTrigger.Conflict) -> String {
        switch conflict {
        case .bareKey:
            return "This is a single typing key with no modifier — it would fire every time you type it. Add a modifier (⌃ ⌥ ⌘) or pick a different key."
        case .systemShortcut(let name):
            return "This combo is already \(name). OpenWhisp would fight the system for it — pick another combo."
        case .refineKey:
            return "This clashes with your Refine key (Cleanup › Refine) — they'd react to the same press. Change one of them."
        case .escapeKey:
            return "Esc is the cancel key — a trigger on Esc would cancel the dictation it just started. Pick a different key."
        }
    }
}
