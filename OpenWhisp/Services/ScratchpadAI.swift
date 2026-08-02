import Foundation

/// The pure rules behind the Scratchpad's AI actions (MAK-99): what we ask the LLM
/// for, and whether we are willing to accept what it sent back.
///
/// Two actions, deliberately different in destructiveness:
///
/// - **Format as Markdown** — restructures the open note (headings, lists,
///   paragraphs) *content-preservingly* and replaces its text IN PLACE. Because it
///   overwrites something the user wrote, its acceptance test is strict: the result
///   must still contain essentially all of the source's non-whitespace characters
///   (`preservationRatio` ≥ `minPreservationRatio`). A model that "helpfully"
///   summarized instead of formatting is REJECTED and the original is kept.
/// - **Summarize** — non-destructive: the result becomes a NEW note, so the source
///   is never at risk. Its guard only rejects empty/garbage output; losing content
///   is the *point* of a summary, so no preservation check applies.
///
/// Foundation-only, so every prompt and every accept/reject decision is pinned by
/// `swift test`. The app layer owns only the LLM round-trip and the note mutation.
public enum ScratchpadAI {

    // MARK: - Actions

    /// The AI actions the Scratchpad toolbar offers.
    public enum Action: String, CaseIterable, Equatable, Sendable {
        /// Restructure the note as Markdown, replacing its text in place.
        case formatMarkdown
        /// Summarize the note into a new note.
        case summarize

        /// Menu title.
        public var title: String {
            switch self {
            case .formatMarkdown: return "Format as Markdown"
            case .summarize:      return "Summarize"
            }
        }

        /// SF Symbol for the menu row.
        public var systemImage: String {
            switch self {
            case .formatMarkdown: return "text.badge.checkmark"
            case .summarize:      return "text.line.first.and.arrowtriangle.forward"
            }
        }

        /// Status text while the request is in flight.
        public var busyLabel: String {
            switch self {
            case .formatMarkdown: return "Formatting…"
            case .summarize:      return "Summarizing…"
            }
        }

        /// Whether the action overwrites the source note (drives the strict
        /// content-preservation guard and the undo requirement).
        public var isDestructive: Bool { self == .formatMarkdown }
    }

    // MARK: - Prompts

    /// The instruction sent with the note text for a given action.
    ///
    /// Both prompts are deliberately conservative about *language*: tiny local
    /// models happily translate their input, and the Scratchpad holds dictation in
    /// whatever language the user speaks (see the LLM cleanup language guard,
    /// PR #157). Every prompt therefore pins the output language to the input's.
    public static func prompt(for action: Action) -> String {
        switch action {
        case .formatMarkdown:
            return """
            Reformat the text below as clean Markdown. Add headings, bullet lists, \
            and paragraph breaks where the structure of the content calls for them.

            Rules, in order of importance:
            1. Preserve the content EXACTLY. Do not summarize, shorten, expand, \
            reword, or omit anything. Every fact, name, number, and sentence in the \
            input must still be present in the output.
            2. Keep the original language. Do not translate.
            3. Change only formatting and layout: headings, list markers, emphasis, \
            line and paragraph breaks. You may fix obvious dictation punctuation and \
            capitalization, and you may drop filler words only when they are clearly \
            speech artifacts.
            4. Output only the reformatted Markdown. No preamble, no explanation, no \
            code fence around the whole thing.
            """
        case .summarize:
            return """
            Summarize the text below as concise Markdown.

            Rules:
            1. Lead with a short paragraph of the gist, then bullet the key points.
            2. If the text contains decisions, questions, or action items, give them \
            their own `## ` section.
            3. Keep the original language. Do not translate.
            4. Base the summary only on the text — do not invent details.
            5. Output only the summary. No preamble, no explanation.
            """
        }
    }

    /// The title for the note a `summarize` run produces: `"Summary — <source>"`.
    ///
    /// The source label is the note's list title (Markdown markers already
    /// stripped), so a source whose first line is `# Meeting — Jul 28` yields
    /// `Summary — Meeting — Jul 28` rather than leaking a stray `#`. An untitled
    /// source degrades to a bare `"Summary"` rather than `"Summary — New note"`.
    public static func summaryTitle(forSourceText sourceText: String) -> String {
        let label = ScratchpadText.listTitle(for: sourceText)
        guard !label.isEmpty, label != "New note" else { return "Summary" }
        return "Summary — " + label
    }

    /// The full body of a summary note: an H1 title line, then the summary.
    ///
    /// An H1 for the same reason the meeting/file imports use one (MAK-96): it is
    /// the note's `displayTitle` in the sidebar and renders as a title in preview.
    public static func summaryNoteText(summary: String, sourceText: String) -> String {
        let body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return "# " + summaryTitle(forSourceText: sourceText) + "\n\n" + body
    }

    // MARK: - Response guard

    /// Why a result was refused. The UI renders `reason` after "Kept original — ".
    public enum Rejection: Error, Equatable, Sendable {
        /// The model returned nothing usable (empty / whitespace only).
        case empty
        /// The model echoed a refusal or a preamble instead of doing the work.
        case notAnAnswer
        /// A to-Markdown result dropped too much of the source's content.
        case lostContent(preservedShare: Double)
        /// The model translated the note into a different writing system.
        case translated

        /// Short human reason for the status line.
        public var reason: String {
            switch self {
            case .empty:
                return "the model returned nothing"
            case .notAnAnswer:
                return "the model didn't return the text"
            case .lostContent(let share):
                return "the result dropped \(Int(((1 - share) * 100).rounded()))% of the note"
            case .translated:
                return "the result came back in a different language"
            }
        }
    }

    /// The share of the source's non-whitespace characters a to-Markdown result
    /// must retain to be accepted.
    ///
    /// 0.80 is deliberately loose: legitimate reformatting *does* lose characters —
    /// filler words ("um", "you know"), duplicated dictation artifacts, and
    /// collapsed whitespace. It is tight enough to catch the failure that actually
    /// matters, a model that summarized a long note into a paragraph.
    ///
    /// Calibrated against a realistic dictated paragraph (see
    /// `testDroppingFillerWordsIsStillAccepted`): a genuine filler-stripping
    /// reformat scores **~0.95**, the same source summarized instead scores
    /// **~0.27**. 0.80 sits in the middle of that gap, so both a stricter and a
    /// looser threshold would still separate the two — the margin, not the exact
    /// number, is what makes this safe.
    public static let minPreservationRatio: Double = 0.80

    /// How much of `source`'s content survived into `output`, as a 0...1 share.
    ///
    /// Compares **multisets of non-whitespace, case-folded characters** rather than
    /// substrings, because reformatting legitimately reorders and re-wraps text —
    /// a diff- or prefix-based check would reject correct results. Markdown's own
    /// structural markers (`#`, `-`, `*`, `>`, backtick) are excluded from both
    /// sides so *adding* them can neither inflate nor deflate the score.
    ///
    /// An empty source scores 1 (nothing to lose). A non-empty source with empty
    /// output scores 0.
    public static func preservationRatio(source: String, output: String) -> Double {
        let sourceCounts = contentCounts(source)
        let sourceTotal = sourceCounts.values.reduce(0, +)
        guard sourceTotal > 0 else { return 1 }
        let outputCounts = contentCounts(output)
        // Sum the overlap of the two multisets: for each character, how many of the
        // source's occurrences the output still has.
        var kept = 0
        for (ch, need) in sourceCounts {
            kept += min(need, outputCounts[ch] ?? 0)
        }
        return Double(kept) / Double(sourceTotal)
    }

    /// Non-whitespace, non-Markdown-marker, case-folded character counts.
    private static func contentCounts(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for ch in text.lowercased() {
            guard !ch.isWhitespace, !markdownMarkers.contains(ch) else { continue }
            counts[ch, default: 0] += 1
        }
        return counts
    }

    /// Structural Markdown characters, ignored on both sides of the comparison.
    private static let markdownMarkers: Set<Character> = ["#", "-", "*", ">", "`", "_", "|", "+"]

    /// Accept or reject an LLM result for `action` over `source`.
    ///
    /// Returns the text to use on success, or the reason to keep the original.
    /// **Failure never clobbers the note** — the caller shows `reason` and leaves the
    /// source untouched.
    public static func validate(
        output: String,
        source: String,
        action: Action
    ) -> Result<String, Rejection> {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        // A model that answered *about* the task instead of doing it. Only checked
        // for short outputs: a long result that happens to open with "I can't"
        // quoted from the note is not a refusal.
        if looksLikeRefusal(trimmed) { return .failure(.notAnAnswer) }

        // Language guard (PR #157): a tiny local model translating the note is the
        // known failure mode. Applies to both actions — a summary in the wrong
        // language is as useless as a translated reformat.
        if RefineOutputGuard.outputTranslatedAway(input: source, output: trimmed) {
            return .failure(.translated)
        }

        // Content preservation — only for the destructive, in-place action. A
        // summary is *supposed* to lose content.
        if action.isDestructive {
            let share = preservationRatio(source: source, output: trimmed)
            guard share >= minPreservationRatio else {
                return .failure(.lostContent(preservedShare: share))
            }
        }

        return .success(trimmed)
    }

    /// Heuristic for "the model talked about the task instead of doing it".
    ///
    /// Kept narrow on purpose: only SHORT outputs are eligible, and only when they
    /// open with a first-person refusal/preamble. A false positive costs the user
    /// nothing but a retry, but a false negative on a long note is invisible.
    static func looksLikeRefusal(_ text: String) -> Bool {
        // Long outputs are the work itself, whatever they open with.
        guard text.count <= 200 else { return false }
        let head = text.lowercased().prefix(60)
        let openers = [
            "i'm sorry", "i am sorry", "sorry,", "i can't", "i cannot", "i can not",
            "i'm unable", "i am unable", "as an ai", "i don't have", "i do not have",
            "there is no text", "there's no text", "no text was provided",
            "please provide", "it seems", "it looks like you",
        ]
        return openers.contains { head.hasPrefix($0) }
    }
}

// MARK: - Model override

/// The Scratchpad's own AI provider/model override (MAK-99), mirroring the MAK-53
/// meeting summarization override exactly.
///
/// The Scratchpad's AI actions are like meeting summaries and unlike dictation
/// cleanup: they run only when the user asks, over a whole note, so they can afford
/// a *larger* model than the tiny one cleanup wants. So they get their own override,
/// defaulting to the `sameAsCleanup` sentinel — existing installs behave as before.
///
/// The *decision* is `SummaryModelResolver.resolve`, reused verbatim rather than
/// re-implemented: its `Override`/`Resolved` types are already feature-agnostic, and
/// sharing them means the Scratchpad's privacy classification (`Resolved.isLocal`,
/// which reads `ScreenContextGate.localRefineProviders`) can never drift from the
/// cleanup and summarize gates. This type adds only the Scratchpad's *storage keys*
/// and its provider-menu vocabulary.
///
/// Storage lives on its own UserDefaults keys, read/written by the Scratchpad model —
/// deliberately NOT as new `@Published` properties on AppState, which is under the
/// MAK-32 LOC ratchet (see `TranslationPreviewController` for the same pattern).
public enum ScratchpadAIModel {

    /// UserDefaults keys. Owned here so the pad's settings surface and any test can
    /// name them from one place.
    public static let providerKey = "scratchpadAIProvider"
    public static let modelKey = "scratchpadAIModel"
    public static let endpointKey = "scratchpadAIEndpoint"

    /// "Use default (current cleanup model)" — the same sentinel the meeting
    /// override uses, so the two settings read identically.
    public static var useDefaultID: String { SummaryModelResolver.sameAsCleanupID }

    /// The provider ids the Scratchpad offers, in menu order.
    ///
    /// The same four the meeting override offers — and, like it, **`agentCLI` is not
    /// among them**: the runtime path is `AppState.summarizeResolved`, which is
    /// OpenAI-shape only and fails closed on an agent-CLI resolution rather than
    /// silently POSTing the note to a cloud endpoint the user never chose.
    public static let offeredProviders: [String] = [useDefaultID, "bundled", "local", "openai"]

    /// Menu label for a provider id — matching the Meetings pane's wording.
    public static func label(for providerID: String) -> String {
        switch providerID {
        case useDefaultID: return "Use default (current cleanup model)"
        case "bundled":    return "On this Mac (built-in)"
        case "local":      return "Your server (self-hosted)"
        case "openai":     return "OpenAI (cloud)"
        case "agentCLI":   return "Agent CLI (Claude / Codex)"
        default:           return providerID
        }
    }

    /// Resolve the effective provider/model/endpoint: the override when the user set
    /// one, else the cleanup/refine settings. A thin, named pass-through to
    /// `SummaryModelResolver.resolve` so the Scratchpad's call sites read in its own
    /// vocabulary and the shared rules stay in one place.
    public static func resolve(
        override: SummaryModelResolver.Override,
        cleanupProvider: String,
        cleanupModel: String,
        cleanupEndpoint: String
    ) -> SummaryModelResolver.Resolved {
        SummaryModelResolver.resolve(
            override: override,
            globalProvider: cleanupProvider,
            globalModel: cleanupModel,
            globalEndpoint: cleanupEndpoint)
    }

    /// Whether a resolved provider can actually serve the Scratchpad's actions.
    /// `agentCLI` cannot — see `offeredProviders`. Used to fail closed *before* a
    /// request is made, with an actionable message.
    public static func isUsable(_ resolved: SummaryModelResolver.Resolved) -> Bool {
        resolved.provider != "agentCLI" && !resolved.provider.isEmpty
    }

    /// The message shown when the resolved provider can't run the action.
    public static let unusableProviderMessage =
        "the agent CLI can't run Scratchpad actions — pick a model in Scratchpad settings"
}
