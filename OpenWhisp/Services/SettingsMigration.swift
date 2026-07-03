import Foundation

/// The slice of UserDefaults the settings migration touches, as a protocol so
/// tests run against an in-memory store.
protocol SettingsStore {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsStore {}

/// One-time, versioned migration of persisted settings across app updates.
///
/// The Settings redesign (docs/openwhisp-settings-redesign.md §6) changed three
/// defaults and split the overloaded "English — Whisper translate to English"
/// language value into `language` + `translateToEnglish`. Existing installs
/// must keep behaving exactly as configured, so before AppState reads
/// UserDefaults:
///  - installs that predate versioning get the OLD defaults written explicitly
///    for any changed-default key they never customized, and
///  - a stored `language == "en"` (the old overload meaning translate) becomes
///    `language = "auto"` + `translateToEnglish = true`.
/// Fresh installs skip straight to the new defaults.
enum SettingsMigration {
    static let versionKey = "settingsVersion"
    static let currentVersion = 3

    /// Keys whose presence marks an existing (pre-versioning) install. Every
    /// install that ran the app at least once has `didCompleteOnboarding` (set
    /// by finishing or skipping the wizard); the rest are belt-and-suspenders
    /// for profiles that somehow bypassed onboarding but changed a setting.
    static let installMarkerKeys = [
        "didCompleteOnboarding", "language", "transcriptionEngine",
        "modelName", "triggerMode", "outputMode",
    ]

    /// Old defaults for keys whose default changed in version 2. Written
    /// explicitly for existing installs that never customized them, so an
    /// update never silently changes behavior.
    static let version2PreservedDefaults: [(key: String, oldDefault: Any)] = [
        ("modelName", "tiny"),
        ("llmProvider", "openai"),
        ("restoreClipboard", false),
    ]

    static func migrate(_ store: SettingsStore) {
        let version = store.object(forKey: versionKey) as? Int ?? 0
        guard version < currentVersion else { return }
        defer { store.set(currentVersion, forKey: versionKey) }

        let isExistingInstall = installMarkerKeys.contains { store.object(forKey: $0) != nil }
        guard isExistingInstall else { return }

        if version < 2 { applyVersion2(store) }
        if version < 3 { applyVersion3(store) }
    }

    /// v2 — Settings redesign: preserve old defaults; split the language overload.
    private static func applyVersion2(_ store: SettingsStore) {
        for (key, oldDefault) in version2PreservedDefaults where store.object(forKey: key) == nil {
            store.set(oldDefault, forKey: key)
        }

        // Split the "en means translate" overload, preserving behavior exactly:
        // the old "English" choice meant translate-to-English with the source
        // language auto-detected.
        if store.object(forKey: "language") as? String == "en" {
            store.set("auto", forKey: "language")
            store.set(true, forKey: "translateToEnglish")
        }
    }

    /// v3 — refine-key and AI-provider corrections:
    /// - A stored `rightControl` refine key becomes `leftControl`: MacBook
    ///   keyboards have no right Control key at all, so the old default made
    ///   refine silently impossible there. (Anyone who genuinely uses right
    ///   Control on an external keyboard can re-pick it — it stays offered.)
    /// - While AI cleanup is OFF, a dormant non-bundled provider snaps to
    ///   "bundled" so the first enable works offline with zero setup. Never
    ///   touches an install where AI cleanup is actually on.
    private static func applyVersion3(_ store: SettingsStore) {
        if store.object(forKey: "refineKey") as? String == "rightControl" {
            store.set("leftControl", forKey: "refineKey")
        }

        let cleanupOn = store.object(forKey: "openAIEnhancementEnabled") as? Bool ?? false
        if !cleanupOn,
           let provider = store.object(forKey: "llmProvider") as? String,
           provider != "bundled" {
            store.set("bundled", forKey: "llmProvider")
        }
    }
}
