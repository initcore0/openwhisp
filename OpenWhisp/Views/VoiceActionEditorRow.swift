import SwiftUI

/// One editable row in the voice-action editor: name, trigger phrases (one per
/// line), and the AI prompt. Built-ins show a "Reset to built-in"; custom actions
/// show "Delete". Edits are held locally and committed via `onSave` (so a partial
/// edit doesn't churn the registry on every keystroke); Save is enabled only when
/// the row is valid and actually changed.
struct VoiceActionEditorRow: View {
    let action: VoiceAction
    let isBuiltin: Bool
    /// True if this id currently has a custom override (edited built-in or user action).
    let isModified: Bool
    let onSave: (VoiceAction) -> Void
    let onReset: () -> Void
    let onDelete: () -> Void

    @State private var displayName: String = ""
    @State private var phrasesText: String = ""
    @State private var prompt: String = ""
    @State private var loadedID: String = ""

    private var editedPhrases: [String] {
        phrasesText
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var edited: VoiceAction {
        VoiceAction(id: action.id, displayName: displayName.trimmingCharacters(in: .whitespaces),
                    triggerPhrases: editedPhrases, prompt: prompt)
    }

    private var isValid: Bool {
        !edited.displayName.isEmpty && !editedPhrases.isEmpty
        && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var isDirty: Bool { edited != action }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)

                Text("Trigger phrases (one per line)")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $phrasesText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 54, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                Text("AI prompt")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70, maxHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                HStack {
                    Button("Save") { onSave(edited) }
                        .disabled(!isValid || !isDirty)
                    if isBuiltin {
                        Button("Reset to built-in", role: .destructive) { onReset(); reload() }
                            .disabled(!isModified)
                    } else {
                        Button("Delete", role: .destructive) { onDelete() }
                    }
                    Spacer()
                    if !isValid {
                        Text("Needs a name, ≥1 phrase, and a prompt")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(action.displayName).fontWeight(.medium)
                if isBuiltin {
                    Text(isModified ? "built-in · edited" : "built-in")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .onAppear { reloadIfNeeded() }
        // If the underlying action changes (e.g. reset/import), refresh local state.
        .onChange(of: action) { _, _ in reloadIfNeeded(force: true) }
    }

    private func reloadIfNeeded(force: Bool = false) {
        if force || loadedID != action.id { reload() }
    }
    private func reload() {
        displayName = action.displayName
        phrasesText = action.triggerPhrases.joined(separator: "\n")
        prompt = action.prompt
        loadedID = action.id
    }
}
