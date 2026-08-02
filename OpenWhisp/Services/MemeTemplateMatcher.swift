import Foundation

/// A meme template from the Imgflip public catalog (`https://api.imgflip.com/get_memes`).
///
/// That endpoint is free, key-less, and read-only: it returns the ~100 most popular
/// templates as `{id, name, url, width, height, box_count}`. The plugin uses it ONLY
/// to find a base image — captioning happens locally with CoreGraphics, so no text,
/// no audio, and no LLM output is ever sent to imgflip.
public struct MemeTemplate: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    /// Display name, e.g. "Distracted Boyfriend". English — this is what the LLM's
    /// `template_query` is matched against.
    public let name: String
    /// Direct image URL (jpg/png) for the blank template.
    public let url: String
    public let width: Int
    public let height: Int

    public init(id: String, name: String, url: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.width = width
        self.height = height
    }
}

/// The Imgflip `get_memes` response envelope.
public struct MemeTemplateCatalogResponse: Decodable, Sendable {
    public struct Payload: Decodable, Sendable {
        public let memes: [MemeTemplate]
    }
    public let success: Bool
    public let data: Payload?

    /// The templates, or empty when the API reported failure.
    public var templates: [MemeTemplate] { success ? (data?.memes ?? []) : [] }
}

/// Picks the template whose name best matches the LLM's `template_query` (spike).
///
/// Matching is LOCAL and lexical — the catalog is ~100 short English names, so a
/// token-overlap score beats anything heavier and keeps the whole decision pure and
/// testable. No second network call, no embedding model.
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
public enum MemeTemplateMatcher {

    /// The minimum score worth accepting. Below this we'd be picking essentially at
    /// random, and a confidently-wrong template is worse than an honest fallback, so
    /// the caller falls back to the catalog's most popular entry instead.
    public static let minimumScore = 100

    /// Find the best template for a query. Returns nil only for an empty catalog.
    ///
    /// A query that matches nothing yields the catalog's FIRST entry (most popular)
    /// rather than nil: the user dictated a meme and should get a meme. The caller
    /// surfaces that this was a fallback.
    public static func bestMatch(
        for query: String, in catalog: [MemeTemplate]
    ) -> Match? {
        guard !catalog.isEmpty else { return nil }

        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else {
            return Match(template: catalog[0], score: 0, isFallback: true)
        }

        var best: (template: MemeTemplate, score: Int)?

        for template in catalog {
            let score = score(query: query, queryTokens: queryTokens, name: template.name)
            // Strictly greater keeps the earlier (more popular) template on a tie.
            if score > (best?.score ?? Int.min) {
                best = (template, score)
            }
        }

        guard let best, best.score >= minimumScore else {
            return Match(template: catalog[0], score: best?.score ?? 0, isFallback: true)
        }
        return Match(template: best.template, score: best.score, isFallback: false)
    }

    /// The chosen template plus why.
    public struct Match: Equatable, Sendable {
        public let template: MemeTemplate
        public let score: Int
        /// True when nothing scored well enough and the most-popular template was
        /// substituted — the UI says so rather than pretending it understood.
        public let isFallback: Bool

        public init(template: MemeTemplate, score: Int, isFallback: Bool) {
            self.template = template
            self.score = score
            self.isFallback = isFallback
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
