import Foundation

/// The pure rules behind the Meme Generator plugin's LLM step (spike).
///
/// One round-trip turns a spoken description ("make me the distracted boyfriend one
/// where the guy is looking at Rust and his girlfriend is Python") into a **ranked
/// list of template candidates** plus the **top/bottom captions**.
///
/// Foundation-only, so both halves — what we ask for and what we're willing to
/// accept back — are pinned by `swift test`. The app layer owns only the LLM
/// round-trip, the image fetch, and the drawing.
///
/// The parser is deliberately forgiving about *packaging* and strict about
/// *content*: small local models wrap JSON in prose or code fences constantly, so we
/// dig the object out (`ScratchpadAI`'s posture), but a response missing the fields
/// is REJECTED rather than silently rendered as an empty meme.
///
/// ## Why ranked candidates (v2)
///
/// v1 asked for a single free-text `template_query` and matched it lexically against
/// the catalog. That silently produced nonsense: "yoda meme" isn't in imgflip's top
/// 100, scored below the matcher's threshold, and the user got Drake with no
/// indication that the corpus simply doesn't contain Yoda.
///
/// v2 gives the model the ACTUAL catalog names and asks for a RANKED list of up to
/// five, verbatim. The parser then drops any name that isn't in that list — a model
/// that invents "Yoda" gets the candidate discarded rather than fuzzy-matched onto
/// something unrelated. When every candidate is dropped, that is reported as a
/// SUCCESS with an empty `templateNames`, and the UI states the corpus plainly
/// instead of quietly substituting a popular template.
///
/// The v1 single-query prompt and parser were deleted rather than kept as a
/// fallback: two parsers where only one runs is exactly the dead-wiring trap this
/// spike is supposed to expose, not commit.
public enum MemeAI {

    // MARK: - Response

    /// Why a response was refused.
    public enum Rejection: Error, Equatable, Sendable {
        /// Nothing usable came back (empty / whitespace only).
        case empty
        /// No JSON object could be found in the response.
        case notJSON
        /// JSON parsed, but there was no usable template AND no caption at all —
        /// rendering this would produce a blank image on a random template. Note a
        /// missing template with captions present is NOT this: that is the honest
        /// "nothing in the corpus fits" answer and it succeeds.
        case missingFields

        public var reason: String {
            switch self {
            case .empty:        return "the model returned nothing"
            case .notJSON:      return "the model didn't return the expected JSON"
            case .missingFields: return "the model left the meme fields empty"
            }
        }
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

    // MARK: - v2: ranked candidates against the real catalog

    /// The maximum number of candidates we ask for (and accept).
    ///
    /// Five is the most that fits a thumbnail strip without scrolling and the most a
    /// user will actually consider before reaching for "Browse all".
    public static let maxCandidates = 5

    /// The instruction for the ranked-candidate round-trip.
    ///
    /// The catalog names are appended by `rankedUserPayload` rather than baked in
    /// here, so this constant stays testable and the prompt stays one place.
    ///
    /// "Think about which templates fit before answering" is deliberate: the owner
    /// asked for the model to consider alternatives rather than snap to one. It
    /// costs a few tokens of reasoning in the response we then discard — the parser
    /// digs the JSON out of prose regardless.
    public static let rankedPrompt = """
    You pick meme templates for a spoken description.

    You are given a numbered list of the ONLY templates available. Each line is a \
    template name, optionally followed by alternate names in parentheses — the \
    parentheses describe what the meme is about, so use them to match a description \
    of the meme's CONTENT, but never copy them into your answer.

    Think about which ones could carry the joke, then rank your best options.

    Reply with ONLY a JSON object, no preamble and no code fence:
    {"templates": ["...", "...", "..."], "top_text": "...", "bottom_text": "..."}

    Rules:
    1. "templates" lists 1 to 5 template names COPIED EXACTLY from the list, best \
    first — the part BEFORE any parentheses, without the number. Do not invent a \
    name, do not reword one, do not use a name that is not on the list.
    2. If nothing on the list fits the description well, still return the closest \
    options — but put the genuinely closest first.
    3. "top_text" and "bottom_text" are the caption lines, in the SAME LANGUAGE as \
    the description. Do not translate them.
    4. Keep each caption short — a few words, meme-style. No quotation marks around \
    them.
    5. If the description only calls for one line, put it in "top_text" and leave \
    "bottom_text" as an empty string.
    6. Never invent a caption that contradicts the description.
    """

    /// How many templates the LLM is asked to rank (v4).
    ///
    /// The shortlist is built LOCALLY by `MemeTemplateCatalog.prefilter` scoring the
    /// user's own description against the whole merged corpus, so this cap is no
    /// longer "the first N by popularity" — it is "the N most relevant". That makes it
    /// safe to be much smaller than v3's 100, which matters: a tiny local model
    /// attends to a 30-line list far better than a 100-line one, and the relevant
    /// template is now guaranteed to be IN the list rather than truncated off the end
    /// at position 180 of a merged ~300-template catalog.
    public static let candidateShortlist = 30

    /// Build the user payload: the description plus the catalog the model must
    /// choose from.
    ///
    /// The list is numbered because small models copy list items more reliably when
    /// the items are visually delimited, and truncated to `limit` because a long list
    /// blows a small local model's context.
    ///
    /// Each line may carry the template's KEYWORDS after its name (v4, see
    /// `MemeTemplateCatalog.promptLines`) — that is what lets the model connect a
    /// description of meme CONTENT to a template whose name shares no words with it.
    /// The name stays first and unadorned so the model can copy it verbatim, which is
    /// what `validate` checks.
    public static func rankedUserPayload(
        description: String, templateNames: [String], limit: Int = candidateShortlist
    ) -> String {
        let names = templateNames.prefix(max(0, limit))
        let list = names.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
        Available templates:
        \(list)

        Meme description:
        \(description.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// A ranked pick: template names that exist in the catalog, plus the captions.
    public struct RankedSpec: Equatable, Sendable {
        /// Template names, best first, each guaranteed to appear in the catalog that
        /// was passed to `parseRanked`. May be EMPTY when the model named only
        /// templates that don't exist — the honest "not in this corpus" signal.
        public let templateNames: [String]
        public let topText: String
        public let bottomText: String

        public init(templateNames: [String], topText: String, bottomText: String) {
            self.templateNames = templateNames
            self.topText = topText
            self.bottomText = bottomText
        }

        /// True when the model produced captions but no usable template — the caller
        /// must show the corpus rather than silently substituting a popular template.
        public var hasNoUsableTemplate: Bool { templateNames.isEmpty }
    }

    /// The wire shape. Decoded leniently: `templates` may arrive as an array or, from
    /// a model that ignored the schema, as a single string.
    private struct RankedWire: Decodable {
        let templates: [String]
        let topText: String
        let bottomText: String

        private enum CodingKeys: String, CodingKey {
            case templates
            case topText = "top_text"
            case bottomText = "bottom_text"
            // Aliases small models reach for when they drift off the schema.
            case template
            case templateQuery = "template_query"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            var names: [String] = []
            if let list = try? c.decode([String].self, forKey: .templates) {
                names = list
            } else if let single = try? c.decode(String.self, forKey: .templates) {
                names = [single]
            } else if let single = try? c.decode(String.self, forKey: .template) {
                names = [single]
            } else if let single = try? c.decode(String.self, forKey: .templateQuery) {
                names = [single]
            }
            templates = names

            topText = (try? c.decode(String.self, forKey: .topText)) ?? ""
            bottomText = (try? c.decode(String.self, forKey: .bottomText)) ?? ""
        }
    }

    /// Parse a ranked-candidate completion, keeping ONLY names that exist in
    /// `catalogNames`.
    ///
    /// Validation is the point of this function. A model that answers "Yoda" for a
    /// catalog without Yoda must have that candidate DROPPED, not fuzzy-matched —
    /// fuzzy matching an invented name is exactly how v1 produced a confident Drake.
    /// Matching against the catalog is case/punctuation-insensitive (models
    /// re-capitalize constantly) but otherwise exact, and the returned names are the
    /// catalog's own spelling so callers can look them up directly.
    ///
    /// Duplicates are collapsed, order is preserved, and the result is capped at
    /// `maxCandidates`.
    ///
    /// Rejects only when the response isn't JSON at all or carries neither a caption
    /// nor a candidate. An empty `templateNames` with captions present is a SUCCESS —
    /// it is the "nothing in the corpus fits" answer the UI needs to state plainly.
    public static func parseRanked(
        _ raw: String, catalogNames: [String]
    ) -> Result<RankedSpec, Rejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        guard let object = firstJSONObject(in: trimmed),
              let data = object.data(using: .utf8),
              let wire = try? JSONDecoder().decode(RankedWire.self, from: data)
        else { return .failure(.notJSON) }

        let names = validate(wire.templates, against: catalogNames)
        let top = clean(wire.topText)
        let bottom = clean(wire.bottomText)

        if names.isEmpty, top.isEmpty, bottom.isEmpty {
            return .failure(.missingFields)
        }
        return .success(RankedSpec(templateNames: names, topText: top, bottomText: bottom))
    }

    /// Keep the proposed names that exist in the catalog, in the model's order,
    /// de-duplicated, capped, and returned in the CATALOG's spelling.
    ///
    /// Exposed for tests: this is the whole anti-hallucination rule.
    public static func validate(
        _ proposed: [String], against catalogNames: [String]
    ) -> [String] {
        // Key on the normalized form so "DRAKE HOTLINE BLING" and "Drake Hotline
        // Bling" resolve to the same catalog entry. First occurrence wins, which
        // matches the catalog's popularity order on a duplicate name.
        var byNormalized: [String: String] = [:]
        for name in catalogNames {
            let key = MemeTemplateMatcher.normalize(name)
            guard !key.isEmpty, byNormalized[key] == nil else { continue }
            byNormalized[key] = name
        }

        var kept: [String] = []
        var seen = Set<String>()
        for candidate in proposed {
            let key = MemeTemplateMatcher.normalize(clean(candidate))
            guard let canonical = byNormalized[key], !seen.contains(key) else { continue }
            seen.insert(key)
            kept.append(canonical)
            if kept.count == maxCandidates { break }
        }
        return kept
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
