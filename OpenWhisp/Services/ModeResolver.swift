import Foundation

/// Pure Mode selection + composition (MAK-39). Owns three decisions so they're
/// `swift test`-able without AppKit:
///
///  1. **Key lookup** — find a Mode by its (normalized) invocation key, for the
///     `openwhisp://switch-mode`/`activate-mode` verbs and the Settings picker.
///  2. **Precedence** — decide which Mode governs a dictation given an explicit
///     invocation vs. an app auto-activation binding.
///  3. **Instruction composition** — fold a Mode's tone preset and free-form
///     instruction into a single refine directive.
///
/// The *effectful* parts (reading the frontmost app, applying overrides, restoring
/// them on session end) stay on AppState, which reuses `ProfileResolver` for the
/// session-scoped language/output/AI-cleanup fields a Mode shares with AppProfile.
public enum ModeResolver {

    /// Find the Mode whose key matches `key` (both normalized). Returns nil when no
    /// Mode owns that key — the URL handler logs a miss rather than guessing.
    public static func mode(forKey key: String, in modes: [Mode]) -> Mode? {
        let target = Mode.normalizeKey(key)
        return modes.first { $0.key == target }
    }

    /// The Mode that should auto-activate for `bundleID`, if any Mode is bound to
    /// that app. First match wins (mirrors `AppProfileStore.profile(for:)`).
    public static func autoActivation(forBundleID bundleID: String?, in modes: [Mode]) -> Mode? {
        guard let bundleID else { return nil }
        return modes.first { $0.appBundleID == bundleID }
    }

    /// Decide which Mode governs the next dictation.
    ///
    /// Precedence (highest first):
    ///  1. An **explicitly invoked** Mode (`switch-mode`/`activate-mode` by key, or
    ///     a picker selection) — the user asked for it by name, so it wins even over
    ///     an app that has its own binding.
    ///  2. An **app auto-activation** Mode, when per-app modes are on and the
    ///     frontmost app is bound to a Mode.
    ///  3. Nothing → the global settings stand.
    ///
    /// - Parameters:
    ///   - explicitKey: a key the user invoked (URL/picker), or nil.
    ///   - frontmostBundleID: the app being dictated into, or nil.
    ///   - perAppModesEnabled: whether app auto-activation is allowed at all.
    ///   - modes: the registry.
    public static func resolveActive(
        explicitKey: String?,
        frontmostBundleID: String?,
        perAppModesEnabled: Bool,
        modes: [Mode]
    ) -> Mode? {
        if let explicitKey, let m = mode(forKey: explicitKey, in: modes) {
            return m
        }
        guard perAppModesEnabled else { return nil }
        return autoActivation(forBundleID: frontmostBundleID, in: modes)
    }

    /// Compose the refine instruction a Mode contributes, or nil when it steers
    /// nothing (no tone and no free-form instruction → inherit the global cleanup).
    ///
    /// Order is tone-first, then the free-form instruction, so a user's explicit
    /// note refines the preset rather than being buried before it. Both are joined
    /// with a blank line; whitespace-only parts are dropped.
    public static func refineInstruction(for mode: Mode) -> String? {
        var parts: [String] = []
        if let tone = mode.tone {
            parts.append(tone.directive)
        }
        if let instruction = mode.instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            parts.append(instruction)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
