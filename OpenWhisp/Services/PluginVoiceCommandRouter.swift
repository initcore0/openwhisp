import Foundation

/// Routes a spoken REFINE instruction to a plugin that claims it.
///
/// ## What this is for
///
/// Refine is "apply this spoken instruction to that text". v10 adds a second
/// destination: an instruction that STARTS with a phrase a plugin declared in its
/// manifest (`PluginManifest.voiceTriggers`) is handed to that plugin instead of the
/// refine LLM. The owner's two flows:
///
/// - Select text anywhere, dictate, tap Refine, say *"create a meme based on that"* —
///   the selection is the material and the meme window is the output.
/// - Refine with nothing selected, say *"create a meme expanding brain: typing,
///   dictating, …"* — the spoken remainder is the whole input.
///
/// ## Why the matching is deliberately STRICT
///
/// A match REDIRECTS the user's dictation: the refine LLM never runs and nothing is
/// inserted into the focused app. That makes a false positive expensive — it silently
/// swallows text the user meant to keep — so the rules are the narrowest ones that
/// still serve the two flows:
///
/// - **Prefix only.** "create a meme …" routes; "…, then create a meme" does not. A
///   substring match would hijack any instruction that merely MENTIONS a meme
///   ("rewrite this so it doesn't sound like a meme").
/// - **Whole-word boundary.** "create a memo about Q3" must NOT match "create a mem"-
///   anything; the character after the phrase has to be a separator, not a letter.
///   This is the near-miss the runtime probe pins.
/// - **Exact phrases**, case- and punctuation-insensitive, with runs of whitespace
///   collapsed — dictation output varies in capitalization and trailing commas, and
///   the user should not have to hit one byte-for-byte.
/// - **No fuzzy/edit-distance matching.** Cheap to add, impossible to reason about,
///   and every false positive costs a dictation.
///
/// Non-match returns nil, and the caller runs the instruction as a NORMAL refine with
/// byte-identical behavior — the fallback is the default, not an error path.
///
/// ## Languages
///
/// Matching is language-agnostic (plain Unicode prefix comparison), so a manifest can
/// declare phrases in any language. The meme plugin ships EN + RU (`сделай мем`,
/// `создай мем`) because the owner dictates in both; adding a language is a manifest
/// edit, not a code change.
///
/// Pure and Foundation-only so `swift test` pins every rule here — this is the gate
/// that decides whether a dictation reaches the user's editor or a plugin window.
public enum PluginVoiceCommandRouter {

    /// A matched voice command: which plugin claimed it, and what was left over.
    public struct Match: Equatable, Sendable {
        /// The `PluginManifest.id` that declared the matched phrase.
        public let pluginID: String
        /// The trigger phrase that matched, normalized (useful for logging/tests).
        public let trigger: String
        /// The instruction with the trigger phrase (and any leading separator
        /// punctuation) removed — the material the plugin should act on.
        ///
        /// EMPTY is a legitimate outcome: "create a meme" on its own is a valid
        /// command whose material comes from the refine CONTENT (the user's
        /// selection) rather than from the spoken remainder.
        public let remainder: String

        public init(pluginID: String, trigger: String, remainder: String) {
            self.pluginID = pluginID
            self.trigger = trigger
            self.remainder = remainder
        }
    }

    /// The characters allowed to sit between the trigger phrase and the remainder —
    /// i.e. what proves the phrase ended on a WORD BOUNDARY.
    ///
    /// Whitespace plus the punctuation dictation actually emits after a lead-in
    /// clause. `:` matters most: the owner's own prompt is
    /// "create a meme expanding brain: typing, …", and `,`/`.`/`—` cover the rest.
    private static let boundaryCharacters = CharacterSet(charactersIn: " \t\n\r:,.;!?-—–")

    /// Ask which enabled plugin claims `instruction`, if any.
    ///
    /// - Parameters:
    ///   - instruction: the spoken refine instruction, raw from the pipeline.
    ///   - enabledPlugins: manifests of plugins that are ENABLED and runnable. The
    ///     caller passes only enabled plugins, so a disabled plugin cannot claim a
    ///     dictation — see `matchIgnoringEnablement` for the disabled-hint case.
    /// - Returns: the match, or nil to proceed as a normal refine.
    ///
    /// Ties are resolved by LONGEST trigger first, then by the order
    /// `enabledPlugins` arrives in (the same first-wins rule `PluginDiscovery` and
    /// `PluginKeyEquivalent` already use). Longest-first matters when one plugin
    /// declares "create a meme" and another "create a meme poster": the more specific
    /// phrase must win regardless of list order, or the specific plugin is
    /// unreachable.
    public static func match(
        instruction: String, enabledPlugins: [PluginManifest]
    ) -> Match? {
        let normalized = normalize(instruction)
        guard !normalized.isEmpty else { return nil }

        // (plugin index, trigger) pairs, longest trigger first so a more specific
        // phrase always beats a shorter one that prefixes it.
        let candidates = enabledPlugins.enumerated()
            .flatMap { index, manifest in
                manifest.normalizedVoiceTriggers.map { (index: index, manifest: manifest, trigger: $0) }
            }
            .sorted { lhs, rhs in
                lhs.trigger.count != rhs.trigger.count
                    ? lhs.trigger.count > rhs.trigger.count
                    : lhs.index < rhs.index
            }

        for candidate in candidates {
            guard let remainder = remainderAfterPrefix(
                candidate.trigger, in: normalized, original: instruction)
            else { continue }
            return Match(
                pluginID: candidate.manifest.id,
                trigger: candidate.trigger,
                remainder: remainder)
        }
        return nil
    }

    /// Whether `instruction` would match `manifest` if it were enabled.
    ///
    /// Exists for exactly one thing: the caller shows "… is disabled" ONLY when a
    /// disabled plugin would otherwise have claimed the instruction. Without this the
    /// hint would either never appear or appear on every unrelated refine.
    public static func matchIgnoringEnablement(
        instruction: String, plugins: [PluginManifest]
    ) -> Match? {
        match(instruction: instruction, enabledPlugins: plugins)
    }

    // MARK: - User-facing strings

    /// The overlay acknowledgment shown the moment a voice command is claimed, e.g.
    /// `"Meme Generator — creating…"`.
    ///
    /// Named after the PLUGIN, because the whole point of the acknowledgment is to
    /// tell the user WHERE their words just went: a routed dictation produces nothing
    /// in the focused app, and an overlay that still said "Refining…" would look like
    /// the refine silently ate it.
    ///
    /// It reaches the overlay through `AppState.statusMessage`, which
    /// `FinalizingCaption.resolve` already surfaces verbatim as the finalize caption —
    /// so this needs no new `OverlayPhase` case and no view change.
    public static func acknowledgment(pluginName: String) -> String {
        "\(pluginName) — creating…"
    }

    /// The one-line hint shown when a voice command matched EXACTLY but the plugin is
    /// switched off. The instruction still runs as a normal refine; this only explains
    /// why the plugin window didn't appear.
    public static func disabledHint(pluginName: String) -> String {
        "\(pluginName) plugin is disabled"
    }

    // MARK: - Rules

    /// Lowercase, collapse whitespace runs, and trim. Applied to BOTH sides so the
    /// comparison is stable against dictation's capitalization and spacing.
    ///
    /// Note this does NOT strip punctuation from the middle of the string — the
    /// boundary check handles the one place punctuation matters (right after the
    /// trigger), and stripping it wholesale would corrupt the remainder the plugin
    /// receives ("typing, dictating" is a LIST; losing the commas loses the items).
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The remainder after `prefix`, or nil when `normalized` doesn't start with it on
    /// a word boundary.
    ///
    /// The remainder is sliced from the ORIGINAL instruction (not the lowercased
    /// form) so the plugin receives the user's real words — the meme captions are
    /// rendered from this text, and lowercasing them would be visible in the output.
    private static func remainderAfterPrefix(
        _ prefix: String, in normalized: String, original: String
    ) -> String? {
        guard normalized.hasPrefix(prefix) else { return nil }

        let afterIndex = normalized.index(normalized.startIndex, offsetBy: prefix.count)
        // Exact match ("create a meme") — a valid command with no remainder.
        if afterIndex == normalized.endIndex { return "" }
        // Word boundary: the phrase must END here. "create a memo" must not match
        // "create a mem" + "o".
        guard let next = normalized[afterIndex].unicodeScalars.first,
              boundaryCharacters.contains(next) else { return nil }

        // Slice the ORIGINAL by counting the same number of significant words the
        // trigger consumed, so casing/spacing in the user's remainder is preserved.
        return originalRemainder(original: original, triggerWordCount: prefix.split(separator: " ").count)
    }

    /// Drop the first `triggerWordCount` whitespace-separated words from `original`
    /// and return what's left, minus any leading separator punctuation.
    private static func originalRemainder(original: String, triggerWordCount: Int) -> String {
        let words = original
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count > triggerWordCount else { return "" }
        let rest = words.dropFirst(triggerWordCount).joined(separator: " ")
        // The trigger's own trailing punctuation belongs to the TRIGGER, not the
        // material: "create a meme: typing, dictating" hands over "typing, dictating".
        // Only leading separators are trimmed — interior commas are the list.
        return rest.trimmingCharacters(in: boundaryCharacters)
    }
}
