import Foundation

/// User's custom vocabulary: terms that bias whisper recognition, plus optional
/// "heard → correct" substitutions applied as a local post-process pass.
///
/// Two distinct mechanisms:
///   - **terms**: names/jargon/acronyms fed to whisper as an initial prompt so
///     the model is biased toward producing them (e.g. "Claude, Anthropic,
///     OpenWhisp, kubectl"). Improves recognition; no guarantee.
///   - **substitutions**: deterministic "from → to" fixups applied after
///     transcription (e.g. "clod code" → "Claude Code"). Whole-word, case-
///     insensitive match; preserves following text.
public struct Vocabulary: Codable, Equatable {
    public var terms: [String]
    public var substitutions: [Substitution]

    public init(terms: [String], substitutions: [Substitution]) {
        self.terms = terms
        self.substitutions = substitutions
    }

    public struct Substitution: Codable, Equatable, Identifiable {
        public var id: UUID
        public var from: String
        public var to: String
        /// Star-for-priority: user-flagged as important. Surfaces to the top of the
        /// editor and can be used to bias ordering. Defaults to `false` so existing
        /// stored files (written before this field existed) still decode.
        public var starred: Bool
        /// How many times this substitution has fired against transcribed text.
        /// Drives sort-by-usage-frequency in the editor. Defaults to `0` for the
        /// same backward-compatibility reason.
        public var usageCount: Int

        public init(id: UUID = UUID(), from: String, to: String,
             starred: Bool = false, usageCount: Int = 0) {
            self.id = id
            self.from = from
            self.to = to
            self.starred = starred
            self.usageCount = usageCount
        }

        // Custom decoding so an OLD substitution JSON that predates `starred` /
        // `usageCount` still decodes: the two new keys are optional and fall back
        // to their defaults. `id` is likewise defensively defaulted (a hand-edited
        // file could omit it) rather than failing the whole load.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.from = try c.decode(String.self, forKey: .from)
            self.to = try c.decode(String.self, forKey: .to)
            self.starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
            self.usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
        }
    }

    public static let empty = Vocabulary(terms: [], substitutions: [])

    /// Substitutions ordered for the editor: starred first, then by descending
    /// usage frequency, with a stable `from` tiebreak so equal-weight rows keep a
    /// deterministic order. Pure — does not mutate the stored order.
    public func substitutionsByFrequency() -> [Substitution] {
        substitutions.sorted { a, b in
            if a.starred != b.starred { return a.starred }        // starred float to top
            if a.usageCount != b.usageCount { return a.usageCount > b.usageCount }
            return a.from.localizedCaseInsensitiveCompare(b.from) == .orderedAscending
        }
    }

    /// Increment the usage count of the substitution with the given id, returning
    /// a new Vocabulary (value-semantic; safe to call from anywhere). No-op if no
    /// substitution matches.
    public func incrementingUsage(of id: Substitution.ID) -> Vocabulary {
        var copy = self
        if let idx = copy.substitutions.firstIndex(where: { $0.id == id }) {
            copy.substitutions[idx].usageCount += 1
        }
        return copy
    }

    /// Increment the usage count of every substitution whose id is in `ids`, once
    /// each, returning a new Vocabulary. Multiple firings of the same rule in one
    /// transcript count as ONE use (the caller passes a *set*), so a term that
    /// rewrote three words in a sentence doesn't leap ahead of a term used across
    /// three separate dictations. Unknown ids are ignored; empty set is a no-op.
    public func incrementingUsage(of ids: Set<Substitution.ID>) -> Vocabulary {
        guard !ids.isEmpty else { return self }
        var copy = self
        for idx in copy.substitutions.indices where ids.contains(copy.substitutions[idx].id) {
            copy.substitutions[idx].usageCount += 1
        }
        return copy
    }

    /// The initial-prompt string passed to whisper to bias recognition.
    /// whisper.cpp treats the prompt as prior context, so a comma-separated list
    /// of terms is a reasonable, low-risk biasing signal.
    public var whisperPrompt: String {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        return cleaned.joined(separator: ", ")
    }
}

/// Loads/saves the vocabulary as JSON in Application Support.
public enum VocabularyStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
    }

    public static func load() -> Vocabulary {
        JSONStore.load(from: fileURL, default: .empty, label: "VocabularyStore")
    }

    public static func save(_ vocabulary: Vocabulary) {
        JSONStore.save(vocabulary, to: fileURL, label: "VocabularyStore")
    }
}

/// Applies the vocabulary's substitutions to transcribed text.
/// Conforms to PostProcessor so it composes in the post-processing chain.
public struct VocabularySubstitutor: PostProcessor {
    public let substitutions: [Vocabulary.Substitution]

    public init(substitutions: [Vocabulary.Substitution]) {
        self.substitutions = substitutions
    }

    public func process(_ text: String, context: PostProcessContext) async throws -> String {
        apply(to: text)
    }

    /// Synchronous entry point for direct use in postProcess.
    public func apply(to text: String) -> String {
        var result = text
        for sub in substitutions {
            guard let from = Self.effectiveFrom(sub) else { continue }
            // Whole-phrase, case-insensitive replacement with word boundaries so
            // we don't rewrite substrings inside larger words. Lookarounds instead
            // of \b: at a non-word edge (e.g. "C++", ".net") \b inverts and
            // demands a word character outside the phrase, so the rule would
            // silently never match. (?<!\w)/(?!\w) equal \b at word-char edges
            // and degrade to "not glued to a word char" at punctuation edges.
            result = result.replacingOccurrences(
                of: Self.pattern(for: from),
                with: NSRegularExpression.escapedTemplate(for: sub.to),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// Which substitutions would actually *match* (fire) against `text`, by id.
    /// Pure and side-effect free — used to bump `usageCount` for exactly the rules
    /// that rewrote the transcript, so the editor's usage sort reflects real use.
    /// Uses the SAME whole-phrase, case-insensitive, lookaround-bounded match as
    /// `apply(to:)`, so "counted as used" and "actually rewrote" can never diverge.
    /// A rule whose `to` equals its `from` (a no-op edit) still counts as matched:
    /// it fired, the user just wrote it as an identity rule.
    public func firedSubstitutionIDs(in text: String) -> Set<Vocabulary.Substitution.ID> {
        var fired: Set<Vocabulary.Substitution.ID> = []
        for sub in substitutions {
            guard let from = Self.effectiveFrom(sub) else { continue }
            let regex = try? NSRegularExpression(pattern: Self.pattern(for: from),
                                                 options: [.caseInsensitive])
            let range = NSRange(text.startIndex..., in: text)
            if regex?.firstMatch(in: text, options: [], range: range) != nil {
                fired.insert(sub.id)
            }
        }
        return fired
    }

    /// The trimmed `from` phrase, or nil when it's blank (a blank rule never fires).
    private static func effectiveFrom(_ sub: Vocabulary.Substitution) -> String? {
        let from = sub.from.trimmingCharacters(in: .whitespacesAndNewlines)
        return from.isEmpty ? nil : from
    }

    /// The whole-phrase, punctuation-edge-safe match pattern for a `from` phrase.
    private static func pattern(for from: String) -> String {
        "(?<!\\w)\(NSRegularExpression.escapedPattern(for: from))(?!\\w)"
    }
}
