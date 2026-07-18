import Foundation

/// The slice of the settings backing store (UserDefaults in the app) that the
/// migration AND `AppState`'s persisted-settings layer read/write through, as a
/// protocol so tests — and the iOS companion — can run against an in-memory or
/// alternate store. `object`/`set` are the primitive contract; the typed
/// accessors below mirror `UserDefaults`'s convenience readers and get default
/// implementations on top of `object(forKey:)`, so a store only has to implement
/// the two primitives to satisfy the whole protocol.
///
/// This is a versioned contract (consumed by the iOS companion, MAK-51): the key
/// names and value types flowing through here are the on-disk settings format —
/// do not rename keys or change value shapes without a migration.
public protocol SettingsStore {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)

    // Typed convenience readers (mirror UserDefaults). Default implementations
    // are provided in terms of `object(forKey:)`; `UserDefaults` overrides them
    // with its own native implementations automatically.
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    func integer(forKey defaultName: String) -> Int
    func data(forKey defaultName: String) -> Data?
    func stringArray(forKey defaultName: String) -> [String]?
}

public extension SettingsStore {
    func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }
    func bool(forKey defaultName: String) -> Bool {
        (object(forKey: defaultName) as? Bool)
            ?? (object(forKey: defaultName) as? NSNumber)?.boolValue
            ?? false
    }
    func integer(forKey defaultName: String) -> Int {
        (object(forKey: defaultName) as? Int)
            ?? (object(forKey: defaultName) as? NSNumber)?.intValue
            ?? 0
    }
    func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }
    func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }
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
    static let currentVersion = 4

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
        if version < 4 { applyVersion4(store) }
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

    /// v4 — Parakeet promoted to the default transcription engine for fresh
    /// installs. Existing installs must keep the engine they were already using:
    /// an update should never silently swap a working, already-downloaded engine
    /// (and pull a fresh ~600 MB Parakeet download) out from under someone. Any
    /// pre-v4 install that never explicitly picked an engine was running on the
    /// old default (WhisperKit, or whisper.cpp on a lean build), so we pin that
    /// old default explicitly here. An install that DID choose an engine already
    /// has `transcriptionEngine` set and is left untouched.
    private static func applyVersion4(_ store: SettingsStore) {
        guard store.object(forKey: "transcriptionEngine") == nil else { return }
        store.set(preParakeetDefaultEngine, forKey: "transcriptionEngine")
    }

    /// The default transcription engine before Parakeet took over (v4). Mirrors
    /// the build-flag fallback in `AppState.defaultTranscriptionEngine` minus the
    /// Parakeet branch, so a lean `WHISPERKIT=0` build pins whisper.cpp rather
    /// than an engine that isn't in the binary.
    static var preParakeetDefaultEngine: String {
        #if WHISPERKIT
        return "whisperKit"
        #else
        return "whisper"
        #endif
    }
}
