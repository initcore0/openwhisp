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

    /// Search the merged catalog, matching a template's NAME *or* its keywords.
    ///
    /// Keywords are what make a merged corpus searchable across cultures: memegen
    /// ships "Ain't Nobody Got Time For That" as a keyword on a template *named*
    /// "Sweet Brown", so a name-only search fails the exact query a user would type.
    /// User-library templates get the filename as an implicit keyword for the same
    /// reason.
    ///
    /// Like `MemeTemplateMatcher.search`, this NEVER falls back: no match is an empty
    /// result, because a silently substituted popular template is the original bug.
    public static func search(_ query: String, in catalog: [MemeTemplate]) -> [MemeTemplate] {
        let normalizedQuery = MemeTemplateMatcher.normalize(query)
        guard !normalizedQuery.isEmpty else { return catalog }

        let needles = normalizedQuery.split(separator: " ").map(String.init)

        return catalog.filter { template in
            // Every token must appear SOMEWHERE across the name and keywords
            // combined, so "russian cat" matches a template named "Cat" with the
            // keyword "Russian" — the cross-field case that a per-field search
            // would miss.
            let haystack = ([template.name] + template.keywords)
                .map { MemeTemplateMatcher.normalize($0) }
                .joined(separator: " ")
            return needles.allSatisfy { haystack.contains($0) }
        }
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
}
