import Foundation

/// A minimal JSON value, so a schema can be built in Swift and encoded verbatim.
///
/// Written by hand rather than reaching for `[String: Any]` because `Any` is not
/// `Encodable` — and rather than a raw JSON string, because a string would put the
/// schema beyond the reach of the type checker AND of `swift test`. It lives in
/// OpenWhispCore (not beside the HTTP client) for exactly that reason: the schemas
/// are logic, and logic in this project is testable by construction.
public indirect enum JSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

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
    /// The catalog lines are appended by `rankedUserPayload` rather than baked in
    /// here, so this constant stays testable and the prompt stays one place.
    ///
    /// ## v6 — three changes, each fixing something the previous prompt got wrong
    ///
    /// **1. Candidates are NUMBERS, not copied names.** v5 asked the model to copy
    /// names "EXACTLY", then dropped anything that didn't match the catalog. That is a
    /// transcription task, and it is the single most fragile thing you can ask a tiny
    /// local model to do: it re-capitalizes, it expands "Y U No" to "Why You No", it
    /// drops the parenthesized keywords or folds them in, and every one of those is a
    /// silently discarded candidate. The shortlist was already numbered for exactly
    /// this reason and the numbers went unused. Returning `[3, 17, 1]` makes the answer
    /// a one-token-per-pick lookup that either indexes a real template or is out of
    /// range — no fuzzy middle ground. The parser still accepts names (see
    /// `parseRanked`), so a model that ignores this is no worse off than in v5.
    ///
    /// **2. Captions are an ARRAY sized to the template.** `top_text`/`bottom_text`
    /// hard-coded the assumption that every meme is a two-liner. Drake is two side
    /// labels, Distracted Boyfriend is three, Expanding Brain is four — so the payload
    /// now states the top candidate's slot count and asks for that many captions, in
    /// panel order.
    ///
    /// **3. "Think about which ones could carry the joke" is GONE.** It asked for
    /// reasoning that the parser then threw away — pure token cost with no consumer,
    /// on the models least able to afford it. In its place the model returns ONE short
    /// `reason`, which the candidate strip actually shows as a tooltip. That is the
    /// same request turned into something the user can see: if the model picked Drake
    /// for a bad reason, the user now reads the bad reason instead of guessing why the
    /// thumbnail is there. Reasoning that is displayed earns its tokens; reasoning that
    /// is discarded does not.
    public static let rankedPrompt = """
    You pick meme templates for a spoken description.

    You are given a numbered list of the ONLY templates available. Each line is a \
    number, a template name, and optionally alternate names in parentheses — the \
    parentheses describe what the meme is about, so use them to match a description \
    of the meme's CONTENT.

    Reply with ONLY a JSON object, no preamble and no code fence:
    {"templates": [3, 17, 1], "captions": ["...", "..."], "reason": "..."}

    Rules:
    1. "templates" lists 1 to 5 NUMBERS from the list, best first. Use the number \
    only — do not write the name, do not invent a number that is not on the list.
    2. If nothing on the list fits the description well, still return the closest \
    options — but put the genuinely closest first.
    3. "captions" are the caption lines for your FIRST choice, in order from the top \
    (or left) panel to the last. The description above says how many that template \
    takes — return exactly that many.
    4. Captions must be in the SAME LANGUAGE as the description. Do not translate them.
    5. Keep each caption short — a few words, meme-style. No quotation marks around \
    them.
    6. Never invent a caption that contradicts the description.
    7. "reason" is ONE short sentence saying why your first choice fits. It is shown \
    to the user, so write it for them, not for yourself.
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

    /// The numbering the model answers with — 1-BASED, matching what it sees.
    ///
    /// Stated once, here, because the offset is the whole contract between
    /// `rankedUserPayload` (which prints `index + 1`) and `resolve` (which subtracts
    /// it). An off-by-one between those two would silently return the model's
    /// neighbour on every pick — a bug that produces plausible-looking wrong templates
    /// rather than an error, which is the worst kind to hunt.
    public static let firstCandidateNumber = 1

    /// One prompt line per shortlisted template, carrying its caption-slot count (v6).
    ///
    /// The count has to be IN the list because the model chooses its first candidate
    /// and writes that candidate's captions in the same reply — it cannot be told the
    /// slot count in advance without knowing what it will pick. Printing it per line
    /// lets the model read the number off the row it just chose.
    ///
    /// Only non-default counts are annotated. Tagging all 166 two-slot templates with
    /// "(2 captions)" would be 166 lines of noise for the case that is already the
    /// default, on models whose attention is the scarce resource — so a bare line MEANS
    /// two, which rule 3 of the prompt and the sentence below both state.
    public static func slotAnnotatedLines(_ lines: [String], slots: [Int]) -> [String] {
        lines.enumerated().map { index, line in
            let count = index < slots.count
                ? MemeCaptionSlots.clamp(slots[index])
                : MemeCaptionSlots.default
            guard count != MemeCaptionSlots.default else { return line }
            return "\(line) [\(count) captions]"
        }
    }

    /// The payload for the v6 round-trip: the numbered shortlist with slot counts, the
    /// description, and the sentence that ties the two together.
    public static func rankedUserPayload(
        description: String, templateLines: [String], slots: [Int],
        limit: Int = candidateShortlist
    ) -> String {
        let annotated = slotAnnotatedLines(templateLines, slots: slots)
        let base = rankedUserPayload(
            description: description, templateNames: annotated, limit: limit)

        return base + """


        A template marked [N captions] takes N caption lines; an unmarked one takes \
        \(MemeCaptionSlots.default). Return exactly as many captions as your FIRST \
        choice takes.
        """
    }

    /// A ranked pick: template names that exist in the catalog, plus the captions.
    public struct RankedSpec: Equatable, Sendable {
        /// Template names, best first, each guaranteed to appear in the catalog that
        /// was passed to `parseRanked`. May be EMPTY when the model named only
        /// templates that don't exist — the honest "not in this corpus" signal.
        public let templateNames: [String]

        /// The captions in PANEL ORDER (v6), one per slot the model was asked for.
        ///
        /// Replaces v5's `topText`/`bottomText` pair. The array is the general case:
        /// a two-slot response is `[top, bottom]`, which is exactly what the legacy
        /// keys decode into, so nothing about the classic path changed except its
        /// spelling.
        public let captions: [String]

        /// The model's one-line justification for its first pick, shown in the
        /// candidate strip's tooltip. Empty when the model didn't give one — it is a
        /// nicety, never a reason to reject a response.
        public let reason: String

        /// True when the captions came from the legacy `top_text`/`bottom_text` pair
        /// rather than a `captions` array (v7).
        ///
        /// Recorded because the two shapes mean different things even when they carry
        /// the same two strings: an ARRAY of two is a model answering a 2-slot question,
        /// while the legacy pair is a model that never engaged with the slot count. On a
        /// 2-slot template both are correct; on any other, the legacy pair is the v6 bug
        /// signature. `fit` treats them identically today — the count is what decides —
        /// and this flag is what lets the host say WHICH happened without re-parsing.
        public let wasLegacyShape: Bool

        public init(
            templateNames: [String], captions: [String], reason: String = "",
            wasLegacyShape: Bool = false
        ) {
            self.templateNames = templateNames
            self.captions = captions
            self.reason = reason
            self.wasLegacyShape = wasLegacyShape
        }

        /// The classic two-slot spelling, kept so existing call sites and tests that
        /// think in top/bottom still read naturally.
        ///
        /// **Deprecated in v8**, for the same reason as `MemeCaptionLayout`'s
        /// top/bottom seed: a two-caption constructor is the shape the v6 bug came in,
        /// and every production path now carries N captions from `parseRanked` straight
        /// into `MemeCaptionSeeding.resolve`. Kept for the tests that assert the legacy
        /// wire shape still decodes.
        @available(*, deprecated, message: """
            Two-caption shape. Use init(templateNames:captions:) — pass a 2-element \
            array when the template really has two slots.
            """)
        public init(templateNames: [String], topText: String, bottomText: String) {
            self.init(templateNames: templateNames, captions: [topText, bottomText])
        }

        public var topText: String { captions.first ?? "" }
        public var bottomText: String { captions.count > 1 ? captions[1] : "" }

        /// True when the model produced captions but no usable template — the caller
        /// must show the corpus rather than silently substituting a popular template.
        public var hasNoUsableTemplate: Bool { templateNames.isEmpty }

        /// True when nothing at all was said — the reject condition, stated once.
        public var isEmpty: Bool {
            templateNames.isEmpty && captions.allSatisfy(\.isEmpty)
        }

        /// The same pick, with the captions replaced by the user's own words (v7).
        ///
        /// Used when `MemeCaptionExtraction` read a list out of the description: the
        /// model's TEMPLATE choice is kept (that is the judgement we wanted from it) and
        /// its captions are discarded in favour of what the user actually said. Marks
        /// the result as non-legacy because these captions came from the user, not from
        /// a `top_text` pair — the distinction the status line reads.
        public func replacingCaptions(with captions: [String]) -> RankedSpec {
            RankedSpec(
                templateNames: templateNames, captions: captions, reason: reason,
                wasLegacyShape: false)
        }
    }

    /// One candidate reference as the model wrote it: a number or a name (v6).
    ///
    /// Modelled explicitly rather than collapsing both into a string, because the two
    /// resolve against completely different things — a number indexes the shortlist,
    /// a name is matched against the catalog — and conflating them is how "17" would
    /// end up being fuzzy-matched against a template called "17 Again".
    public enum CandidateRef: Equatable, Sendable {
        case index(Int)
        case name(String)
    }

    /// The wire shape. Decoded leniently on purpose: `templates` may arrive as an
    /// array of numbers (the v6 contract), an array of strings, a mix of both, a bare
    /// number, or a single string; captions may arrive as an array (v6) or as
    /// `top_text`/`bottom_text` (v5 and any model that saw a two-line meme and reached
    /// for the classic keys).
    private struct RankedWire: Decodable {
        let templates: [CandidateRef]
        let captions: [String]
        let reason: String
        /// Whether `captions` was reconstructed from `top_text`/`bottom_text` (v7).
        let wasLegacyShape: Bool

        private enum CodingKeys: String, CodingKey {
            case templates
            case captions
            case reason
            case topText = "top_text"
            case bottomText = "bottom_text"
            // Aliases small models reach for when they drift off the schema.
            case template
            case templateQuery = "template_query"
            case texts
            case lines
        }

        /// Decode one element of `templates`, which may be a number or a string.
        ///
        /// A string that is ENTIRELY a number ("3") is treated as an index: a model
        /// asked for numbers and answering `["3"]` meant the third template, and
        /// looking for a catalog entry named "3" would throw that away.
        private struct AnyRef: Decodable {
            let ref: CandidateRef?

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let number = try? c.decode(Int.self) {
                    ref = .index(number)
                } else if let text = try? c.decode(String.self) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let number = Int(trimmed) {
                        ref = .index(number)
                    } else {
                        ref = trimmed.isEmpty ? nil : .name(trimmed)
                    }
                } else {
                    // A shape we don't understand (an object, a null) is DROPPED rather
                    // than failing the whole decode — one weird element must not cost
                    // the user the four good candidates beside it.
                    ref = nil
                }
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            var refs: [CandidateRef] = []
            if let list = try? c.decode([AnyRef].self, forKey: .templates) {
                refs = list.compactMap(\.ref)
            } else if let single = try? c.decode(AnyRef.self, forKey: .templates), let ref = single.ref {
                refs = [ref]
            } else if let single = try? c.decode(AnyRef.self, forKey: .template), let ref = single.ref {
                refs = [ref]
            } else if let single = try? c.decode(String.self, forKey: .templateQuery) {
                refs = [.name(single)]
            }
            templates = refs

            // v6 array first, then the aliases, then the v5 legacy pair. The legacy
            // branch is LAST so a response carrying both an array and stray top/bottom
            // keys keeps the array — the richer answer wins.
            if let list = try? c.decode([String].self, forKey: .captions) {
                captions = list
                wasLegacyShape = false
            } else if let list = try? c.decode([String].self, forKey: .texts) {
                captions = list
                wasLegacyShape = false
            } else if let list = try? c.decode([String].self, forKey: .lines) {
                captions = list
                wasLegacyShape = false
            } else {
                let top = (try? c.decode(String.self, forKey: .topText)) ?? ""
                let bottom = (try? c.decode(String.self, forKey: .bottomText)) ?? ""
                captions = [top, bottom]
                wasLegacyShape = true
            }

            reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
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

        let names = resolve(wire.templates, shortlist: catalogNames)
        // Trailing empties are dropped so a model padding a 2-slot answer out to four
        // strings doesn't seed two blank boxes — but INTERIOR empties are kept, because
        // in a panel meme "" at slot 2 means "this panel has no caption", and shifting
        // slot 3 up into its place would relabel the wrong panel.
        var captions = wire.captions.map(clean)
        while let last = captions.last, last.isEmpty { captions.removeLast() }

        let spec = RankedSpec(
            templateNames: names, captions: captions, reason: clean(wire.reason),
            wasLegacyShape: wire.wasLegacyShape)
        guard !spec.isEmpty else { return .failure(.missingFields) }
        return .success(spec)
    }

    /// Resolve the model's candidate references against the shortlist it was shown.
    ///
    /// This is the whole anti-hallucination rule, now covering both answer shapes:
    ///
    /// * **A number** indexes the shortlist, 1-based (`firstCandidateNumber`), and is
    ///   REJECTED when out of range. There is no clamping and no nearest-match: a model
    ///   answering `47` for a 30-line list has miscounted or invented, and quietly
    ///   handing back template 30 would be v1's confident-Drake bug wearing a number.
    /// * **A name** is matched case/punctuation-insensitively against the shortlist and
    ///   returned in the SHORTLIST's spelling. Kept from v5 for backward compatibility:
    ///   a model that ignores the numbering is exactly as well served as before.
    ///
    /// Order is the model's, duplicates collapse (including a number and a name that
    /// resolve to the SAME template — the dedupe is on the resolved name, not on how it
    /// was written), and the result is capped at `maxCandidates`.
    ///
    /// `shortlist` must be the same list, in the same order, that
    /// `rankedUserPayload` numbered — that is what makes an index meaningful.
    public static func resolve(
        _ refs: [CandidateRef], shortlist: [String]
    ) -> [String] {
        // Key on the normalized form so "DRAKE HOTLINE BLING" and "Drake Hotline
        // Bling" resolve to the same catalog entry. First occurrence wins, which
        // matches the catalog's popularity order on a duplicate name.
        var byNormalized: [String: String] = [:]
        for name in shortlist {
            let key = MemeTemplateMatcher.normalize(name)
            guard !key.isEmpty, byNormalized[key] == nil else { continue }
            byNormalized[key] = name
        }

        var kept: [String] = []
        var seen = Set<String>()

        for ref in refs {
            let canonical: String?
            switch ref {
            case .index(let number):
                let offset = number - firstCandidateNumber
                canonical = shortlist.indices.contains(offset) ? shortlist[offset] : nil
            case .name(let raw):
                canonical = byNormalized[MemeTemplateMatcher.normalize(clean(raw))]
            }

            guard let canonical else { continue }
            let key = MemeTemplateMatcher.normalize(canonical)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            kept.append(canonical)
            if kept.count == maxCandidates { break }
        }
        return kept
    }

    /// Keep the proposed names that exist in the catalog (the v5 name-only entry
    /// point), expressed in terms of `resolve` so there is exactly one rule.
    public static func validate(
        _ proposed: [String], against catalogNames: [String]
    ) -> [String] {
        resolve(proposed.map { CandidateRef.name($0) }, shortlist: catalogNames)
    }

    // MARK: - v6: refitting captions to another template's structure

    /// The instruction for the caption REFIT round-trip.
    ///
    /// ## Why a second call exists at all
    ///
    /// The candidate strip's promise is "same joke, different template". That held
    /// while every template was two-slot: the boxes carried over verbatim. It breaks
    /// the moment structure varies — clicking from Drake (2) to Expanding Brain (4)
    /// used to leave two captions on a four-panel meme, and clicking back left four
    /// captions stacked on a two-panel one. Neither is the same joke.
    ///
    /// Redistributing captions LOCALLY can't work: going 2 → 4 needs two new lines
    /// invented in the user's language and in the joke's voice, which is a language
    /// task. So it is a second, deliberately small LLM call — no catalog in the
    /// payload, no ranking, just the captions and a target count.
    ///
    /// It is only ever reached when the count actually CHANGES (`needsRefit`); a
    /// same-count switch reuses the captions instantly, as it always did.
    public static let refitPrompt = """
    You rewrite meme captions to fit a different meme template.

    You are given the original description, the captions as they stand, and how many \
    caption slots the new template has.

    Reply with ONLY a JSON object, no preamble and no code fence:
    {"captions": ["...", "..."]}

    Rules:
    1. Return EXACTLY the requested number of captions, in order from the top (or \
    left) panel to the last.
    2. Keep the SAME joke and the SAME language as the captions you were given. Do \
    not translate them and do not change the subject.
    3. When there are more slots than before, split or extend the joke across them — \
    do not repeat a caption or pad with empty strings.
    4. When there are fewer, condense — keep the punchline.
    5. Keep each caption short, meme-style. No quotation marks around them.
    """

    /// The payload for a refit: the joke as it stands plus the target structure.
    public static func refitUserPayload(
        description: String, captions: [String], slots: Int, templateName: String
    ) -> String {
        let count = MemeCaptionSlots.clamp(slots)
        let current = captions.isEmpty
            ? "(none yet)"
            : captions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        return """
        Meme description:
        \(description.trimmingCharacters(in: .whitespacesAndNewlines))

        Current captions:
        \(current)

        The new template is "\(templateName)" and it takes \(count) caption\(count == 1 ? "" : "s").
        Return exactly \(count).
        """
    }

    /// Whether switching to a `slots`-slot template needs the refit round-trip.
    ///
    /// The fast path is the point: a same-count switch is the overwhelmingly common
    /// one (two thirds of the corpus is two-slot), and paying an LLM call to be told
    /// the captions are fine would make the strip feel slower than v5 for no gain.
    /// Also false when there are no captions to refit — an empty box set is seeded
    /// locally, not rewritten.
    public static func needsRefit(captions: [String], slots: Int) -> Bool {
        let meaningful = captions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !meaningful.isEmpty else { return false }
        return captions.count != MemeCaptionSlots.clamp(slots)
    }

    // MARK: - v7: the host decides what a caption count MEANS

    /// What to do with a caption response, given the template it has to fill (v7).
    ///
    /// ## The v6 bug this type exists to make impossible
    ///
    /// v6 had no such decision. `parseRanked` returned whatever the model wrote,
    /// `applyRanked` handed it to `seedBoxes`, and a 2-caption answer for a 4-slot
    /// Expanding Brain was padded with two blank boxes and rendered — the reported
    /// failure. The legacy `top_text`/`bottom_text` fallback made that the DEFAULT
    /// outcome for any model that reached for the classic keys, because those keys can
    /// only ever produce two.
    ///
    /// The rule is now stated once, here, and it is the host's, not the model's:
    ///
    /// * **The count matches** → render.
    /// * **The count doesn't match** → REFIT. Never render a mismatch silently; the
    ///   refit call already exists (`refitPrompt`) and says "same joke, exactly N".
    /// * **The legacy two-caption shape** is accepted as final for a **2-slot template
    ///   only**. That is the one case where `top_text`/`bottom_text` is genuinely the
    ///   right answer rather than a model that ignored the slot count. On any N≠2
    ///   template it is treated as the mismatch it is.
    public enum CaptionFit: Equatable, Sendable {
        /// The captions fill the template — render them as they are.
        case ready([String])
        /// The count is wrong; run the refit round-trip to `slots` captions.
        case refit(from: [String], to: Int)

        /// The captions to seed right now, in either case.
        ///
        /// A refit still SEEDS first: the template has already been chosen and the user
        /// should see the joke land while the refit runs, rather than an empty canvas.
        /// `seedBoxes` pads or truncates to the slot count, so this is always safe.
        public var captions: [String] {
            switch self {
            case .ready(let captions):      return captions
            case .refit(let captions, _):   return captions
            }
        }

        /// True when a second round-trip is owed.
        public var needsRefit: Bool {
            if case .refit = self { return true }
            return false
        }
    }

    /// Decide whether `captions` may be rendered on a `slots`-slot template.
    ///
    /// `wasLegacyShape` is what makes the 2-slot exception decidable: a `["a","b"]` that
    /// came from a `captions` ARRAY is the model answering a 2-slot question correctly,
    /// while the same pair from `top_text`/`bottom_text` is a model that never engaged
    /// with the slot count at all. Both are fine on a 2-slot template and neither is
    /// fine on a 4-slot one, so the flag doesn't change THIS rule — but it is carried on
    /// `RankedSpec` so the status line can be honest about which happened, and so a
    /// future rule can tell them apart without re-deriving it.
    ///
    /// Empty captions never refit: there is no joke to preserve, and asking a model to
    /// rewrite nothing into four somethings is how you get four hallucinations. They
    /// seed as empty boxes for the user to type into, exactly as `select` already does.
    public static func fit(captions: [String], slots: Int, wasLegacyShape: Bool = false) -> CaptionFit {
        let target = MemeCaptionSlots.clamp(slots)
        let meaningful = captions.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !meaningful.isEmpty else { return .ready(captions) }
        guard captions.count != target else { return .ready(captions) }
        return .refit(from: captions, to: target)
    }

    /// The status line shown while a mismatch is being refitted.
    ///
    /// Honest about the shortfall rather than a generic spinner: the user watched the
    /// model answer and is about to watch the captions CHANGE, and "Refitting…" alone
    /// would make that look like a glitch. Naming the numbers makes the second call
    /// legible as a correction.
    public static func refitStatus(wrote: Int, of slots: Int) -> String {
        "Model wrote \(wrote) of \(slots) — refitting…"
    }

    /// Parse a refit reply into exactly `slots` captions.
    ///
    /// Returns nil rather than throwing a typed error: a refit that fails must leave
    /// the user with the captions they already had, silently. The switch itself already
    /// succeeded (the template is rendering) — turning a failed nicety into a visible
    /// error would make a working action look broken.
    ///
    /// The result is always exactly `slots` long: padded with empty boxes when the
    /// model returned too few, truncated when it returned too many. The caller seeds
    /// boxes from this directly, so a length mismatch here would silently produce the
    /// wrong number of boxes — the very bug being fixed.
    public static func parseRefit(_ raw: String, slots: Int) -> [String]? {
        let count = MemeCaptionSlots.clamp(slots)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let object = firstJSONObject(in: trimmed),
              let data = object.data(using: .utf8),
              let wire = try? JSONDecoder().decode(RankedWire.self, from: data)
        else { return nil }

        let captions = wire.captions.map(clean)
        // Nothing usable came back — the legacy top/bottom fallback in `RankedWire`
        // means an object with no caption keys at all decodes to ["", ""], so an
        // all-empty result has to be refused here rather than becoming blank boxes.
        guard captions.contains(where: { !$0.isEmpty }) else { return nil }

        if captions.count >= count { return Array(captions.prefix(count)) }
        return captions + Array(repeating: "", count: count - captions.count)
    }

    // MARK: - v7: constrained decoding (the systemic fix)

    /// JSON schemas that FORCE the response shape, for servers that support
    /// constrained decoding.
    ///
    /// ## Why this is the real fix
    ///
    /// Every other guard in this file is a parser: the model writes whatever it wants
    /// and we decide afterwards whether to accept it. That is a losing game against a
    /// 1.5B local model — v5 fixed name transcription, v6 fixed the caption array, and
    /// v6 STILL shipped the bug this file's `fit` now catches, because there was always
    /// one more shape to mis-write.
    ///
    /// llama-server compiles a `json_schema` into a GBNF grammar and constrains the
    /// SAMPLER with it. A response missing `captions`, or carrying `top_text` instead,
    /// or returning three strings where four were required, is then not rejected — it
    /// is unrepresentable, because no token sequence that produces it is reachable.
    /// The whole class of bug goes away rather than being caught one shape at a time.
    ///
    /// These are built as values rather than raw JSON strings so `swift test` can
    /// assert their contents; a schema stored as a string literal would be exactly the
    /// kind of untested wiring this spike exists to avoid shipping.
    public enum Schema {

        /// The ranked-pick schema: numeric template indices plus a caption array.
        ///
        /// `templates` is `integer`-typed, which is what makes v6's numbered-reference
        /// idea airtight: a model CANNOT answer with a name it invented, because a
        /// string is not a representable token at that position.
        ///
        /// Captions are deliberately NOT pinned to a count here — the model chooses its
        /// first candidate in the same reply, so the required count isn't known when the
        /// request is built. The count is enforced host-side by `fit`, and the refit call
        /// (which DOES know the number) is schema-pinned by `refit(slots:)`.
        public static func ranked(maxCaptions: Int = MemeCaptionSlots.maximum) -> JSONValue {
            .object([
                "type": .string("object"),
                "properties": .object([
                    "templates": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "minItems": .int(1),
                        "maxItems": .int(maxCandidates),
                    ]),
                    "captions": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "minItems": .int(1),
                        "maxItems": .int(MemeCaptionSlots.clamp(maxCaptions)),
                    ]),
                    "reason": .object(["type": .string("string")]),
                ]),
                "required": .array([
                    .string("templates"), .string("captions"), .string("reason"),
                ]),
                "additionalProperties": .bool(false),
            ])
        }

        /// The refit schema: EXACTLY `slots` captions, and nothing else.
        ///
        /// `minItems == maxItems == slots` is the whole point. The refit call exists
        /// precisely because a count was wrong, so it is the one call where the required
        /// count is known up front — and pinning both bounds makes "wrote 2 of 4" a
        /// shape the sampler cannot emit. On a server with constrained decoding this
        /// makes the refit succeed on the first attempt by construction.
        public static func refit(slots: Int) -> JSONValue {
            let count = MemeCaptionSlots.clamp(slots)
            return .object([
                "type": .string("object"),
                "properties": .object([
                    "captions": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "minItems": .int(count),
                        "maxItems": .int(count),
                    ]),
                ]),
                "required": .array([.string("captions")]),
                "additionalProperties": .bool(false),
            ])
        }
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
