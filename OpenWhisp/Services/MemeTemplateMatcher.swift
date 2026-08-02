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

    public init(
        id: String, name: String, url: String, width: Int, height: Int,
        source: MemeTemplateSource = .imgflip, keywords: [String] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.width = width
        self.height = height
        self.source = source
        self.keywords = keywords
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
                source: .imgflip, keywords: [])
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

        private enum CodingKeys: String, CodingKey { case id, name, blank, keywords }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            blank = try c.decode(String.self, forKey: .blank)
            keywords = try? c.decode([String].self, forKey: .keywords)
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
                source: .memegen, keywords: wire.keywords ?? [])
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
    /// Deliberately unlike v1's deleted `bestMatch`: no scoring, no threshold, and
    /// above all **no fallback**. A search that matches nothing returns nothing, because an
    /// empty grid saying "no templates match" is the entire point — silently
    /// substituting popular templates is the bug this whole change exists to fix.
    ///
    /// Matching is substring-based over the normalized name so it is
    /// case/diacritic/punctuation-insensitive, and multi-word queries match when
    /// EVERY token appears somewhere in the name (so "drake bling" finds "Drake
    /// Hotline Bling"). Catalog order — imgflip's popularity ranking — is preserved.
    public static func search(_ query: String, in catalog: [MemeTemplate]) -> [MemeTemplate] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return catalog }

        // Split on the normalized form, not `tokens`: stopword removal is right for
        // matching an LLM's phrase, wrong for a user typing letter by letter — a
        // search for "the" should still narrow the list rather than reset it.
        let needles = normalizedQuery.split(separator: " ").map(String.init)

        return catalog.filter { template in
            let haystack = normalize(template.name)
            return needles.allSatisfy { haystack.contains($0) }
        }
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
    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "en_US"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Meaningful tokens, with English stopwords dropped so "the drake meme" and
    /// "drake" score the same.
    static func tokens(in value: String) -> [String] {
        let stopwords: Set<String> = ["the", "a", "an", "of", "and", "meme", "guy", "man"]
        return normalize(value)
            .split(separator: " ")
            .map(String.init)
            .filter { !stopwords.contains($0) && $0.count > 1 }
    }
}
