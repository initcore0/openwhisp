import Foundation

/// Pure, testable planning + prompt assembly for meeting summarization (MAK-50).
///
/// Summarizing a long transcript with a *tiny local model* is a map-reduce: the
/// transcript is split on sentence boundaries into segments small enough for the
/// model's context, each segment is mapped to a partial extraction ("decisions,
/// action items, key points"), and the partials are reduced by a combine prompt into
/// the final structured Markdown (## Summary / ## Decisions / ## Action items).
///
/// This type owns only the *decisions*: how to split, and what text goes into each
/// prompt. It performs no LLM calls — the app feeds each prompt through the existing
/// refine service seam (`AsyncTextRefiner` / `OpenAITranslationService`). Being
/// Foundation-only it compiles into `OpenWhispCore` and the splitter + prompt
/// assembly are unit-tested via `swift test`.
///
/// **Language rule:** every prompt demands output in the transcript's own language
/// (the same lesson `RefineOutputGuard` enforces). After the LLM produces the final
/// summary the app must run `RefineOutputGuard.outputTranslatedAway(input:
/// transcript, output: summary)` and, on rejection, show the transcript with a note
/// rather than a translated summary.
public enum MeetingSummarizer {

    // MARK: - Segment plan

    /// One transcript segment to map, with its 0-based index for stable ordering.
    public struct Segment: Equatable {
        public let index: Int
        public let text: String
        public init(index: Int, text: String) {
            self.index = index
            self.text = text
        }
    }

    /// Target segment size in characters, sized for a tiny (≤1.5B) local model's
    /// context once the per-segment prompt scaffolding is added. Deliberately
    /// conservative so a segment plus its instruction comfortably fits.
    public static let defaultSegmentChars = 2_400

    /// A short transcript that fits in a single segment skips the map/reduce entirely
    /// (one segment, one direct summarize prompt). Anything longer than this many
    /// characters is planned as multiple segments and combined.
    public static var singleSegmentThreshold: Int { defaultSegmentChars }

    /// Split `transcript` into segments no larger than ~`segmentChars`, breaking only
    /// on sentence boundaries so no sentence is cut mid-way. When a single sentence
    /// exceeds the target it becomes its own (oversized) segment rather than being
    /// chopped — the model still sees a whole thought. Whitespace-only input yields
    /// no segments.
    public static func plan(transcript: String, segmentChars: Int = defaultSegmentChars) -> [Segment] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = max(1, segmentChars)

        let sentences = splitIntoSentences(trimmed)
        var segments: [String] = []
        var current = ""

        for sentence in sentences {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= limit {
                current += " " + sentence
            } else {
                segments.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { segments.append(current) }

        return segments.enumerated().map { Segment(index: $0.offset, text: $0.element) }
    }

    /// True when the transcript is short enough to summarize in one direct pass (no
    /// map/reduce). Mirrors `plan` producing 0 or 1 segments.
    public static func isSingleSegment(transcript: String, segmentChars: Int = defaultSegmentChars) -> Bool {
        plan(transcript: transcript, segmentChars: segmentChars).count <= 1
    }

    // MARK: - Prompts

    /// System instruction for the direct single-pass summary of a short transcript.
    /// Demands the transcript's own language and the fixed Markdown section layout.
    public static func directSummaryPrompt() -> String {
        """
        You are a meeting-notes tool. Summarize the meeting transcript the user provides.
        Write your answer in EXACTLY this Markdown structure, using these three headings verbatim:
        ## Summary
        A short paragraph of what the meeting was about.
        ## Decisions
        A bullet list of decisions made. Write "None." if there were none.
        ## Action items
        A bullet list of action items, each with the owner if stated. Write "None." if there were none.
        Reply in the SAME language as the transcript — never translate it. If the transcript is in Russian, answer in Russian; if in German, answer in German.
        Output ONLY the Markdown: no preamble, no code fences, no explanation.
        """
    }

    /// System instruction for the MAP step: extract raw material from one segment.
    /// Kept terse and structured so partials combine cleanly in the reduce step.
    public static func mapPrompt() -> String {
        """
        You are extracting notes from ONE part of a longer meeting transcript.
        From the text the user provides, extract:
        - Decisions made
        - Action items (with owner if stated)
        - Key points discussed
        List them as short bullets under those three labels. If a category has nothing, write "None." under it.
        Do not summarize the whole meeting — only what is in THIS part.
        Reply in the SAME language as the transcript — never translate it.
        Output ONLY the bullets: no preamble, no code fences, no explanation.
        """
    }

    /// System instruction for the REDUCE step: combine the per-segment partials into
    /// the final structured summary. Same Markdown layout as the direct prompt.
    public static func combinePrompt() -> String {
        """
        You are assembling final meeting notes from several partial extractions of the same meeting (in order).
        Merge them, remove duplicates, and resolve any partial that says "None." against the others.
        Write the final notes in EXACTLY this Markdown structure, using these three headings verbatim:
        ## Summary
        A short paragraph of what the meeting was about.
        ## Decisions
        A bullet list of the decisions made across the whole meeting. Write "None." if there were none.
        ## Action items
        A bullet list of action items across the whole meeting, each with the owner if stated. Write "None." if there were none.
        Reply in the SAME language as the partials — never translate them.
        Output ONLY the Markdown: no preamble, no code fences, no explanation.
        """
    }

    /// The user-message text for the combine step: the numbered partials joined so
    /// the model sees them in transcript order.
    public static func combineInput(partials: [String]) -> String {
        partials
            .enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }

    // MARK: - Map/reduce runner (pure orchestration over an injected LLM call)

    /// One LLM round-trip: (systemInstruction, userText) → output; throws on failure.
    public typealias Call = (_ instruction: String, _ input: String) async throws -> String

    /// Run the full map/reduce over `transcript` using the injected `call`. A short
    /// transcript takes the direct single-pass prompt; a long one is mapped per
    /// segment then combined. Pure orchestration (no state, no IO) so it's driven
    /// directly by tests with a scripted call — and reused by the app coordinator.
    public static func run(transcript: String, segmentChars: Int = defaultSegmentChars, call: Call) async throws -> String {
        let segments = plan(transcript: transcript, segmentChars: segmentChars)
        if segments.count <= 1 {
            let input = segments.first?.text ?? transcript
            return try await call(directSummaryPrompt(), input)
        }
        var partials: [String] = []
        for segment in segments {
            partials.append(try await call(mapPrompt(), segment.text))
        }
        return try await call(combinePrompt(), combineInput(partials: partials))
    }

    // MARK: - Sentence splitting

    /// Split text into sentences using Foundation's linguistic sentence tokenizer,
    /// falling back to the whole (trimmed) string as one sentence when enumeration
    /// yields nothing. Newlines are treated as boundaries too, so a transcript that
    /// arrives as unpunctuated newline-separated lines still segments.
    private static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        // First break on hard newlines — chunked transcripts often join lines without
        // terminal punctuation, which the sentence enumerator would otherwise merge.
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            var any = false
            trimmedLine.enumerateSubstrings(in: trimmedLine.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
                if let sub = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
                    sentences.append(sub)
                    any = true
                }
            }
            if !any { sentences.append(trimmedLine) }
        }
        return sentences.isEmpty ? [text] : sentences
    }
}
