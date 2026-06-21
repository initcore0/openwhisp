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

        init(id: UUID = UUID(), from: String, to: String) {
            self.id = id
            self.from = from
            self.to = to
        }
    }

    static let empty = Vocabulary(terms: [], substitutions: [])

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
        guard let data = try? Data(contentsOf: fileURL),
              let vocab = try? JSONDecoder().decode(Vocabulary.self, from: data) else {
            return .empty
        }
        return vocab
    }

    static func save(_ vocabulary: Vocabulary) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(vocabulary)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[VocabularyStore] save failed: \(error.localizedDescription)")
        }
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
            // we don't rewrite substrings inside larger words.
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: from))\\b"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: to),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }
}
