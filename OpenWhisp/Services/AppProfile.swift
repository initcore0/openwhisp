import Foundation

/// A per-app override profile. When the frontmost app at dictation start matches
/// `appBundleID`, the profile's non-nil overrides are applied for that session
/// (e.g. Slack → casual + AI cleanup off; Mail → English + AI cleanup on).
///
/// Only a focused set of high-impact fields is overridable; everything else
/// falls back to the global settings.
struct AppProfile: Codable, Identifiable, Equatable {
    var id: UUID
    /// Frontmost app bundle ID this profile applies to (e.g. "com.tinyspeck.slackmacgap").
    var appBundleID: String
    /// Human-friendly name for the list (usually the app's display name).
    var displayName: String

    /// Overrides (nil = inherit global). Stored as strings to mirror AppState.
    var language: String?          // "auto","en",...
    var outputMode: String?        // "finalOnly","liveChunks","preview"
    var aiCleanupEnabled: Bool?    // overrides openAIEnhancementEnabled

    init(
        id: UUID = UUID(),
        appBundleID: String,
        displayName: String,
        language: String? = nil,
        outputMode: String? = nil,
        aiCleanupEnabled: Bool? = nil
    ) {
        self.id = id
        self.appBundleID = appBundleID
        self.displayName = displayName
        self.language = language
        self.outputMode = outputMode
        self.aiCleanupEnabled = aiCleanupEnabled
    }
}

/// Loads/saves profiles as JSON in Application Support.
enum AppProfileStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    static func load() -> [AppProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([AppProfile].self, from: data)
        } catch {
            // The file exists but is undecodable (corruption, hand-edit, version
            // skew). Move it aside instead of returning [] silently — the next
            // save would otherwise overwrite it and make the loss permanent.
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            print("[AppProfileStore] load failed: \(error); moved file to \(backup.lastPathComponent)")
            return []
        }
    }

    static func save(_ profiles: [AppProfile]) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[AppProfileStore] save failed: \(error.localizedDescription)")
        }
    }

    /// First profile matching the given bundle ID, if any.
    static func profile(for bundleID: String?, in profiles: [AppProfile]) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles.first { $0.appBundleID == bundleID }
    }
}
