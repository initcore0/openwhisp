import SwiftUI
import Cocoa

/// Per-App Profiles: override language, output, and AI cleanup for specific
/// apps. A table + ± footer, same pattern as the Substitutions table.
struct ProfilesPane: View {
    @ObservedObject var appState: AppState

    @State private var selectedProfileID: UUID?
    @State private var profileAddMessage: String = ""

    var body: some View {
        Form {
            Section {
                SubtitledToggle(
                    "Apply per-app profiles",
                    subtitle: "Override language, output, AI cleanup, and the text-insert method for specific apps when you start dictating into them.",
                    isOn: $appState.perAppModesEnabled
                )

                if appState.profiles.isEmpty {
                    // Empty state with direction, not a blank list.
                    Text("No profiles yet. Add the app you dictate into most — for example, keep Live typing for your editor and Preview everywhere else.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                } else {
                    profilesTable
                }

                addFooter

                if !profileAddMessage.isEmpty {
                    SettingsFootnote(profileAddMessage)
                }
            } header: {
                Text("Profiles")
            } footer: {
                SettingsFootnote("“Inherit” keeps your global setting. “English” translates what you speak into English, matching the global translate option.")
            }
        }
        .formStyle(.grouped)
    }

    private var profilesTable: some View {
        Table(appState.profiles, selection: $selectedProfileID) {
            TableColumn("App") { profile in
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName.isEmpty ? profile.appBundleID : profile.displayName)
                    Text(profile.appBundleID)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            TableColumn("Language") { profile in
                Picker("", selection: languageBinding(profile.id)) {
                    Text("Inherit").tag("__inherit__")
                    Text("Auto").tag("auto")
                    Text("English").tag("en")
                    Text("Russian").tag("ru")
                }
                .labelsHidden()
            }
            TableColumn("Output") { profile in
                Picker("", selection: outputBinding(profile.id)) {
                    Text("Inherit").tag("__inherit__")
                    Text("Preview").tag("preview")
                    Text("Insert at end").tag("finalOnly")
                    Text("Type live").tag("liveChunks")
                }
                .labelsHidden()
            }
            TableColumn("AI cleanup") { profile in
                Picker("", selection: aiBinding(profile.id)) {
                    Text("Inherit").tag("__inherit__")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .labelsHidden()
            }
            TableColumn("Insert") { profile in
                Picker("", selection: insertBinding(profile.id)) {
                    Text("Inherit").tag("__inherit__")
                    Text("Auto").tag("auto")
                    Text("Direct").tag("directAX")
                    Text("Paste").tag("paste")
                    Text("AppleScript").tag("appleScript")
                }
                .labelsHidden()
            }
        }
        .frame(minHeight: 140, maxHeight: 260)
    }

    private var addFooter: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Choose App…") { chooseAppForProfile() }
                Button("Add Last-Used App") { addProfileForFrontmostApp() }
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
            .accessibilityLabel("Add profile")

            Divider().frame(height: 14)

            Button {
                if let id = selectedProfileID {
                    appState.profiles.removeAll { $0.id == id }
                    selectedProfileID = nil
                }
            } label: {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selectedProfileID == nil)
            .accessibilityLabel("Remove selected profile")

            Spacer()
        }
    }

    // MARK: - Bindings (inherit-aware, looked up by id)

    private func languageBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { appState.profiles.first(where: { $0.id == id })?.language ?? "__inherit__" },
            set: { newValue in
                guard let idx = appState.profiles.firstIndex(where: { $0.id == id }) else { return }
                appState.profiles[idx].language = newValue == "__inherit__" ? nil : newValue
            }
        )
    }

    private func outputBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { appState.profiles.first(where: { $0.id == id })?.outputMode ?? "__inherit__" },
            set: { newValue in
                guard let idx = appState.profiles.firstIndex(where: { $0.id == id }) else { return }
                appState.profiles[idx].outputMode = newValue == "__inherit__" ? nil : newValue
            }
        )
    }

    private func aiBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let v = appState.profiles.first(where: { $0.id == id })?.aiCleanupEnabled else { return "__inherit__" }
                return v ? "on" : "off"
            },
            set: { newValue in
                guard let idx = appState.profiles.firstIndex(where: { $0.id == id }) else { return }
                switch newValue {
                case "on":  appState.profiles[idx].aiCleanupEnabled = true
                case "off": appState.profiles[idx].aiCleanupEnabled = false
                default:    appState.profiles[idx].aiCleanupEnabled = nil
                }
            }
        )
    }

    private func insertBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { appState.profiles.first(where: { $0.id == id })?.insertionMode ?? "__inherit__" },
            set: { newValue in
                guard let idx = appState.profiles.firstIndex(where: { $0.id == id }) else { return }
                appState.profiles[idx].insertionMode = newValue == "__inherit__" ? nil : newValue
            }
        )
    }

    // MARK: - Adding profiles

    /// Pick any app from /Applications and add a profile for it. Reliable way to
    /// target a specific app (vs. guessing "frontmost", which is OpenWhisp itself
    /// while Settings is open).
    private func chooseAppForProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Profile"
        panel.message = "Choose an app to create a per-app profile for"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else {
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        addProfile(bundleID: bid, name: name)
    }

    /// Convenience: add a profile for the most recently used regular app (the one
    /// you were in before opening Settings).
    private func addProfileForFrontmostApp() {
        let candidate = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !$0.isActive
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard let app = candidate, let bid = app.bundleIdentifier else {
            profileAddMessage = "Couldn't determine the last-used app. Use “Choose App…” instead."
            return
        }
        addProfile(bundleID: bid, name: app.localizedName ?? bid)
    }

    /// Shared add path with explicit feedback (instead of a silent no-op).
    private func addProfile(bundleID: String, name: String) {
        if appState.profiles.contains(where: { $0.appBundleID == bundleID }) {
            profileAddMessage = "A profile for “\(name)” already exists."
            return
        }
        let profile = AppProfile(appBundleID: bundleID, displayName: name)
        appState.profiles.append(profile)
        selectedProfileID = profile.id
        profileAddMessage = "Added profile for “\(name)”."
    }
}
