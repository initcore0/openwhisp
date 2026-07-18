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
    /// Per-app refine tone/formatting preset (MAK-77): a `RefinePreset` raw value
    /// ("verbatim","minimalCleanup","casual","formal","custom"). nil = inherit the
    /// global cleanup intensity/prompt. ADDITIVE field — profiles.json is a
    /// versioned contract with the iOS companion, so a missing key decodes as nil
    /// and old files round-trip unchanged. Stored as a string (mirroring
    /// `insertionMode`) so an unknown future value degrades to inherit, not a
    /// decode failure.
    public var refinePreset: String?
    /// Custom refine system prompt, used only when `refinePreset == "custom"`.
    public var refineCustomPrompt: String?

    /// When this profile was last edited by the user (ConfigBundle schema v3,
    /// MAK-51 WP0b). The sync merge does last-writer-wins per object by this stamp.
    /// A v2 file written before the field existed decodes to
    /// `Date(timeIntervalSince1970: 0)` so any stamped v3 edit always wins over
    /// unstamped legacy data — see ``ConfigBundle`` for the schema note.
    public var updatedAt: Date

    /// The sentinel a pre-v3 (unstamped) profile decodes to.
    public static let unstampedEpoch = Date(timeIntervalSince1970: 0)

    public init(
        id: UUID = UUID(),
        appBundleID: String,
        displayName: String,
        language: String? = nil,
        outputMode: String? = nil,
        aiCleanupEnabled: Bool? = nil,
        insertionMode: String? = nil,
        refinePreset: String? = nil,
        refineCustomPrompt: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.appBundleID = appBundleID
        self.displayName = displayName
        self.language = language
        self.outputMode = outputMode
        self.aiCleanupEnabled = aiCleanupEnabled
        self.insertionMode = insertionMode
        self.refinePreset = refinePreset
        self.refineCustomPrompt = refineCustomPrompt
        self.updatedAt = updatedAt
    }

    // Custom decoding so a profiles.json written before `updatedAt` existed still
    // decodes: the field is optional and falls back to the EPOCH (not "now") so
    // unstamped v2 data always loses the last-writer-wins race to a stamped v3
    // edit. Other keys keep their required/optional shape.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.appBundleID = try c.decode(String.self, forKey: .appBundleID)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.outputMode = try c.decodeIfPresent(String.self, forKey: .outputMode)
        self.aiCleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiCleanupEnabled)
        self.insertionMode = try c.decodeIfPresent(String.self, forKey: .insertionMode)
        // MAK-77 additive fields: absent in pre-existing files → nil (inherit).
        self.refinePreset = try c.decodeIfPresent(String.self, forKey: .refinePreset)
        self.refineCustomPrompt = try c.decodeIfPresent(String.self, forKey: .refineCustomPrompt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Return a copy stamped as edited `now`. Pure — the ``AppProfile`` editing
    /// helpers call this so every user edit advances the stamp.
    public func stamped(_ now: Date = Date()) -> AppProfile {
        var copy = self
        copy.updatedAt = now
        return copy
    }
}

// MARK: - Stamped edits (MAK-51 WP0b)
//
// Every USER edit of a profile must advance its `updatedAt` so the sync merge's
// last-writer-wins keeps the newer object. These pure array helpers are the
// funnel the ProfilesPane editor routes through so the stamp can't be forgotten.
public extension Array where Element == AppProfile {
    /// Append a profile, stamped `now`.
    func addingProfile(_ profile: AppProfile, now: Date = Date()) -> [AppProfile] {
        self + [profile.stamped(now)]
    }

    /// Remove the profile with `id`.
    func removingProfile(_ id: AppProfile.ID) -> [AppProfile] {
        filter { $0.id != id }
    }

    /// Apply `mutate` to the profile with `id`, then stamp it `now`. No-op if no
    /// profile matches. The one funnel every field edit goes through.
    func editingProfile(
        _ id: AppProfile.ID, now: Date = Date(),
        _ mutate: (inout AppProfile) -> Void
    ) -> [AppProfile] {
        guard let idx = firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        mutate(&copy[idx])
        copy[idx].updatedAt = now
        return copy
    }

    /// Stamp `now` onto every profile that decoded unstamped (pre-v3 source).
    /// Applied on a deliberate config import / pack apply so imported profiles
    /// win the next sync's LWW rather than losing to a stamped peer copy.
    func restampingUnstamped(now: Date = Date()) -> [AppProfile] {
        map { $0.updatedAt == AppProfile.unstampedEpoch ? $0.stamped(now) : $0 }
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
