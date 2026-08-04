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

            installSection
        }
        .formStyle(.grouped)
        // Re-enumerate on appear so a folder dropped into the plugins directory
        // shows up without relaunching the app.
        .onAppear { host.reload() }
    }

    private var introSection: some View {
        Section {
            SettingsFootnote(
                "Plugins are optional add-ons. Each one you enable gets its own window, "
                + "reachable from the menu bar under Plugins. They're off until you turn them on.")
        } header: {
            Text("Plugins")
        }
    }

    private var emptySection: some View {
        Section {
            Text("No plugins are available in this build.")
                .foregroundStyle(.secondary)
        } footer: {
            SettingsFootnote(
                "Plugins ship with OpenWhisp by default. This build was made with "
                + "PLUGINS=0, which leaves them out entirely.")
        }
    }

    @ViewBuilder
    private func pluginSection(_ plugin: PluginDiscovery.Discovered) -> some View {
        Section {
            SubtitledToggle(
                plugin.manifest.name,
                subtitle: plugin.manifest.summary,
                isOn: Binding(
                    get: { host.isEnabled(plugin.id) },
                    set: { host.setEnabled($0, for: plugin.id) })
            )
            .disabled(!plugin.isRunnable)

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
                LabeledContent("Open from the menu bar") {
                    Text(shortcutSubtitle(for: plugin))
                        .foregroundStyle(.secondary)
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
                + "see it listed. Installed plugins are listed but can't be loaded yet — "
                + "only plugins that ship with the app can run.")
        }
    }
}
