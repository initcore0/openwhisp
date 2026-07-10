import Foundation

/// Static, code-defined catalog of OpenWhisp's user-facing features for the
/// "Tips & Commands" cheat sheet, the onboarding "What's next" card, and the
/// rotating first-run overlay hints (MAK-25).
///
/// Foundation-only so it lives in OpenWhispCore and is unit-tested independently of
/// AppKit/SwiftUI — the menu window, onboarding card, and overlay just render these
/// values. The content is a TRUTH CONTRACT, mirroring the changelog's `availability`
/// rule: every entry here describes only what the running app actually does today,
/// and every Settings path is the real one. Nothing aspirational — if a feature
/// isn't wired, it doesn't appear here (it goes in the changelog as `coming-soon`).
enum TipsCatalog {

    // MARK: - Cheat-sheet groups

    /// A named group of related cheat-sheet rows (e.g. "Voice editing", "Formatting").
    struct Group: Equatable {
        let title: String
        /// One short line describing what the group is for.
        let subtitle: String
        let rows: [Row]
    }

    /// One cheat-sheet row: a thing you can do, how to invoke it, and where to turn
    /// it on if it's off by default.
    struct Row: Equatable {
        /// What you say or do — the invocation ("say “scratch that”", "double-tap Fn").
        let invocation: String
        /// The plain result / what it does.
        let effect: String
        /// The real Settings path to enable/configure it, or nil if always on.
        let settingsPath: String?
    }

    /// The full cheat sheet, grouped. Sourced from the shipped feature set
    /// (changelog `availability: "live"` entries + the Settings panes). Order is
    /// roughly most-reached-for first.
    static let groups: [Group] = [
        Group(
            title: "Voice editing",
            subtitle: "Fix a misspoken phrase without deleting and re-dictating (Preview mode, on-device, no AI).",
            rows: [
                Row(invocation: "say “scratch that”",
                    effect: "Drops the last thing you said.",
                    settingsPath: "Settings › Output › Delivery → “Preview, then insert”; “Spoken edit commands” on"),
                Row(invocation: "say “delete last word”",
                    effect: "Removes the last word.",
                    settingsPath: nil),
                Row(invocation: "say “delete last sentence”",
                    effect: "Removes the last sentence.",
                    settingsPath: nil),
                Row(invocation: "say “new paragraph” / “new line”",
                    effect: "Inserts a paragraph or line break.",
                    settingsPath: nil),
                Row(invocation: "say “undo”",
                    effect: "Reverses the last voice edit.",
                    settingsPath: nil),
            ]
        ),
        Group(
            title: "Hands-free dictation",
            subtitle: "Lock the mic open so you can speak without holding a key.",
            rows: [
                Row(invocation: "double-tap your trigger key",
                    effect: "Locks the mic open for one session; tap again or press Esc to stop.",
                    settingsPath: "Settings › Dictation › Activation › “Activation style” → “Hands-free (tap to lock)” (or just double-tap)"),
                Row(invocation: "press Esc while locked",
                    effect: "Stops and discards the locked session.",
                    settingsPath: nil),
            ]
        ),
        Group(
            title: "Spoken formatting",
            subtitle: "Turn spoken structure into clean text, on-device, no LLM. Each group is off by default.",
            rows: [
                Row(invocation: "say “five dollars” / “ten cents”",
                    effect: "→ $5 / 10¢",
                    settingsPath: "Settings › Cleanup › Formatting › Currency"),
                Row(invocation: "say “twenty twenty six”",
                    effect: "→ 2026 (spoken times like “ten thirty” are left alone).",
                    settingsPath: "Settings › Cleanup › Formatting › Numbers and years"),
                Row(invocation: "say “bullet buy milk” / “number one …”",
                    effect: "→ - buy milk / 1. …",
                    settingsPath: "Settings › Cleanup › Formatting › Spoken lists"),
                Row(invocation: "say “heading intro” / “bold ship it”",
                    effect: "→ # intro / **ship it**",
                    settingsPath: "Settings › Cleanup › Formatting › Markdown commands"),
            ]
        ),
        Group(
            title: "File @-mentions (Cursor & Windsurf)",
            subtitle: "Say a filename and OpenWhisp writes an @-mention so your editor's autocomplete pops up.",
            rows: [
                Row(invocation: "say “main dot t s”",
                    effect: "→ @main.ts (only while Cursor/Windsurf is frontmost).",
                    settingsPath: "Settings › Cleanup › Formatting › “Enable file tagging in code editors”"),
                Row(invocation: "say “at main”",
                    effect: "→ @main (a bare mention).",
                    settingsPath: nil),
            ]
        ),
        Group(
            title: "AI cleanup",
            subtitle: "Choose how much the AI reshapes your words; your raw transcript is always kept.",
            rows: [
                Row(invocation: "pick a cleanup level",
                    effect: "None (verbatim), Low, Medium, or High polish.",
                    settingsPath: "Settings › Cleanup › Automatic Cleanup"),
                Row(invocation: "click Revert (↺)",
                    effect: "Restores your exact raw words — in the post-dictation overlay or in History.",
                    settingsPath: "Settings › Privacy › History"),
                Row(invocation: "use a coding-agent CLI as the engine",
                    effect: "Reuse claude / codex to clean up each dictation with your own subscription.",
                    settingsPath: "Settings › Cleanup › AI Model → “Agent CLI (Claude / Codex)”"),
            ]
        ),
        Group(
            title: "Output targets",
            subtitle: "Route the final transcript somewhere other than the focused app. Fails open — your words are never dropped.",
            rows: [
                Row(invocation: "send to a file",
                    effect: "Append each dictation to a Markdown/text file (e.g. your daily note).",
                    settingsPath: "Settings › Output › Output target › File"),
                Row(invocation: "send to a Shortcut",
                    effect: "Run any macOS Shortcut with your transcript as input.",
                    settingsPath: "Settings › Output › Output target › Shortcut"),
                Row(invocation: "send to a webhook",
                    effect: "POST { text, language, app, timestamp } as JSON to a URL.",
                    settingsPath: "Settings › Output › Output target › Webhook"),
            ]
        ),
        Group(
            title: "Launcher & automation",
            subtitle: "Drive OpenWhisp from Raycast, Alfred, Shortcuts, or a script.",
            rows: [
                Row(invocation: "open \"openwhisp://record\"",
                    effect: "Start/stop dictation from any launcher.",
                    settingsPath: nil),
                Row(invocation: "open \"openwhisp://refine?instruction=make%20it%20formal\"",
                    effect: "Rewrite your last result onto the clipboard.",
                    settingsPath: nil),
                Row(invocation: "open \"openwhisp://paste-last-result\"",
                    effect: "Paste the last result. Ready-made recipes ship in integrations/.",
                    settingsPath: nil),
            ]
        ),
        Group(
            title: "Self-learning dictionary",
            subtitle: "Star, sort by use, and accept the corrections OpenWhisp proposes — all on your Mac.",
            rows: [
                Row(invocation: "type over a misheard word",
                    effect: "OpenWhisp offers that fix as a suggested correction to accept.",
                    settingsPath: "Settings › Cleanup › Vocabulary"),
                Row(invocation: "star a rule / Sort by use",
                    effect: "Keeps your most-used substitutions at the top.",
                    settingsPath: nil),
            ]
        ),
    ]

    // MARK: - Onboarding "What's next" card

    /// One "next thing to explore" pointer shown at the end of onboarding — a title,
    /// a one-line pitch, and the real Settings path to reach it.
    struct NextStep: Equatable {
        let title: String
        let pitch: String
        let settingsPath: String
    }

    /// 2–3 features to point a brand-new user at once setup is done. Kept short and
    /// high-value; all live and reachable at the paths given.
    static let whatsNext: [NextStep] = [
        NextStep(
            title: "Voice editing",
            pitch: "Say “scratch that” or “delete last sentence” to fix a phrase without re-dictating.",
            settingsPath: "Settings › Output › Delivery → “Preview, then insert”"
        ),
        NextStep(
            title: "Hands-free mode",
            pitch: "Double-tap your trigger key to lock the mic open — speak with your hands free.",
            settingsPath: "Settings › Dictation › Activation"
        ),
        NextStep(
            title: "Tune the AI cleanup",
            pitch: "Dial how much the AI polishes your words, from verbatim to a full rewrite.",
            settingsPath: "Settings › Cleanup › Automatic Cleanup"
        ),
    ]

    // MARK: - Rotating overlay hints

    /// The short, dismissible hints rotated in the dictation overlay for a new
    /// user's first sessions. One line each, describing a real, discoverable
    /// feature. Order is the rotation order (see `HintRotation`). Each has a stable
    /// `id` so a dismissed hint stays dismissed across sessions.
    struct Hint: Equatable {
        /// Stable identifier, persisted in the dismissed set.
        let id: String
        /// The one-line tip text shown in the overlay.
        let text: String
    }

    /// The rotating hint deck. Deliberately small and concrete — each points at a
    /// feature a new user is unlikely to find on their own.
    static let hints: [Hint] = [
        Hint(id: "scratch-that",
             text: "Tip: say “scratch that” to drop the last thing you said (Preview mode)."),
        Hint(id: "hands-free",
             text: "Tip: double-tap your trigger key to lock the mic open — hands-free."),
        Hint(id: "cleanup-dial",
             text: "Tip: dial the AI cleanup from verbatim to a full polish in Settings › Cleanup."),
        Hint(id: "revert",
             text: "Tip: after a dictation, one tap reverts to your exact raw words."),
        Hint(id: "formatting",
             text: "Tip: turn on spoken formatting to say “bullet …” or “bold that” (Settings › Cleanup › Formatting)."),
        Hint(id: "output-targets",
             text: "Tip: route a dictation to a file, Shortcut, or webhook (Settings › Output)."),
    ]
}
