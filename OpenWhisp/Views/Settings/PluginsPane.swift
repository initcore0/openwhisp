import SwiftUI

/// Settings → Plugins (docs/PLUGINS.md).
///
/// Lists every discovered plugin with an enable toggle, its network disclosure, and
/// its per-plugin configuration surface. Plugins are OPTIONAL and off by default, so
/// this pane is the only thing standing between a stock install and an extra surface.
///
/// State lives on `PluginHost` (its own defaults key), not AppState — the MAK-32
/// ratchet is at zero headroom, so this pane observes the host directly rather than
/// mirroring into `@State` the way single-key features do.
struct PluginsPane: View {

    @ObservedObject var host: PluginHost

    /// The bundled starter plugins, read when the pane appears and after each install.
    ///
    /// Held in `@State` rather than recomputed in `body` because reading it touches the
    /// filesystem twice (the pack directory and the user's plugins directory), and `body`
    /// runs on every unrelated redraw.
    @State private var starters: [PluginStarterPack.Offering] = []

    /// The refusal from the last install attempt, shown inline. Cleared on the next one.
    @State private var starterProblem: String?

    var body: some View {
        Form {
            introSection

            if host.discovered.isEmpty {
                emptySection
            } else {
                ForEach(host.discovered) { plugin in
                    pluginSection(plugin)
                }
            }

            starterSection
            installSection
        }
        .formStyle(.grouped)
        // Re-enumerate on appear so a folder dropped into the plugins directory
        // shows up without relaunching the app.
        .onAppear {
            host.reload()
            starters = host.starterOfferings
        }
    }

    private var introSection: some View {
        Section {
            SettingsFootnote(
                "Plugins are optional add-ons, reachable from the menu bar under Plugins "
                + "and by voice. Some open a window; script plugins just run their steps "
                + "on your text. They're off until you turn them on.")
        } header: {
            Text("Plugins")
        }
    }

    private var emptySection: some View {
        Section {
            Text("No plugins are installed yet.")
                .foregroundStyle(.secondary)
        } footer: {
            // Deliberately does NOT say "this build has no plugins". `PLUGINS=0` drops
            // only the COMPILED plugin surfaces; script plugins are host-executed, so a
            // lean build still installs and runs every starter below. Telling a lean-build
            // user that plugins are unavailable would be false.
            SettingsFootnote(
                "Install a starter plugin below, or drop your own folder into the plugins "
                + "folder. Built-in plugins are left out of a PLUGINS=0 build; script "
                + "plugins work either way, because OpenWhisp runs their steps itself.")
        }
    }

    @ViewBuilder
    private func pluginSection(_ plugin: PluginDiscovery.Discovered) -> some View {
        Section {
            // A script plugin's capabilities come BEFORE its toggle, because unlike a
            // built-in it was not reviewed by anyone — the manifest is the only thing
            // describing what it will do, and the user is the reviewer. Reading first,
            // then deciding, is the whole point.
            scriptDisclosures(for: plugin)

            SubtitledToggle(
                plugin.manifest.name,
                subtitle: plugin.manifest.summary,
                isOn: Binding(
                    get: { host.isEnabled(plugin.id) },
                    set: { host.setEnabled($0, for: plugin.id) })
            )
            .disabled(!plugin.isRunnable)

            // Running a shell script is its own decision, so it gets its own switch.
            // Folding it into the enable toggle would mean the user agreed to execute
            // code by agreeing to try a plugin — the two are not the same statement.
            if let consent = host.consent(for: plugin), consent.requiresScriptConsent {
                SubtitledToggle(
                    "Allow this plugin to run its script",
                    subtitle: consent.scriptConsentPrompt,
                    isOn: Binding(
                        get: { host.hasScriptConsent(plugin.id) },
                        set: { host.setScriptConsent($0, for: plugin.id) })
                )
                .disabled(!plugin.isRunnable)
            }

            // A plugin that WILL fail says so here, rather than at the moment the user
            // dictates into it and gets nothing.
            if host.isEnabled(plugin.id), let problem = host.scriptPlanProblem(for: plugin) {
                SettingsCallout(.warning, problem)
            }

            // Honest about what this build can actually run: an external plugin is
            // listed so the user knows it was found, but there is no loader yet.
            if let reason = plugin.unavailableReason {
                SettingsCallout(.warning, reason)
            }

            // The app is local-first. A plugin that reaches out says so, right next
            // to the switch that turns it on.
            if let disclosure = plugin.manifest.networkDisclosure {
                SettingsCallout(.info, disclosure)
            }

            // The clipboard is a bigger privacy fact than a network host — it routinely
            // holds passwords, tokens, and other people's messages — so a plugin that
            // receives it discloses that in the same place, before the user enables it.
            if let disclosure = plugin.manifest.clipboardDisclosure {
                SettingsCallout(.info, disclosure)
            }

            // Where to find it, and the shortcut that opens it. A shortcut the
            // user is never told about may as well not exist, and the menu row it
            // appears on is two clicks away inside a submenu.
            if host.isEnabled(plugin.id), plugin.isRunnable {
                // A script plugin has no window — the menu row RUNS it — so the label
                // says what the row actually does rather than promising a window that
                // will never appear.
                LabeledContent(
                    plugin.manifest.entry == .script
                        ? "Run from the menu bar" : "Open from the menu bar"
                ) {
                    Text(shortcutSubtitle(for: plugin))
                        .foregroundStyle(.secondary)
                }

                if !plugin.manifest.normalizedVoiceTriggers.isEmpty {
                    LabeledContent("Voice command") {
                        Text("“\(plugin.manifest.normalizedVoiceTriggers[0]) …”")
                            .foregroundStyle(.secondary)
                    }
                }

                configuration(for: plugin)
            }
        } header: {
            Label(plugin.manifest.name, systemImage: plugin.manifest.symbol)
        } footer: {
            SettingsFootnote(
                "Version \(plugin.manifest.version) · "
                + (plugin.source == .builtIn ? "Built in" : "Installed"))
        }
    }

    /// What a script plugin will do, stated before the user turns it on.
    ///
    /// The strings come from `PluginConsent`, which `swift test` pins, rather than being
    /// composed here: a privacy-facing disclosure the view could quietly reword is not a
    /// disclosure. Same reasoning as `networkDisclosure` and `clipboardDisclosure`.
    @ViewBuilder
    private func scriptDisclosures(for plugin: PluginDiscovery.Discovered) -> some View {
        if let consent = host.consent(for: plugin), !consent.disclosures.isEmpty {
            ForEach(consent.disclosures, id: \.self) { line in
                // A shell script is the one capability that can do anything at all, so
                // it reads as a warning while the rest are statements of fact.
                SettingsCallout(
                    consent.requiresScriptConsent && line == consent.disclosures.first
                        ? .warning : .info,
                    line)
            }
        }
    }

    /// "Plugins › Meme Generator (⌘M)" — the GRANTED shortcut, not the requested one.
    ///
    /// Resolved through the same `PluginKeyEquivalent.assign` pass the menu itself
    /// uses, over the same active-plugin list, so the pane can never advertise a
    /// shortcut the menu refused on a collision. Advertising a key that does nothing
    /// would be worse than saying nothing at all.
    private func shortcutSubtitle(for plugin: PluginDiscovery.Discovered) -> String {
        let granted = PluginKeyEquivalent.assign(
            requests: host.activePlugins.map { ($0.id, $0.manifest.keyEquivalent) })
        guard let key = granted[plugin.id] else { return "Plugins › \(plugin.manifest.name)" }
        return "Plugins › \(plugin.manifest.name)  ⌘\(key.uppercased())"
    }

    /// A plugin's own configuration surface.
    ///
    /// Today this is a fixed switch on the plugin id — the honest shape while every
    /// plugin ships in this repo and is reviewed with it. The next step is for the
    /// manifest to declare its settings schema (or the plugin to vend its own view),
    /// which is exactly the part that gets hard once plugins are third-party.
    @ViewBuilder
    private func configuration(for plugin: PluginDiscovery.Discovered) -> some View {
        if plugin.id == PluginRegistry.memeGenerator.id {
            LabeledContent("Language model") {
                Text("Follows Settings → Cleanup")
                    .foregroundStyle(.secondary)
            }
            SettingsFootnote(
                "The meme generator uses your configured cleanup model to turn a spoken "
                + "description into a template choice and captions. Captions are drawn on "
                + "your Mac — only the blank template image is downloaded.")
        }
    }

    /// Settings → Plugins → **Starter plugins** (MAK-101).
    ///
    /// The pack ships inside the app bundle, but installing one is a real COPY into
    /// `~/Library/Application Support/OpenWhisp/Plugins/` — the same path a third-party
    /// plugin takes. Two reasons that matters more than a bundled read-only tier would:
    /// it dogfoods the install route rather than leaving it exercised only by its author,
    /// and it makes the installed plugin the user's own editable folder.
    ///
    /// The section hides itself once every starter is installed, rather than lingering as
    /// a list of dead buttons.
    @ViewBuilder
    private var starterSection: some View {
        if !starters.isEmpty {
            Section {
                if let starterProblem {
                    SettingsCallout(.warning, starterProblem)
                }

                ForEach(starters) { offering in
                    starterRow(offering)
                }
            } header: {
                Label("Starter plugins", systemImage: "shippingbox")
            } footer: {
                SettingsFootnote(
                    "These ship with OpenWhisp and install into your plugins folder — the "
                    + "same folder any other plugin goes in. Once installed a plugin is "
                    + "yours: edit its manifest.json to change what it does. Installing "
                    + "never overwrites a folder you already have, and every starter is "
                    + "still off until you turn it on above.")
            }
        }
    }

    private func starterRow(_ offering: PluginStarterPack.Offering) -> some View {
        LabeledContent {
            if offering.isInstalled {
                // Not a disabled button: "already installed" is the ordinary outcome, and
                // a greyed-out Install reads as something broken rather than something
                // done.
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Install") {
                    starterProblem = host.installStarter(offering)
                    starters = host.starterOfferings
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(offering.manifest.name)
                    Text(offering.manifest.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                // The manifest's own SF Symbol, so a starter row looks like the plugin
                // row it becomes once installed.
                Image(systemName: offering.manifest.symbol)
            }
        }
    }

    private var installSection: some View {
        Section {
            HStack {
                Text("Plugins folder")
                Spacer()
                Button("Show in Finder") {
                    let dir = PluginHost.externalDirectory
                    try? FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        } header: {
            Text("Installing plugins")
        } footer: {
            SettingsFootnote(
                "Drop a plugin folder containing manifest.json here and reopen this pane to "
                + "see it listed — no rebuild or relaunch. Installed plugins run as script "
                + "plugins (\"entry\": \"script\"): a list of steps OpenWhisp performs for "
                + "them, so they can only do what you see disclosed above. A folder claiming "
                + "to be built in is listed but never run.")
        }
    }
}
