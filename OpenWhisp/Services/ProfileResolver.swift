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
enum ProfileResolver {
    /// The four session-scoped settings a profile can override. `nil` fields in an
    /// `AppProfile` mean "inherit the global"; this type is the fully-resolved
    /// result with every field decided.
    struct Resolved: Equatable {
        var language: String
        var translateToEnglish: Bool
        var outputMode: String
        var aiCleanupEnabled: Bool
    }

    /// The current global values a profile overrides on top of.
    struct Globals: Equatable {
        var language: String
        var translateToEnglish: Bool
        var outputMode: String
        var aiCleanupEnabled: Bool
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
    static func resolve(profile: AppProfile, over globals: Globals) -> Resolved {
        var out = Resolved(
            language: globals.language,
            translateToEnglish: globals.translateToEnglish,
            outputMode: globals.outputMode,
            aiCleanupEnabled: globals.aiCleanupEnabled
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

        return out
    }
}
