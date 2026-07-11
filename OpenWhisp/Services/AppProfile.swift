import Foundation

/// A per-app override profile. When the frontmost app at dictation start matches
/// `appBundleID`, the profile's non-nil overrides are applied for that session
/// (e.g. Slack → casual + AI cleanup off; Mail → English + AI cleanup on).
///
/// Only a focused set of high-impact fields is overridable; everything else
/// falls back to the global settings.
public struct AppProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    /// Frontmost app bundle ID this profile applies to (e.g. "com.tinyspeck.slackmacgap").
    public var appBundleID: String
    /// Human-friendly name for the list (usually the app's display name).
    public var displayName: String

    /// Overrides (nil = inherit global). Stored as strings to mirror AppState.
    public var language: String?          // "auto","en",...
    public var outputMode: String?        // "finalOnly","liveChunks","preview"
    public var aiCleanupEnabled: Bool?    // overrides openAIEnhancementEnabled
    /// Per-app text-insert method override (MAK-42): an `InsertionMode` raw value
    /// ("auto","directAX","paste","appleScript"). nil = inherit the global. Lets a
    /// user force AppleScript keystroke for an Electron/VNC app that mangles the
    /// global paste/AX method, while everything else keeps the global default.
    public var insertionMode: String?

    public init(
        id: UUID = UUID(),
        appBundleID: String,
        displayName: String,
        language: String? = nil,
        outputMode: String? = nil,
        aiCleanupEnabled: Bool? = nil,
        insertionMode: String? = nil
    ) {
        self.id = id
        self.appBundleID = appBundleID
        self.displayName = displayName
        self.language = language
        self.outputMode = outputMode
        self.aiCleanupEnabled = aiCleanupEnabled
        self.insertionMode = insertionMode
    }
}

/// Loads/saves profiles as JSON in Application Support.
public enum AppProfileStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    public static func load() -> [AppProfile] {
        JSONStore.load(from: fileURL, default: [], label: "AppProfileStore")
    }

    public static func save(_ profiles: [AppProfile]) {
        JSONStore.save(profiles, to: fileURL, label: "AppProfileStore")
    }

    /// First profile matching the given bundle ID, if any.
    public static func profile(for bundleID: String?, in profiles: [AppProfile]) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles.first { $0.appBundleID == bundleID }
    }
}
