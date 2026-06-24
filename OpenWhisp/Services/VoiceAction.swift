import Foundation

/// A named voice action: a set of trailing trigger phrases the user can speak to
/// run a curated transformation on their dictation (e.g. "make a telegram post").
///
/// This is the data-driven generalization of what used to be a hardcoded
/// `enum Action { case telegramPost }` plus a single editable prompt string. An
/// action is just data — id + display name + trigger phrases + LLM prompt — so
/// built-in actions and pack/user-supplied actions share one mechanism, and a
/// pack can add NEW actions (tweet, commit message, …), not only retune the
/// Telegram prompt.
///
/// Foundation-only and `Codable`, so it lives in OpenWhispCore (testable) and can
/// travel inside a `ConfigBundle`/pack later.
struct VoiceAction: Codable, Equatable, Identifiable {
    /// Stable identifier used for overlay/override (a pack with the same id
    /// replaces the built-in) and for the parser's returned match.
    var id: String
    /// Short human label for UI / status ("Telegram post").
    var displayName: String
    /// Trailing phrases (case-insensitive) that trigger this action, matched at
    /// the very end of the utterance. Include EN + RU forms as needed.
    var triggerPhrases: [String]
    /// The LLM directive applied to the remaining content when triggered.
    var prompt: String

    init(id: String, displayName: String, triggerPhrases: [String], prompt: String) {
        self.id = id
        self.displayName = displayName
        self.triggerPhrases = triggerPhrases
        self.prompt = prompt
    }
}

/// The set of voice actions in effect: built-ins overlaid with any user/pack
/// additions. Pure merge/lookup logic, unit-tested.
struct VoiceActionRegistry: Equatable {
    private(set) var actions: [VoiceAction]

    init(_ actions: [VoiceAction]) {
        self.actions = actions
    }

    /// All trigger phrases across every action, for the parser to match against.
    var allPhrases: [(phrase: String, id: String)] {
        actions.flatMap { action in
            action.triggerPhrases.map { (phrase: $0, id: action.id) }
        }
    }

    /// The action with `id`, if present.
    func action(id: String) -> VoiceAction? {
        actions.first { $0.id == id }
    }

    /// Merge `overrides` onto this registry: an override whose id matches an
    /// existing action REPLACES it (in place, preserving order); an override with
    /// a new id is APPENDED. This is how packs/imports extend the built-ins.
    func merging(_ overrides: [VoiceAction]) -> VoiceActionRegistry {
        var result = actions
        for override in overrides {
            if let idx = result.firstIndex(where: { $0.id == override.id }) {
                result[idx] = override
            } else {
                result.append(override)
            }
        }
        return VoiceActionRegistry(result)
    }
}

// MARK: - Built-in actions

extension VoiceAction {
    /// Stable id of the built-in Telegram-post action (so packs/user can override it).
    static let telegramPostID = "telegram-post"

    /// Default Telegram-post prompt: lightly shorten + rewrite + Telegram-friendly emoji.
    static let defaultTelegramPostPrompt =
        "Rewrite the user's text as a short, engaging Telegram post. "
        + "Lightly shorten and tighten it for readability, keep the original language, "
        + "meaning, names, URLs, and any code. Use a friendly, natural tone and add a few "
        + "relevant emoji that render correctly in Telegram (place them inline or at the "
        + "start of lines, do not overuse). Keep it to a few short paragraphs. "
        + "Return only the post text, with no preamble, quotes, or markdown code fences."

    /// The built-in Telegram-post action (EN + RU trigger phrases).
    static let telegramPost = VoiceAction(
        id: telegramPostID,
        displayName: "Telegram post",
        triggerPhrases: [
            "make a telegram post", "make this a telegram post", "make it a telegram post",
            "turn this into a telegram post", "telegram post", "post to telegram",
            "сделай пост для телеграм", "сделай пост для телеграма",
            "сделай телеграм пост", "пост для телеграм", "пост в телеграм",
            "оформи как пост для телеграм"
        ],
        prompt: defaultTelegramPostPrompt
    )
}

extension VoiceActionRegistry {
    /// The default set of actions shipped in the app. Packs/user overlays are
    /// merged on top of this. Always available even with no config files.
    static let builtins = VoiceActionRegistry([.telegramPost])
}
