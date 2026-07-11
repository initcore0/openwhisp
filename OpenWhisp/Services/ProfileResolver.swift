import Foundation

/// Pure per-app-profile override resolution (Phase 2.5 core extraction).
///
/// When "per-app modes" is on, dictating into a given app can override the global
/// language / output-mode / AI-cleanup settings for that one session. The decision
/// of *what the effective settings become* (including the historical `"en"` →
/// translate-to-English remap) was inline on the app-only `AppState`; extracting
/// it here makes the remap and inherit-vs-override matrix `swift test`-able without
/// AppKit, and keeps AppState's apply/restore lifecycle honest against a tested
/// spec. AppState still owns the *effectful* parts (reading the frontmost app,
/// backing up globals, suppressing persistence, restoring on session end).
public enum ProfileResolver {
    /// The four session-scoped settings a profile can override. `nil` fields in an
    /// `AppProfile` mean "inherit the global"; this type is the fully-resolved
    /// result with every field decided.
    public struct Resolved: Equatable {
        public var language: String
        public var translateToEnglish: Bool
        public var outputMode: String
        public var aiCleanupEnabled: Bool
        /// The effective text-insert method (`InsertionMode` raw value) for the
        /// session — the profile's override, or the global when the profile
        /// inherits (MAK-42).
        public var insertionMode: String

        public init(language: String, translateToEnglish: Bool, outputMode: String, aiCleanupEnabled: Bool, insertionMode: String) {
            self.language = language
            self.translateToEnglish = translateToEnglish
            self.outputMode = outputMode
            self.aiCleanupEnabled = aiCleanupEnabled
            self.insertionMode = insertionMode
        }
    }

    /// The current global values a profile overrides on top of.
    public struct Globals: Equatable {
        public var language: String
        public var translateToEnglish: Bool
        public var outputMode: String
        public var aiCleanupEnabled: Bool
        /// The global text-insert method (`InsertionMode` raw value).
        public var insertionMode: String

        public init(language: String, translateToEnglish: Bool, outputMode: String, aiCleanupEnabled: Bool, insertionMode: String) {
            self.language = language
            self.translateToEnglish = translateToEnglish
            self.outputMode = outputMode
            self.aiCleanupEnabled = aiCleanupEnabled
            self.insertionMode = insertionMode
        }
    }

    /// Resolve the effective settings for `profile` layered over `globals`.
    ///
    /// Rules (identical to AppState.applyProfileForFrontmostApp):
    /// - A nil profile field inherits the global.
    /// - `profile.language == "en"` is the historical "translate to English"
    ///   selection: it maps to `language = "auto"` (source auto-detected) +
    ///   `translateToEnglish = true`. Any OTHER explicit language transcribes in
    ///   that language with `translateToEnglish = false`.
    /// - A nil `profile.language` leaves BOTH language and translateToEnglish at
    ///   their globals (the remap only fires when the profile pins a language).
    public static func resolve(profile: AppProfile, over globals: Globals) -> Resolved {
        var out = Resolved(
            language: globals.language,
            translateToEnglish: globals.translateToEnglish,
            outputMode: globals.outputMode,
            aiCleanupEnabled: globals.aiCleanupEnabled,
            insertionMode: globals.insertionMode
        )

        if let lang = profile.language {
            if lang == "en" {
                out.language = "auto"
                out.translateToEnglish = true
            } else {
                out.language = lang
                out.translateToEnglish = false
            }
        }
        if let mode = profile.outputMode { out.outputMode = mode }
        if let ai = profile.aiCleanupEnabled { out.aiCleanupEnabled = ai }
        if let insert = profile.insertionMode { out.insertionMode = insert }

        return out
    }
}
