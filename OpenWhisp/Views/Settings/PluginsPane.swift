import SwiftUI

/// Settings → Plugins (spike/plugin-system).
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
                "In-repo plugins are compiled in with PLUGINS=1 ./build.sh.")
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
            // listed so the user knows it was found, but the spike has no loader.
            if let reason = plugin.unavailableReason {
                SettingsCallout(.warning, reason)
            }

            // The app is local-first. A plugin that reaches out says so, right next
            // to the switch that turns it on.
            if let disclosure = plugin.manifest.networkDisclosure {
                SettingsCallout(.info, disclosure)
            }

            if host.isEnabled(plugin.id), plugin.isRunnable {
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

    /// A plugin's own configuration surface.
    ///
    /// In the spike this is a fixed switch on the plugin id — the honest shape for a
    /// prototype with one plugin. A real system would have the manifest declare its
    /// settings schema (or the plugin vend its own view), which is exactly the part
    /// that gets hard once plugins are third-party.
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
                + "see it listed. This prototype lists installed plugins but can't load them — "
                + "only plugins that ship with the app can run.")
        }
    }
}
