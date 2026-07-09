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
struct Vocabulary: Codable, Equatable {
    var terms: [String]
    var substitutions: [Substitution]

    struct Substitution: Codable, Equatable, Identifiable {
        var id: UUID
        var from: String
        var to: String
        /// Star-for-priority: user-flagged as important. Surfaces to the top of the
        /// editor and can be used to bias ordering. Defaults to `false` so existing
        /// stored files (written before this field existed) still decode.
        var starred: Bool
        /// How many times this substitution has fired against transcribed text.
        /// Drives sort-by-usage-frequency in the editor. Defaults to `0` for the
        /// same backward-compatibility reason.
        var usageCount: Int

        init(id: UUID = UUID(), from: String, to: String,
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
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.from = try c.decode(String.self, forKey: .from)
            self.to = try c.decode(String.self, forKey: .to)
            self.starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
            self.usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
        }
    }

    static let empty = Vocabulary(terms: [], substitutions: [])

    /// Substitutions ordered for the editor: starred first, then by descending
    /// usage frequency, with a stable `from` tiebreak so equal-weight rows keep a
    /// deterministic order. Pure — does not mutate the stored order.
    func substitutionsByFrequency() -> [Substitution] {
        substitutions.sorted { a, b in
            if a.starred != b.starred { return a.starred }        // starred float to top
            if a.usageCount != b.usageCount { return a.usageCount > b.usageCount }
            return a.from.localizedCaseInsensitiveCompare(b.from) == .orderedAscending
        }
    }

    /// Increment the usage count of the substitution with the given id, returning
    /// a new Vocabulary (value-semantic; safe to call from anywhere). No-op if no
    /// substitution matches.
    func incrementingUsage(of id: Substitution.ID) -> Vocabulary {
        var copy = self
        if let idx = copy.substitutions.firstIndex(where: { $0.id == id }) {
            copy.substitutions[idx].usageCount += 1
        }
        return copy
    }

    /// The initial-prompt string passed to whisper to bias recognition.
    /// whisper.cpp treats the prompt as prior context, so a comma-separated list
    /// of terms is a reasonable, low-risk biasing signal.
    var whisperPrompt: String {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        return cleaned.joined(separator: ", ")
    }
}

/// Loads/saves the vocabulary as JSON in Application Support.
enum VocabularyStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
    }

    static func load() -> Vocabulary {
        JSONStore.load(from: fileURL, default: .empty, label: "VocabularyStore")
    }

    static func save(_ vocabulary: Vocabulary) {
        JSONStore.save(vocabulary, to: fileURL, label: "VocabularyStore")
    }
}

/// Applies the vocabulary's substitutions to transcribed text.
/// Conforms to PostProcessor so it composes in the post-processing chain.
struct VocabularySubstitutor: PostProcessor {
    let substitutions: [Vocabulary.Substitution]

    func process(_ text: String, context: PostProcessContext) async throws -> String {
        apply(to: text)
    }

    /// Synchronous entry point for direct use in postProcess.
    func apply(to text: String) -> String {
        var result = text
        for sub in substitutions {
            let from = sub.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { continue }
            let to = sub.to
            // Whole-phrase, case-insensitive replacement with word boundaries so
            // we don't rewrite substrings inside larger words. Lookarounds instead
            // of \b: at a non-word edge (e.g. "C++", ".net") \b inverts and
            // demands a word character outside the phrase, so the rule would
            // silently never match. (?<!\w)/(?!\w) equal \b at word-char edges
            // and degrade to "not glued to a word char" at punctuation edges.
            let pattern = "(?<!\\w)\(NSRegularExpression.escapedPattern(for: from))(?!\\w)"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: to),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }
}
