import SwiftUI
import Cocoa

/// Rules: the post-completion trigger/rules engine (MAK-43). A list of user rules,
/// each a match (hook + text pattern + app scope + session mode) → ordered actions
/// that reuse the existing output sinks (file / Shortcut / webhook), the hardened
/// shell runner, a snippet insert, or opening a URL.
///
/// App-only SwiftUI (build.sh glob). All decision logic lives in the pure, tested
/// `Rules.swift` core; this pane only edits the `RuleSet` on `AppState`, which
/// persists it via `RuleStore`.
struct RulesPane: View {
    @ObservedObject var appState: AppState

    /// The rule currently open in the editor sheet (nil = no sheet).
    @State private var editing: Rule?
    /// A fresh unsaved rule shown in the editor when the user taps "＋".
    @State private var isAddingNew = false

    var body: some View {
        Form {
            introSection
            rulesListSection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            RuleEditorView(
                rule: rule,
                isNew: isAddingNew,
                onSave: { saved in save(saved); editing = nil },
                onCancel: { editing = nil }
            )
            .frame(minWidth: 520, minHeight: 560)
        }
    }

    // MARK: - Intro

    private var introSection: some View {
        Section {
            Button {
                var rule = Rule()
                rule.name = "New rule"
                isAddingNew = true
                editing = rule
            } label: {
                Label("Add rule", systemImage: "plus")
            }
        } header: {
            Text("Rules")
        } footer: {
            SettingsFootnote("When a dictation finishes, OpenWhisp runs your rules as a side channel — matching ones fire their actions (append to a file, run a Shortcut, POST a webhook, run a script, open a URL, insert a snippet). Rules never change or delay what gets typed: if an action fails, only that action is skipped. Actions run on agent-bridge sessions only when a rule explicitly opts in.")
        }
    }

    // MARK: - Rules list

    private var rulesListSection: some View {
        Section {
            if appState.ruleSet.rules.isEmpty {
                Text("No rules yet. Add one to route or archive a finished dictation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(appState.ruleSet.rules) { rule in
                    ruleRow(rule)
                }
            }
        } header: {
            Text("Your rules")
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: Rule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding(for: rule))
                .labelsHidden()
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                    .fontWeight(.medium)
                    .foregroundColor(rule.isEnabled ? .primary : .secondary)
                Text(summary(for: rule))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Edit") { isAddingNew = false; editing = rule }
            Button {
                delete(rule)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this rule")
        }
        .padding(.vertical, 2)
    }

    /// A one-line human summary of a rule's trigger + actions.
    private func summary(for rule: Rule) -> String {
        let hook = rule.hook == .transcribeComplete ? "after transcribe" : "after refine"
        let match: String
        switch rule.match.kind {
        case .always:   match = "always"
        case .exact:    match = "text = \u{201C}\(rule.match.pattern)\u{201D}"
        case .prefix:   match = "starts with \u{201C}\(rule.match.pattern)\u{201D}"
        case .contains: match = "contains \u{201C}\(rule.match.pattern)\u{201D}"
        case .regex:    match = "regex /\(rule.match.pattern)/"
        }
        let actions = rule.actions.map(Self.actionLabel).joined(separator: ", ")
        let scope = (rule.appScope.bundleID?.isEmpty == false) ? " · \(rule.appScope.bundleID!)" : ""
        return "\(hook) · \(match)\(scope) → \(actions.isEmpty ? "no actions" : actions)"
    }

    static func actionLabel(_ action: RuleAction) -> String {
        switch action {
        case .insertSnippet: return "insert snippet"
        case .openURL:       return "open URL"
        case .runShell:      return "run script"
        case .runShortcut:   return "run Shortcut"
        case .postWebhook:   return "POST webhook"
        case .appendFile:    return "append file"
        }
    }

    // MARK: - Mutations

    private func enabledBinding(for rule: Rule) -> Binding<Bool> {
        Binding(
            get: { appState.ruleSet.rules.first { $0.id == rule.id }?.isEnabled ?? false },
            set: { newValue in
                guard let idx = appState.ruleSet.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                appState.ruleSet.rules[idx].isEnabled = newValue
            }
        )
    }

    private func save(_ rule: Rule) {
        if let idx = appState.ruleSet.rules.firstIndex(where: { $0.id == rule.id }) {
            appState.ruleSet.rules[idx] = rule
        } else {
            appState.ruleSet.rules.append(rule)
        }
    }

    private func delete(_ rule: Rule) {
        appState.ruleSet.rules.removeAll { $0.id == rule.id }
    }
}

// MARK: - Editor

/// A modal editor for one `Rule`: name, hook, match, app scope, session mode, and
/// the ordered action list. Edits a local copy and hands it back on Save so a
/// Cancel discards cleanly.
private struct RuleEditorView: View {
    @State var rule: Rule
    let isNew: Bool
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Rule") {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.isEnabled)
                }

                Section("Trigger") {
                    Picker("Fires", selection: $rule.hook) {
                        Text("After transcribe (pre-refine)").tag(RuleHook.transcribeComplete)
                        Text("After refine (final text)").tag(RuleHook.llmComplete)
                    }
                    Picker("Match", selection: $rule.match.kind) {
                        Text("Always").tag(RuleMatchKind.always)
                        Text("Exact").tag(RuleMatchKind.exact)
                        Text("Starts with").tag(RuleMatchKind.prefix)
                        Text("Contains").tag(RuleMatchKind.contains)
                        Text("Regex").tag(RuleMatchKind.regex)
                    }
                    if rule.match.kind != .always {
                        TextField("Pattern", text: $rule.match.pattern)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                    }
                    TextField("App bundle ID (optional, e.g. com.apple.Notes)", text: appScopeBinding)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                    Picker("Sessions", selection: $rule.sessionMode) {
                        Text("Dictation only").tag(RuleSessionMode.dictation)
                        Text("Agent only").tag(RuleSessionMode.agent)
                        Text("Both").tag(RuleSessionMode.any)
                    }
                    if rule.sessionMode != .dictation {
                        SettingsFootnote("This rule can fire on agent-bridge sessions — the agent's transcript will reach the actions below.")
                    }
                }

                actionsSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isNew ? "Add rule" : "Save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.actions.isEmpty)
            }
            .padding(12)
        }
    }

    private var appScopeBinding: Binding<String> {
        Binding(
            get: { rule.appScope.bundleID ?? "" },
            set: { rule.appScope.bundleID = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Actions editor

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            ForEach(Array(rule.actions.enumerated()), id: \.offset) { index, action in
                actionEditor(index: index, action: action)
            }
            Menu {
                Button("Insert snippet") { rule.actions.append(.insertSnippet(text: "")) }
                Button("Open URL") { rule.actions.append(.openURL(template: "")) }
                Button("Run script") { rule.actions.append(.runShell(scriptPath: "")) }
                Button("Run Shortcut") { rule.actions.append(.runShortcut(name: "")) }
                Button("POST webhook") { rule.actions.append(.postWebhook(config: WebhookConfig(url: ""))) }
                Button("Append to file") { rule.actions.append(.appendFile(config: FileOutputConfig(path: ""))) }
            } label: {
                Label("Add action", systemImage: "plus")
            }
        } header: {
            Text("Actions")
        } footer: {
            SettingsFootnote("Actions run in order. The transcript is sent to script / Shortcut / webhook / file actions on stdin or as JSON — never interpolated into a shell command. In an Open-URL template, {{text}} is replaced by the percent-encoded transcript.")
        }
    }

    @ViewBuilder
    private func actionEditor(index: Int, action: RuleAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(RulesPane.actionLabel(action)).fontWeight(.medium)
                Spacer()
                Button {
                    rule.actions.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            actionFields(index: index, action: action)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionFields(index: Int, action: RuleAction) -> some View {
        switch action {
        case .insertSnippet(let text):
            TextField("Snippet text", text: bind(index, get: { text }, set: { .insertSnippet(text: $0) }))
                .textFieldStyle(.roundedBorder)
        case .openURL(let template):
            TextField("https://example.com/?q={{text}}", text: bind(index, get: { template }, set: { .openURL(template: $0) }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
        case .runShell(let path):
            TextField("/path/to/executable", text: bind(index, get: { path }, set: { .runShell(scriptPath: $0) }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
        case .runShortcut(let name):
            TextField("Shortcut name", text: bind(index, get: { name }, set: { .runShortcut(name: $0) }))
                .textFieldStyle(.roundedBorder)
        case .postWebhook(let config):
            TextField("https://example.com/webhook", text: bind(index, get: { config.url }, set: {
                var c = config; c.url = $0; return .postWebhook(config: c)
            }))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled(true)
        case .appendFile(let config):
            TextField("~/notes/dictations.md", text: bind(index, get: { config.path }, set: {
                var c = config; c.path = $0; return .appendFile(config: c)
            }))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled(true)
        }
    }

    /// A string binding that reads the current field value and, on set, rewrites the
    /// action at `index` via `set`.
    private func bind(_ index: Int, get: @escaping () -> String, set: @escaping (String) -> RuleAction) -> Binding<String> {
        Binding(
            get: get,
            set: { newValue in
                guard rule.actions.indices.contains(index) else { return }
                rule.actions[index] = set(newValue)
            }
        )
    }
}
