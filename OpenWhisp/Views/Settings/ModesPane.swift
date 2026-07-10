import SwiftUI
import Cocoa

/// Modes (MAK-39): first-class, user-authored dictation styles. Each Mode bundles a
/// stable invocation key, a tone/instruction that steer the AI refine, optional
/// model + language/output/AI-cleanup overrides, a custom SF Symbol icon, and an
/// optional app auto-activation binding. A Mode is invoked by key — from the picker
/// here, or an `openwhisp://switch-mode?key=…` / `activate-mode?key=…` URL.
///
/// Layout: an "active Mode" picker + a master list of Modes with an inline detail
/// editor, matching the sidebar/detail feel of the other panes.
struct ModesPane: View {
    @ObservedObject var appState: AppState

    @State private var selectedModeID: UUID?

    var body: some View {
        Form {
            activeSection
            listSection
            if let id = selectedModeID,
               let idx = appState.modes.firstIndex(where: { $0.id == id }) {
                editorSection(idx: idx)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Active Mode picker

    private var activeSection: some View {
        Section {
            Picker("Active mode", selection: activeModeBinding) {
                Text("None (global settings)").tag(String?.none)
                ForEach(appState.modes) { mode in
                    Text(mode.name).tag(String?.some(mode.key))
                }
            }
            SettingsFootnote(
                "The active mode governs your next dictations until you change it. " +
                "A launcher can also switch modes with openwhisp://switch-mode?key=… " +
                "(next dictation only) or activate-mode?key=… (sticky).")
        } header: {
            Text("Active")
        }
    }

    private var activeModeBinding: Binding<String?> {
        Binding(
            get: { appState.activeModeKey },
            set: { newValue in
                if let newValue { appState.selectMode(key: newValue, sticky: true) }
                else { appState.clearActiveMode() }
            }
        )
    }

    // MARK: Master list

    private var listSection: some View {
        Section {
            if appState.modes.isEmpty {
                Text("No modes yet. Add one to bundle a tone, an AI instruction, and " +
                     "optional overrides you can invoke by key.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                List(selection: $selectedModeID) {
                    ForEach(appState.modes) { mode in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: mode))
                                .frame(width: 18)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.name.isEmpty ? mode.key : mode.name)
                                Text(mode.key)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let tone = mode.tone {
                                Text(tone.label)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(mode.id)
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
            addRemoveFooter
        } header: {
            Text("Modes")
        }
    }

    private func icon(for mode: Mode) -> String {
        if let s = mode.iconSymbol, !s.isEmpty { return s }
        return mode.tone?.defaultIcon ?? "square.stack.3d.up"
    }

    private var addRemoveFooter: some View {
        HStack(spacing: 0) {
            Button {
                let n = appState.modes.count + 1
                let mode = Mode(key: "mode-\(n)", name: "Mode \(n)", tone: .casual)
                appState.modes.append(mode)
                selectedModeID = mode.id
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add mode")

            Divider().frame(height: 14)

            Button {
                if let id = selectedModeID {
                    appState.modes.removeAll { $0.id == id }
                    selectedModeID = nil
                }
            } label: {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selectedModeID == nil)
            .accessibilityLabel("Remove selected mode")

            Spacer()
        }
    }

    // MARK: Detail editor

    @ViewBuilder
    private func editorSection(idx: Int) -> some View {
        Section {
            TextField("Name", text: nameBinding(idx))
            TextField("Key (for invocation)", text: keyBinding(idx))
                .font(.system(.body, design: .monospaced))
            TextField("Icon (SF Symbol)", text: iconBinding(idx))

            Picker("Tone", selection: toneBinding(idx)) {
                Text("None").tag(Tone?.none)
                ForEach(Tone.allCases, id: \.self) { tone in
                    Text(tone.label).tag(Tone?.some(tone))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("AI instruction").font(.caption).foregroundColor(.secondary)
                TextEditor(text: instructionBinding(idx))
                    .frame(minHeight: 54)
                    .font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            }

            Picker("Language", selection: languageBinding(idx)) {
                Text("Inherit").tag("__inherit__")
                Text("Auto").tag("auto")
                Text("English").tag("en")
                Text("Russian").tag("ru")
            }
            Picker("Output", selection: outputBinding(idx)) {
                Text("Inherit").tag("__inherit__")
                Text("Preview").tag("preview")
                Text("Insert at end").tag("finalOnly")
                Text("Type live").tag("liveChunks")
            }
            Picker("AI cleanup", selection: aiBinding(idx)) {
                Text("Inherit").tag("__inherit__")
                Text("On").tag("on")
                Text("Off").tag("off")
            }

            // App auto-activation binding: when set (and per-app modes are on),
            // this Mode activates automatically when dictating into that app.
            TextField("Auto-activate for app (bundle ID)", text: appBinding(idx),
                      prompt: Text("e.g. com.apple.mail"))
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("Edit mode")
        } footer: {
            SettingsFootnote(
                "The key is normalized (lowercased, spaces → hyphens). Tone + " +
                "instruction steer the AI refine. Language/output/AI-cleanup apply " +
                "for that session; a per-mode transcription-model swap is not wired " +
                "yet (see the changelog). App auto-activation also needs per-app " +
                "modes enabled in the Dictation pane.")
        }
    }

    // MARK: Bindings

    private func nameBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { appState.modes[safe: idx]?.name ?? "" },
                set: { appState.modes[idx].name = $0 })
    }
    private func keyBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { appState.modes[safe: idx]?.key ?? "" },
                set: { appState.modes[idx].key = Mode.normalizeKey($0) })
    }
    private func iconBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { appState.modes[safe: idx]?.iconSymbol ?? "" },
                set: { appState.modes[idx].iconSymbol = $0.isEmpty ? nil : $0 })
    }
    private func instructionBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { appState.modes[safe: idx]?.instruction ?? "" },
                set: { appState.modes[idx].instruction = $0.isEmpty ? nil : $0 })
    }
    private func toneBinding(_ idx: Int) -> Binding<Tone?> {
        Binding(get: { appState.modes[safe: idx]?.tone },
                set: { appState.modes[idx].tone = $0 })
    }
    private func languageBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { appState.modes[safe: idx]?.language ?? "__inherit__" },
                set: { appState.modes[idx].language = $0 == "__inherit__" ? nil : $0 })
    }
    private func outputBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { appState.modes[safe: idx]?.outputMode ?? "__inherit__" },
                set: { appState.modes[idx].outputMode = $0 == "__inherit__" ? nil : $0 })
    }
    private func appBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { appState.modes[safe: idx]?.appBundleID ?? "" },
                set: {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.modes[idx].appBundleID = trimmed.isEmpty ? nil : trimmed
                })
    }
    private func aiBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard let v = appState.modes[safe: idx]?.aiCleanupEnabled else { return "__inherit__" }
                return v ? "on" : "off"
            },
            set: { newValue in
                switch newValue {
                case "on":  appState.modes[idx].aiCleanupEnabled = true
                case "off": appState.modes[idx].aiCleanupEnabled = false
                default:    appState.modes[idx].aiCleanupEnabled = nil
                }
            }
        )
    }
}

private extension Array {
    /// Bounds-safe subscript so a binding read never crashes if the selected row
    /// was just removed mid-update.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
