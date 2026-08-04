import Foundation

/// A meme template from the Imgflip public catalog (`https://api.imgflip.com/get_memes`).
///
/// That endpoint is free, key-less, and read-only: it returns the ~100 most popular
/// templates as `{id, name, url, width, height, box_count}`. The plugin uses it ONLY
/// to find a base image — captioning happens locally with CoreGraphics, so no text,
/// no audio, and no LLM output is ever sent to imgflip.
public struct MemeTemplate: Equatable, Sendable, Codable, Identifiable {
    /// Source-qualified id (`"imgflip:181913649"`, `"userLibrary:<uuid>"`) — see
    /// `MemeTemplateCatalog.qualifiedID`. Qualified so two providers can never
    /// collide into one image-cache entry.
    public let id: String
    /// Display name, e.g. "Distracted Boyfriend". This is the string the LLM is asked
    /// to copy verbatim and the key candidates are validated against. For a
    /// user-library template it is whatever the user named it, in their own script.
    public let name: String
    /// Where the blank template image lives: an `https:` URL for the remote
    /// providers, a `file:` URL for the user's own library. Both are just "a string
    /// that locates the image", which is what lets all three sources share one
    /// fetch/render path.
    public let url: String
    public let width: Int
    public let height: Int
    /// Which provider contributed this template. Drives the Browse grid's badge and
    /// whether the image is loaded from disk or the network.
    public let source: MemeTemplateSource
    /// Alternate search terms. memegen ships these ("Ain't Nobody Got Time For That"
    /// on a template *named* "Sweet Brown"); imgflip has none; the user library
    /// carries the original filename. Searching them is what makes a merged,
    /// multi-lingual corpus findable — see `MemeTemplateCatalog.search`.
    public let keywords: [String]

    /// How many caption slots this template actually has (v6).
    ///
    /// ## Why this exists
    ///
    /// Up to v5 every meme was captioned top-and-bottom, because that is what the LLM
    /// was asked for and what `seedBoxes` produced. That is *wrong for most of the
    /// corpus*: Drake is two SIDE labels, Distracted Boyfriend is three, Expanding
    /// Brain is four. Rendering a four-panel meme with a top line and a bottom line
    /// isn't a stylistic choice, it's a broken meme — the joke lives in the per-panel
    /// captions.
    ///
    /// Both remote sources carried this all along and v5 discarded it: memegen's
    /// `/templates` ships `lines`, imgflip's `get_memes` ships `box_count`. Now they
    /// are decoded into this field, the LLM is asked for exactly this many captions,
    /// and `MemeCaptionLayout.seedBoxes(slots:)` lays out that many boxes.
    ///
    /// Defaults to `MemeCaptionSlots.default` (2) so an older cache, a user-library
    /// import, or a source that doesn't report it still behaves exactly as it did.
    /// Clamped at construction — see `MemeCaptionSlots.clamp` — because a wire value
    /// of 0 (or 40) must not become 0 caption boxes (or 40).
    public let captionSlots: Int

    public init(
        id: String, name: String, url: String, width: Int, height: Int,
        source: MemeTemplateSource = .imgflip, keywords: [String] = [],
        captionSlots: Int = MemeCaptionSlots.default
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.width = width
        self.height = height
        self.source = source
        self.keywords = keywords
        self.captionSlots = MemeCaptionSlots.clamp(captionSlots)
    }

    /// Decoding tolerates a missing `source`/`keywords` so a catalog cache written by
    /// an older build still loads instead of being discarded — the cache is a
    /// performance artifact, but throwing it away on every upgrade would make the
    /// first launch after an update look like the offline bug this release fixes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        width = (try? c.decode(Int.self, forKey: .width)) ?? 0
        height = (try? c.decode(Int.self, forKey: .height)) ?? 0
        source = (try? c.decode(MemeTemplateSource.self, forKey: .source)) ?? .imgflip
        keywords = (try? c.decode([String].self, forKey: .keywords)) ?? []
        // A cache written by a v5 build has no `captionSlots`. Defaulting rather than
        // failing keeps the offline path working across the upgrade — the cache is a
        // performance artifact, and discarding it would make the first launch after an
        // update look like the offline bug this plugin already fixed once.
        captionSlots = MemeCaptionSlots.clamp(
            (try? c.decode(Int.self, forKey: .captionSlots)) ?? MemeCaptionSlots.default)
    }
}

/// How many caption slots a template has, and what a sane value looks like (v6).
///
/// A tiny namespace rather than loose constants because the clamp is a RULE with a
/// reason, applied at three boundaries (imgflip's `box_count`, memegen's `lines`, and
/// the cache decoder) and it must agree at all three.
public enum MemeCaptionSlots {

    /// What a template gets when its source doesn't say — the classic top/bottom meme.
    ///
    /// Two, because that is what every caption path did before slots existed: a
    /// template with unknown structure must degrade to v5's behaviour, not to a guess.
    public static let `default` = 2

    /// The floor. A template with zero caption slots would seed zero boxes and give
    /// the user a picture with no way to type on it — the source reporting `0` (or a
    /// negative, or a corrupt cache) must never produce that dead end.
    public static let minimum = 1

    /// The ceiling. memegen reports up to 8 `lines`; the cap exists so a wire value
    /// nobody anticipated can't seed a screenful of boxes the user has to delete by
    /// hand. Real templates top out at 8, so this clips nothing that exists today.
    public static let maximum = 8

    /// Bring any reported count into range.
    public static func clamp(_ raw: Int) -> Int {
        min(max(raw, minimum), maximum)
    }
}

/// The Imgflip `get_memes` response envelope.
public struct MemeTemplateCatalogResponse: Decodable, Sendable {
    /// The raw wire shape. Decoded into a separate type rather than straight into
    /// `MemeTemplate` because the id has to be SOURCE-QUALIFIED before it becomes a
    /// catalog id, and a `Decodable` conformance can't know which provider it is
    /// being decoded for.
    public struct Wire: Decodable, Sendable {
        public let id: String
        public let name: String
        public let url: String
        public let width: Int
        public let height: Int
        /// How many caption boxes the template really has (v6). imgflip has shipped
        /// this on `get_memes` all along and v5 threw it away, which is why Distracted
        /// Boyfriend (3) and Expanding Brain (4) were captioned top-and-bottom.
        /// Optional so a response missing it decodes to the 2-slot default rather than
        /// failing the whole catalog.
        public let boxCount: Int?

        private enum CodingKeys: String, CodingKey {
            case id, name, url, width, height
            case boxCount = "box_count"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decode(String.self, forKey: .url)
            width = (try? c.decode(Int.self, forKey: .width)) ?? 0
            height = (try? c.decode(Int.self, forKey: .height)) ?? 0
            boxCount = try? c.decode(Int.self, forKey: .boxCount)
        }
    }
    public struct Payload: Decodable, Sendable {
        public let memes: [Wire]
    }
    public let success: Bool
    public let data: Payload?

    /// The templates, or empty when the API reported failure.
    public var templates: [MemeTemplate] {
        guard success else { return [] }
        return (data?.memes ?? []).map { wire in
            MemeTemplate(
                id: MemeTemplateCatalog.qualifiedID(.imgflip, wire.id),
                name: wire.name, url: wire.url,
                width: wire.width, height: wire.height,
                source: .imgflip, keywords: [],
                captionSlots: wire.boxCount ?? MemeCaptionSlots.default)
        }
    }
}

/// The memegen.link `/templates` response (spike v3).
///
/// A second key-less, read-only catalog — ~200 templates, many of which imgflip's
/// top-100 popularity list doesn't carry. Like imgflip it is used ONLY to locate a
/// blank image: captioning stays local, so memegen's own caption-rendering URL API
/// (`/images/<id>/<top>/<bottom>.jpg`) is deliberately NOT used. Routing the user's
/// text through a URL would put their words on someone else's server, which is
/// exactly what this plugin avoids.
///
/// The response is a bare JSON ARRAY, not an envelope, so failure shows up as a
/// decode error rather than a `success: false` flag.
public struct MemegenTemplateResponse: Decodable, Sendable {
    public struct Wire: Decodable, Sendable {
        public let id: String
        public let name: String
        /// The blank (caption-less) image URL.
        public let blank: String
        /// Alternate names — the field that makes a merged corpus searchable.
        public let keywords: [String]?
        /// How many caption lines the template takes (v6).
        ///
        /// memegen's `/templates` reports this per template — verified against the live
        /// API: of its 212 templates, 166 are 2-line, 23 are 3-line, 7 are 4-line, and
        /// the rest spread over 1/5/6/8. It ships the COUNT only; there is no box
        /// geometry anywhere in the payload (the fields are `lines`, `overlays`,
        /// `styles`, `blank`, `example`, `source`, `keywords`), so positions have to be
        /// synthesized — see `MemeCaptionLayout.slotCenters`.
        public let lines: Int?

        private enum CodingKeys: String, CodingKey { case id, name, blank, keywords, lines }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            blank = try c.decode(String.self, forKey: .blank)
            keywords = try? c.decode([String].self, forKey: .keywords)
            lines = try? c.decode(Int.self, forKey: .lines)
        }
    }

    public let templates: [MemeTemplate]

    public init(from decoder: Decoder) throws {
        let wires = try [Wire](from: decoder)
        templates = wires.compactMap { wire in
            // A template with no name can't be searched, de-duplicated, or copied
            // verbatim by the LLM — drop it at the boundary rather than letting it
            // occupy a grid cell nobody can reach.
            let name = wire.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !wire.blank.isEmpty else { return nil }
            return MemeTemplate(
                id: MemeTemplateCatalog.qualifiedID(.memegen, wire.id),
                name: name, url: wire.blank,
                // memegen doesn't report dimensions; 0 means "ask the image".
                // Nothing in the render path uses these (the layout works off the
                // decoded NSImage's real pixel size), so they stay honest zeros
                // rather than invented defaults.
                width: 0, height: 0,
                source: .memegen, keywords: wire.keywords ?? [],
                captionSlots: wire.lines ?? MemeCaptionSlots.default)
        }
    }
}

/// Local, lexical template lookup over the catalog (spike).
///
/// Matching is LOCAL — the catalog is ~100 short English names, so a token-overlap
/// score beats anything heavier and keeps the whole decision pure and testable. No
/// second network call, no embedding model.
///
/// Scoring, highest first:
/// 1. **Exact** name match (case/punctuation-insensitive) — 1000.
/// 2. **Full-phrase containment** either way ("drake" ⊂ "Drake Hotline Bling") —
///    500 plus a closeness bonus, so the shortest containing name wins.
/// 3. **Token overlap** — 100 per query token found in the name, plus a small bonus
///    for a tighter name, so "Two Buttons" beats "Two Buttons But Worse" on "two buttons".
///
/// Ties break on the catalog's own order, which is popularity-ranked — the more
/// famous template is the better guess.
///
/// **v2 note.** v1's `bestMatch` — "return the single best template, or the most
/// popular one if nothing scores" — was DELETED. That built-in fallback is precisely
/// the reported bug: it turned "yoda meme" into a confident Drake with no way for the
/// caller to know. The two survivors both refuse to guess, and each returns an empty
/// result the UI must handle: `ranked` (score-ordered candidates) and `search` (the
/// user's own query over the whole corpus).
public enum MemeTemplateMatcher {

    // MARK: - Fallback ranking (v2)

    /// Rank the catalog by how well each name scores against a free-text query,
    /// keeping only entries that score at all.
    ///
    /// This is the v2 fallback: when the model proposes only template names that
    /// don't exist (the "yoda" case), the candidate strip would otherwise be pure
    /// popularity — the same blind guess v1 made, just with more thumbnails. Scoring
    /// the user's own description against the catalog at least puts anything lexically
    /// related in front of them first.
    ///
    /// This NEVER substitutes a popular template for a zero score:
    /// a query matching nothing returns an EMPTY list, and the caller is responsible
    /// for deciding what to show and for saying that nothing matched. That split —
    /// ranking here, fallback policy at the call site — is what makes the fallback
    /// visible instead of silent.
    public static func ranked(
        for query: String, in catalog: [MemeTemplate], limit: Int
    ) -> [MemeTemplate] {
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty, limit > 0 else { return [] }

        // A named struct rather than a tuple chain: the inferred-tuple version was
        // too much for the type checker ("unable to type-check in reasonable time").
        struct Scored {
            let index: Int
            let template: MemeTemplate
            let score: Int
        }

        // `index` preserves the catalog's popularity order as the tie-break, since
        // `sorted(by:)` is not guaranteed stable.
        var scored: [Scored] = []
        for (index, template) in catalog.enumerated() {
            let value = score(query: query, queryTokens: queryTokens, name: template.name)
            guard value > 0 else { continue }
            scored.append(Scored(index: index, template: template, score: value))
        }

        scored.sort { left, right in
            left.score == right.score ? left.index < right.index : left.score > right.score
        }
        return scored.prefix(limit).map(\.template)
    }

    // MARK: - Browse all (manual override)

    /// Filter the catalog by a user-typed search string, for the "Browse all" grid.
    ///
    /// This is the honest answer to "yoda isn't in the corpus": the user can see and
    /// search every template the plugin has, and pick one the model never proposed.
    ///
    /// **v4: ranked, not all-or-nothing.** This now delegates to
    /// `MemeTemplateCatalog.search`, which scores name AND keywords and orders the
    /// results best-first. The v3 rule here — every query token had to appear in the
    /// name — is what made a content description ("the worst day for the planet")
    /// return nothing at all: one unmatched token vetoed every token that did match.
    /// See `MemeTemplateCatalog.score` for the tiers.
    ///
    /// Still **no fallback**: a query matching nothing returns nothing, because an
    /// empty grid saying "no templates match" is the entire point — silently
    /// substituting popular templates is the bug this whole change exists to fix.
    public static func search(_ query: String, in catalog: [MemeTemplate]) -> [MemeTemplate] {
        MemeTemplateCatalog.search(query, in: catalog)
    }

    // MARK: - Scoring

    static func score(query: String, queryTokens: [String], name: String) -> Int {
        let normalizedQuery = normalize(query)
        let normalizedName = normalize(name)

        if normalizedQuery == normalizedName { return 1000 }

        let nameTokens = tokens(in: name)

        // Whole-phrase containment in either direction. The closeness bonus favors
        // the shortest name that still contains the query.
        if !normalizedQuery.isEmpty,
           normalizedName.contains(normalizedQuery) || normalizedQuery.contains(normalizedName) {
            let lengthGap = abs(normalizedName.count - normalizedQuery.count)
            return 500 + max(0, 50 - lengthGap)
        }

        let nameTokenSet = Set(nameTokens)
        let overlap = queryTokens.filter { nameTokenSet.contains($0) }.count
        guard overlap > 0 else { return 0 }

        // Prefer a name that is mostly the matched tokens over one that buries them
        // among many others.
        let tightness = max(0, 20 - (nameTokens.count - overlap) * 4)
        return overlap * 100 + tightness
    }

    /// Lowercase, strip punctuation, collapse whitespace.
    public static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "en_US"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Tokens for SEARCH scoring (v4).
    ///
    /// Like `tokens`, but it degrades gracefully instead of vanishing: a query made
    /// entirely of stopwords ("the man") would tokenize to nothing and silently reset
    /// the grid to the whole catalog, so when stopword removal empties the query we
    /// fall back to the raw normalized words. Single characters survive here too — a
    /// user typing "x" is narrowing, not searching for nothing.
    public static func searchTokens(in value: String) -> [String] {
        let meaningful = tokens(in: value)
        guard meaningful.isEmpty else { return meaningful }
        return normalize(value).split(separator: " ").map(String.init)
    }

    /// Meaningful tokens, with English stopwords dropped so "the drake meme" and
    /// "drake" score the same.
    public static func tokens(in value: String) -> [String] {
        let stopwords: Set<String> = ["the", "a", "an", "of", "and", "meme", "guy", "man"]
        return normalize(value)
            .split(separator: " ")
            .map(String.init)
            .filter { !stopwords.contains($0) && $0.count > 1 }
    }
}
