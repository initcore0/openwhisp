import Foundation

/// Where a template came from (spike v3).
///
/// The owner's report was that the corpus was "too limited and America-centric".
/// One catalog can't fix that — imgflip's top 100 is an English-language popularity
/// list, and *any* curated remote list will be someone else's culture. So the corpus
/// becomes a MERGE of sources, and the one that actually answers "worldwide" is the
/// user's own library: an image the user imported is by definition a template from
/// their culture, and it needs no API, no key, and no network.
///
/// Order matters and is deliberate — see `MemeTemplateCatalog.merge`.
public enum MemeTemplateSource: String, Equatable, Sendable, Codable, CaseIterable {
    /// imgflip's key-less `get_memes` top 100.
    case imgflip
    /// memegen.link's key-less `/templates` list (~200 more).
    case memegen
    /// Images the user imported themselves, stored under Application Support.
    case userLibrary

    /// The label shown next to a template in the Browse grid, so the user can tell
    /// where a template came from — particularly which ones are theirs.
    public var label: String {
        switch self {
        case .imgflip:     return "imgflip"
        case .memegen:     return "memegen"
        case .userLibrary: return "My library"
        }
    }
}

/// A merged, de-duplicated, searchable template catalog (spike v3).
///
/// This is the pure half of the provider system: given templates from any number of
/// sources, it decides which survive, in what order, and which ones a query matches.
/// The IO — HTTP, disk, thumbnails — lives in the app layer, so all the *policy*
/// here is pinned by `swift test`.
public enum MemeTemplateCatalog {

    /// Merge templates from several sources into one catalog.
    ///
    /// **Precedence is user-first.** The user's own library wins every collision,
    /// then imgflip (popularity-ranked and the corpus the LLM prompt was tuned on),
    /// then memegen. If the user imported their own "Drake", theirs is the Drake —
    /// a remote catalog must never shadow a local file the user deliberately added.
    /// This is the same "earlier provider wins" rule `PluginDiscovery` already uses,
    /// pointed the other way on purpose: there, trust decreases with writability;
    /// here, the writable source IS the trusted one because the user put it there.
    ///
    /// De-duplication is by NORMALIZED NAME, not by id: imgflip and memegen both
    /// carry "Distracted Boyfriend" under completely different ids, and showing the
    /// user the same meme twice in a grid is the visible bug. Ids stay unique across
    /// sources because `MemeTemplate.id` is prefixed at the provider (see
    /// `qualifiedID`), so a de-dup by id would silently do nothing.
    ///
    /// Within a source the incoming order is preserved — imgflip's order is its
    /// popularity ranking, and the LLM payload truncates from the end, so scrambling
    /// it would quietly degrade the model's picks.
    public static func merge(_ groups: [[MemeTemplate]]) -> [MemeTemplate] {
        var out: [MemeTemplate] = []
        var seen = Set<String>()

        for group in groups {
            for template in group {
                let key = MemeTemplateMatcher.normalize(template.name)
                // A template with an unusable name can't be de-duplicated or searched
                // for, and can't be copied verbatim by the LLM. Drop it rather than
                // letting it occupy a grid cell nobody can reach.
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(template)
            }
        }
        return out
    }

    /// Namespace a provider's raw id so ids stay unique across sources.
    ///
    /// imgflip ids are numeric ("181913649") and memegen's are slugs ("drake"), so
    /// they don't collide *today* — but the user library mints its own ids, and two
    /// sources agreeing on an id would make the image cache serve one template's
    /// picture for another. Prefixing is cheap insurance against a bug that would
    /// look like a rendering glitch rather than an id collision.
    public static func qualifiedID(_ source: MemeTemplateSource, _ rawID: String) -> String {
        "\(source.rawValue):\(rawID)"
    }

    /// The source a qualified id came from, or nil when the id isn't qualified.
    ///
    /// Used to decide whether a template's image is a local file (user library) or a
    /// URL to fetch, without threading the source through every call site.
    public static func source(ofQualifiedID id: String) -> MemeTemplateSource? {
        guard let separator = id.firstIndex(of: ":") else { return nil }
        return MemeTemplateSource(rawValue: String(id[id.startIndex..<separator]))
    }

    /// Search the merged catalog, matching a template's NAME *or* its keywords, and
    /// return the results RANKED by how well each one matched.
    ///
    /// Keywords are what make a merged corpus searchable across cultures: memegen
    /// ships "Ain't Nobody Got Time For That" as a keyword on a template *named*
    /// "Sweet Brown", so a name-only search fails the exact query a user would type.
    /// User-library templates get the filename as an implicit keyword for the same
    /// reason.
    ///
    /// ## v4 — why the all-tokens rule had to go
    ///
    /// v3 required EVERY query token to appear somewhere in name+keywords
    /// (`needles.allSatisfy`). That is defensible for a user typing a name letter by
    /// letter, and fatal for the way people actually describe a meme. The owner's
    /// repro: "the worst day for the planet" never surfaces the Bart Simpson
    /// "Worst Day Of My Life So Far" template, because "planet" appears in neither
    /// its name nor its keywords — so one unmatched token vetoes the four that
    /// matched perfectly. A content description can essentially never satisfy an
    /// all-tokens rule, which made describing a meme the one thing search couldn't do.
    ///
    /// So matching is now SCORED (see `score`) and the result is ordered best-first.
    /// A template that matches some tokens is shown, ranked below one that matched
    /// more. Popularity — the catalog's own order — breaks ties, so the famous
    /// template wins when two score the same.
    ///
    /// What did NOT change: this still **never falls back**. A query that matches
    /// nothing at all returns an EMPTY list, because a silently substituted popular
    /// template is the original bug this whole spike exists to fix. "Rank partial
    /// matches" and "invent a match" are different things.
    public static func search(_ query: String, in catalog: [MemeTemplate]) -> [MemeTemplate] {
        ranked(query, in: catalog, limit: catalog.count).map(\.template)
    }

    /// A scored search hit. Exposed so callers that need the score (the LLM
    /// prefilter, tests) don't have to re-derive it.
    public struct Match: Equatable, Sendable {
        public let template: MemeTemplate
        public let score: Int
        public init(template: MemeTemplate, score: Int) {
            self.template = template
            self.score = score
        }
    }

    /// The scored, ordered matches for a query — the engine behind both `search` and
    /// `prefilter`.
    ///
    /// Ordering is score descending, then the catalog's own index ascending. The
    /// index tie-break matters twice: `sorted(by:)` is not guaranteed stable, and the
    /// catalog order IS the popularity ranking, so it is the right thing to fall back
    /// on when two templates match a query equally well.
    public static func ranked(
        _ query: String, in catalog: [MemeTemplate], limit: Int
    ) -> [Match] {
        let normalizedQuery = MemeTemplateMatcher.normalize(query)
        let cap = max(0, limit)
        guard cap > 0 else { return [] }
        // An empty query isn't a failed search — it's "no filter applied", which the
        // Browse grid renders as the whole corpus in popularity order.
        guard !normalizedQuery.isEmpty else {
            return catalog.prefix(cap).map { Match(template: $0, score: 0) }
        }

        let queryTokens = MemeTemplateMatcher.searchTokens(in: query)
        guard !queryTokens.isEmpty else {
            return catalog.prefix(cap).map { Match(template: $0, score: 0) }
        }

        // A named struct rather than a tuple chain: the inferred-tuple version of this
        // sort was too much for the type checker in `MemeTemplateMatcher.ranked`, and
        // there is no reason to rediscover that here.
        struct Scored {
            let index: Int
            let template: MemeTemplate
            let score: Int
        }

        var scored: [Scored] = []
        for (index, template) in catalog.enumerated() {
            let value = score(queryTokens: queryTokens, normalizedQuery: normalizedQuery,
                              template: template)
            guard value > 0 else { continue }
            scored.append(Scored(index: index, template: template, score: value))
        }

        scored.sort { left, right in
            left.score == right.score ? left.index < right.index : left.score > right.score
        }
        return scored.prefix(cap).map { Match(template: $0.template, score: $0.score) }
    }

    /// Score one template against a query, over its name AND its keywords.
    ///
    /// The tiers, and why each exists:
    ///
    /// * **Exact name** (10_000) — typing a template's name means you want that
    ///   template, full stop.
    /// * **Whole-phrase containment** in the name (5_000 + closeness) — "drake" ⊂
    ///   "Drake Hotline Bling". The closeness bonus prefers the shortest name that
    ///   still contains the phrase.
    /// * **Per-token matches** — this is the tier that fixes the owner's repro. Each
    ///   query token is worth its best match anywhere in the template:
    ///   100 for a whole-token hit in the NAME, 60 for one in a KEYWORD (a name match
    ///   is stronger evidence than an alias), and 25/15 for a PREFIX hit
    ///   ("planetary" → "planet"), which counts for less precisely because it is
    ///   weaker evidence. Summing over tokens means more matched tokens ranks higher,
    ///   which is the whole ordering the owner asked for.
    /// * **Coverage bonus** — a template matching a larger FRACTION of the query is
    ///   worth more than one matching the same count out of a longer query, so short
    ///   precise queries stay precise.
    ///
    /// Returns 0 when nothing matched, which is what keeps "no results" possible.
    public static func score(
        queryTokens: [String], normalizedQuery: String, template: MemeTemplate
    ) -> Int {
        let normalizedName = MemeTemplateMatcher.normalize(template.name)
        if !normalizedName.isEmpty, normalizedName == normalizedQuery { return 10_000 }

        if !normalizedQuery.isEmpty, !normalizedName.isEmpty,
           normalizedName.contains(normalizedQuery) || normalizedQuery.contains(normalizedName) {
            let lengthGap = abs(normalizedName.count - normalizedQuery.count)
            return 5_000 + max(0, 100 - lengthGap)
        }

        let nameTokens = Set(MemeTemplateMatcher.normalize(template.name).split(separator: " ").map(String.init))
        let keywordTokens = Set(
            template.keywords
                .flatMap { MemeTemplateMatcher.normalize($0).split(separator: " ").map(String.init) })

        var total = 0
        var matchedTokens = 0
        for token in queryTokens {
            var best = 0
            if nameTokens.contains(token) { best = 100 }
            else if keywordTokens.contains(token) { best = 60 }
            else if nameTokens.contains(where: { $0.hasPrefix(token) || token.hasPrefix($0) }) { best = 25 }
            else if keywordTokens.contains(where: { $0.hasPrefix(token) || token.hasPrefix($0) }) { best = 15 }

            if best > 0 {
                total += best
                matchedTokens += 1
            }
        }
        guard matchedTokens > 0 else { return 0 }

        // Reward matching a larger share of what the user actually said.
        let coverage = (matchedTokens * 50) / queryTokens.count
        return total + coverage
    }

    /// The templates handed to the LLM to rank, chosen by LOCAL relevance to the
    /// user's description rather than by raw popularity.
    ///
    /// ## Why this exists (v4)
    ///
    /// v3 gave the model `promptNames(catalog, limit: 100)` — the first hundred
    /// templates in popularity order, names only. That has two failures the owner hit:
    /// the genuinely relevant template can sit at position 180 of a merged ~300 corpus
    /// and never enter the prompt at all, and a model given bare NAMES cannot connect
    /// "the worst day for the planet" to a template whose relevance lives in its
    /// KEYWORDS.
    ///
    /// So the catalog is prefiltered locally first: score every template against the
    /// user's own words, keep the top `limit`, and hand the model that shortlist WITH
    /// its keywords (see `promptLines`). Describing meme CONTENT now finds templates
    /// through their keywords, and the shortlist is small enough that a tiny local
    /// model can actually attend to all of it.
    ///
    /// Falls back to popularity order when the description matches nothing — the model
    /// still deserves a corpus to choose from, and the UI already states plainly when
    /// nothing matched.
    public static func prefilter(
        for description: String, in catalog: [MemeTemplate], limit: Int
    ) -> [MemeTemplate] {
        let cap = max(0, limit)
        guard cap > 0 else { return [] }

        let hits = ranked(description, in: catalog, limit: cap).map(\.template)
        guard !hits.isEmpty else { return Array(catalog.prefix(cap)) }

        // Top up with popular templates when the query was narrow, so the model always
        // sees a full shortlist rather than the two things that happened to match.
        guard hits.count < cap else { return hits }
        var out = hits
        var seen = Set(hits.map(\.id))
        for template in catalog where out.count < cap {
            guard !seen.contains(template.id) else { continue }
            seen.insert(template.id)
            out.append(template)
        }
        return out
    }

    /// The names handed to the LLM, capped so a merged ~300-name corpus doesn't blow
    /// a small local model's context.
    ///
    /// The cap is applied AFTER the merge so the user's own templates — which sort
    /// first — are always in the prompt. That is the point: a user who imported ten
    /// Russian templates should have the model able to pick them, even if imgflip's
    /// hundred would otherwise fill the budget.
    public static func promptNames(_ catalog: [MemeTemplate], limit: Int) -> [String] {
        Array(catalog.prefix(max(0, limit)).map(\.name))
    }

    /// One prompt line per template: the name, plus its keywords in parentheses.
    ///
    /// The keywords are the point (v4). "Worst Day Of My Life So Far" carries aliases
    /// a user's description will hit even when the NAME shares no words with it, so
    /// showing the model only names throws away the very signal that connects a
    /// content description to a template. Templates with no keywords render as a bare
    /// name, so nothing is padded with noise.
    ///
    /// The name is always FIRST on the line and unadorned, because the prompt asks the
    /// model to copy the name verbatim and `MemeAI.validate` checks it against the
    /// catalog — a line the model can't cleanly copy a name out of would be rejected
    /// as a hallucination.
    public static func promptLines(_ catalog: [MemeTemplate], limit: Int) -> [String] {
        catalog.prefix(max(0, limit)).map { template in
            let keywords = template.keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !keywords.isEmpty else { return template.name }
            return "\(template.name) (\(keywords.prefix(6).joined(separator: ", ")))"
        }
    }
}
