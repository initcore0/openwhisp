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
        /// When this entry was last edited by the user (ConfigBundle schema v3,
        /// MAK-51 WP0b). The sync merge does per-entry last-writer-wins by this
        /// stamp: on a conflict the newer `updatedAt` wins. A v2 file written
        /// before this field existed decodes to `Date(timeIntervalSince1970: 0)`
        /// (the distant past) so any stamped edit from a v3 peer always wins over
        /// unstamped legacy data — see ``ConfigBundle`` for the schema note.
        public var updatedAt: Date

        /// The sentinel a pre-v3 (unstamped) entry decodes to: the distant past,
        /// so it loses every last-writer-wins race until deliberately restamped
        /// (see ``Vocabulary/restampingUnstamped(now:)``).
        public static let unstampedEpoch = Date(timeIntervalSince1970: 0)

        public init(id: UUID = UUID(), from: String, to: String,
             starred: Bool = false, usageCount: Int = 0,
             updatedAt: Date = Date()) {
            self.id = id
            self.from = from
            self.to = to
            self.starred = starred
            self.usageCount = usageCount
            self.updatedAt = updatedAt
        }

        // Custom decoding so an OLD substitution JSON that predates `starred` /
        // `usageCount` / `updatedAt` still decodes: the new keys are optional and
        // fall back to their defaults. `id` is likewise defensively defaulted (a
        // hand-edited file could omit it) rather than failing the whole load.
        // `updatedAt` falls back to the EPOCH (not "now") so unstamped v2 data
        // always loses the last-writer-wins race to any stamped v3 edit.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.from = try c.decode(String.self, forKey: .from)
            self.to = try c.decode(String.self, forKey: .to)
            self.starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
            self.usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
            self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
                ?? Substitution.unstampedEpoch
        }

        /// Return a copy stamped as edited `now`. Pure — the mutation-path
        /// helpers on ``Vocabulary`` call this so every user edit advances the
        /// stamp (a stamp that never moves makes last-writer-wins silently wrong).
        public func stamped(_ now: Date = Date()) -> Substitution {
            var copy = self
            copy.updatedAt = now
            return copy
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

    // MARK: - Stamped edits (MAK-51 WP0b)
    //
    // Every USER edit of a substitution must advance its `updatedAt`, or the sync
    // merge's per-entry last-writer-wins silently keeps stale data. These pure,
    // value-semantic helpers are the single funnel the editors route through so no
    // callsite can mutate a field without also stamping it. `incrementingUsage`
    // above is deliberately NOT stamped: a usage bump is a machine-driven counter,
    // not a user edit, and stamping it would let a passive dictation win the merge
    // over a real remote edit.

    /// Append a new substitution, stamped `now`. Returns a new Vocabulary.
    public func addingSubstitution(_ sub: Substitution, now: Date = Date()) -> Vocabulary {
        var copy = self
        copy.substitutions.append(sub.stamped(now))
        return copy
    }

    /// Append `sub` unless a rule with the same case-insensitive `from→to` already
    /// exists. Stamped `now`. The single funnel for machine-added rules (accepted
    /// proposals, MAK-86 auto-adds) so a duplicate can never slip in. Returns a new
    /// Vocabulary (unchanged when the rule is already present).
    public func addingSubstitutionIfAbsent(_ sub: Substitution, now: Date = Date()) -> Vocabulary {
        func key(_ f: String, _ t: String) -> String {
            "\(f.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\u{1F}\(t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
        let k = key(sub.from, sub.to)
        guard !substitutions.contains(where: { key($0.from, $0.to) == k }) else { return self }
        return addingSubstitution(sub, now: now)
    }

    /// Remove the substitution with `id`. Returns a new Vocabulary (no stamp —
    /// the entry is gone; a tombstone model is out of scope for the v1 merge).
    public func removingSubstitution(_ id: Substitution.ID) -> Vocabulary {
        var copy = self
        copy.substitutions.removeAll { $0.id == id }
        return copy
    }

    /// Apply `mutate` to the substitution with `id`, then stamp it `now`. Returns
    /// a new Vocabulary; no-op if no entry matches. The one funnel every field
    /// edit (from/to/starred) goes through so the stamp can never be forgotten.
    public func editingSubstitution(
        _ id: Substitution.ID, now: Date = Date(),
        _ mutate: (inout Substitution) -> Void
    ) -> Vocabulary {
        var copy = self
        guard let idx = copy.substitutions.firstIndex(where: { $0.id == id }) else { return self }
        mutate(&copy.substitutions[idx])
        copy.substitutions[idx].updatedAt = now
        return copy
    }

    /// Stamp `now` onto every substitution that decoded with the epoch sentinel
    /// (i.e. came from a pre-v3 source with no `updatedAt`). Used when a user
    /// deliberately IMPORTS a config or applies a pack: the act of importing is a
    /// user edit, so those entries must win the next sync's last-writer-wins race
    /// rather than losing to any stamped peer copy of the same id. Genuinely
    /// stamped v3 entries keep their real timestamps untouched.
    public func restampingUnstamped(now: Date = Date()) -> Vocabulary {
        var copy = self
        for idx in copy.substitutions.indices where copy.substitutions[idx].updatedAt == Substitution.unstampedEpoch {
            copy.substitutions[idx].updatedAt = now
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
            guard let from = Self.effectiveFrom(sub),
                  let regex = Self.compiledRegex(for: from) else { continue }
            // Whole-phrase, case-insensitive replacement with word boundaries so
            // we don't rewrite substrings inside larger words. Lookarounds instead
            // of \b: at a non-word edge (e.g. "C++", ".net") \b inverts and
            // demands a word character outside the phrase, so the rule would
            // silently never match. (?<!\w)/(?!\w) equal \b at word-char edges
            // and degrade to "not glued to a word char" at punctuation edges.
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: sub.to)
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
        let range = NSRange(text.startIndex..., in: text)
        for sub in substitutions {
            guard let from = Self.effectiveFrom(sub),
                  let regex = Self.compiledRegex(for: from) else { continue }
            if regex.firstMatch(in: text, options: [], range: range) != nil {
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

    /// Process-wide compiled-regex cache. A fresh substitutor is constructed for
    /// every postProcess call — several times per second during streaming — so
    /// caching per instance would never hit; the cache is keyed by the rule's
    /// trimmed `from` phrase at type scope instead. NSRegularExpression is
    /// immutable and documented thread-safe, so sharing instances is fine; the
    /// lock only guards the dictionary. Growth is bounded by the distinct `from`
    /// phrases the user ever configures in one app run.
    private static let regexCacheLock = NSLock()
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    private static func compiledRegex(for from: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if let cached = regexCache[from] { return cached }
        let regex = try? NSRegularExpression(pattern: pattern(for: from), options: [.caseInsensitive])
        if let regex { regexCache[from] = regex }
        return regex
    }

    /// The whole-phrase, punctuation-edge-safe match pattern for a `from` phrase.
    private static func pattern(for from: String) -> String {
        "(?<!\\w)\(NSRegularExpression.escapedPattern(for: from))(?!\\w)"
    }
}
