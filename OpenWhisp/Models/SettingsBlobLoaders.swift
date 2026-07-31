import Foundation

/// Init-time decoders for the JSON settings blobs AppState reads before its
/// injected `settingsStore` seam exists. Extracted from AppState (MAK-32 ratchet):
/// they read `UserDefaults.standard` directly and hold no AppState state, so they
/// live here and AppState calls them from its initializer.
enum SettingsBlobLoaders {

    /// Load the persisted output-target settings, defaulting to focused-app
    /// (today's behavior) when absent or unreadable.
    static func outputTargetSettings() -> OutputTargetSettings {
        guard let data = UserDefaults.standard.data(forKey: "outputTargetSettings"),
              let decoded = try? JSONDecoder().decode(OutputTargetSettings.self, from: data)
        else { return OutputTargetSettings() }
        return decoded
    }

    /// Load the persisted screen-context config, defaulting to OFF (opt-in) when
    /// absent or unreadable.
    static func screenContext() -> ScreenContextSettings {
        guard let data = UserDefaults.standard.data(forKey: "screenContextSettings"),
              let decoded = try? JSONDecoder().decode(ScreenContextSettings.self, from: data)
        else { return ScreenContextSettings.default }
        return decoded
    }
}
