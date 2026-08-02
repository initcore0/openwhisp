import Foundation

/// The pure rules behind the Meme Generator plugin's LLM step (spike).
///
/// One round-trip turns a spoken description ("make me the distracted boyfriend one
/// where the guy is looking at Rust and his girlfriend is Python") into three fields:
/// a **template query** used to pick a base image, and the **top/bottom captions**.
///
/// Foundation-only, so both halves — what we ask for and what we're willing to
/// accept back — are pinned by `swift test`. The app layer owns only the LLM
/// round-trip, the image fetch, and the drawing.
///
/// The parser is deliberately forgiving about *packaging* and strict about
/// *content*: small local models wrap JSON in prose or code fences constantly, so we
/// dig the object out (`ScratchpadAI`'s posture), but a response missing the fields
/// is REJECTED rather than silently rendered as an empty meme.
public enum MemeAI {

    // MARK: - Request

    /// The instruction sent with the user's spoken description.
    ///
    /// Language note, same as the Scratchpad's AI prompts (PR #157): the captions
    /// must stay in the user's language. Tiny local models translate their input
    /// unprompted, and a meme dictated in Ukrainian coming back in English is a bug.
    /// The `template_query` is the exception — it is matched against an
    /// English-titled catalog, so it is pinned to English on purpose.
    public static let prompt = """
    You turn a spoken description of a meme into the fields needed to build it.

    Reply with ONLY a JSON object, no preamble and no code fence, with exactly these keys:
    {"template_query": "...", "top_text": "...", "bottom_text": "..."}

    Rules:
    1. "template_query" names the meme template in ENGLISH — the well-known name if \
    the description implies one (e.g. "drake hotline bling", "distracted boyfriend", \
    "two buttons"), otherwise two or three words describing the image that would fit.
    2. "top_text" and "bottom_text" are the caption lines, in the SAME LANGUAGE as \
    the description. Do not translate them.
    3. Keep each caption short — a few words, meme-style. Do not add quotation marks \
    around them.
    4. If the description only calls for one line, put it in "top_text" and leave \
    "bottom_text" as an empty string.
    5. Never invent a caption that contradicts the description.
    """

    /// Build the user payload for a description. Trimmed; the caller guarantees
    /// non-empty (the Generate button is disabled otherwise).
    public static func userPayload(description: String) -> String {
        "Meme description:\n" + description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response

    /// The three fields a successful round-trip yields.
    public struct MemeSpec: Equatable, Sendable, Codable {
        /// English-ish search phrase used to pick a template from the catalog.
        public let templateQuery: String
        /// Upper caption, in the user's language. May be empty.
        public let topText: String
        /// Lower caption, in the user's language. May be empty.
        public let bottomText: String

        public init(templateQuery: String, topText: String, bottomText: String) {
            self.templateQuery = templateQuery
            self.topText = topText
            self.bottomText = bottomText
        }

        private enum CodingKeys: String, CodingKey {
            case templateQuery = "template_query"
            case topText = "top_text"
            case bottomText = "bottom_text"
        }
    }

    /// Why a response was refused.
    public enum Rejection: Error, Equatable, Sendable {
        /// Nothing usable came back (empty / whitespace only).
        case empty
        /// No JSON object could be found in the response.
        case notJSON
        /// JSON parsed, but there was no template query and no caption at all —
        /// rendering this would produce a blank image on a random template.
        case missingFields

        public var reason: String {
            switch self {
            case .empty:        return "the model returned nothing"
            case .notJSON:      return "the model didn't return the expected JSON"
            case .missingFields: return "the model left the meme fields empty"
            }
        }
    }

    /// Parse a raw completion into a `MemeSpec`.
    ///
    /// Accepts a bare object, a fenced ```json block, and an object embedded in
    /// surrounding prose — all three are things small local models actually emit.
    public static func parse(_ raw: String) -> Result<MemeSpec, Rejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        guard let object = firstJSONObject(in: trimmed) else { return .failure(.notJSON) }
        guard let data = object.data(using: .utf8),
              let spec = try? JSONDecoder().decode(MemeSpec.self, from: data)
        else { return .failure(.notJSON) }

        let cleaned = MemeSpec(
            templateQuery: clean(spec.templateQuery),
            topText: clean(spec.topText),
            bottomText: clean(spec.bottomText))

        // A spec with no query AND no captions is not a meme. One empty caption is
        // fine (rule 4 in the prompt asks for exactly that on single-line memes).
        if cleaned.templateQuery.isEmpty, cleaned.topText.isEmpty, cleaned.bottomText.isEmpty {
            return .failure(.missingFields)
        }
        return .success(cleaned)
    }

    /// Strip the wrapping models add around caption values: surrounding quotes and
    /// stray whitespace. Keeps interior punctuation untouched.
    private static func clean(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.count >= 2,
              let first = s.first, let last = s.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Extract the first balanced `{...}` run from a string, ignoring braces that
    /// appear inside JSON string literals (so a caption containing `{` can't end the
    /// scan early). Returns nil when there is no balanced object.
    private static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let char = text[index]

            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                continue
            }

            switch char {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            default:
                break
            }
        }
        return nil
    }
}
