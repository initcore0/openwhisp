import Foundation

/// The disk-cache policy for the merged template catalog (spike v3).
///
/// Two owner requirements drive this: browsing must be **instant**, and the plugin
/// must **work offline after the first fetch**. Both fall out of the same rule —
/// always read the cache first, and treat the network as a background refresh rather
/// than a precondition.
///
/// The pure part (this file) decides *whether* to refresh and *what to do when the
/// refresh fails*. The app layer does the reading and writing.
public enum MemeCatalogCache {

    /// The cached catalog file's shape.
    ///
    /// Versioned and stamped: the version lets a format change migrate instead of
    /// silently mis-decoding, and the timestamp is what `shouldRefresh` reasons over.
    public struct Cached: Equatable, Sendable, Codable {
        public var version: Int
        public var fetchedAt: Date
        public var templates: [MemeTemplate]

        public init(version: Int = MemeCatalogCache.currentVersion, fetchedAt: Date, templates: [MemeTemplate]) {
            self.version = version
            self.fetchedAt = fetchedAt
            self.templates = templates
        }
    }

    public static let currentVersion = 1

    public static let fileName = "catalog-cache.json"

    /// How long a cached catalog is considered fresh.
    ///
    /// Meme template catalogs change on the order of months, and a stale entry costs
    /// the user nothing — the template still renders. A day balances "picks up new
    /// templates eventually" against "never blocks the UI on a network call the user
    /// didn't ask for".
    public static let maxAge: TimeInterval = 60 * 60 * 24

    /// What to do on window open, given what is on disk.
    public enum Decision: Equatable, Sendable {
        /// Nothing usable cached — fetch before the user can browse.
        case fetchNow
        /// Cache is usable and fresh; use it and don't touch the network.
        case useCache
        /// Cache is usable but stale; show it IMMEDIATELY and refresh behind it.
        ///
        /// This is the case that makes browsing feel instant: the user never waits on
        /// a refresh, and a failed one costs them nothing because they are already
        /// looking at the cached corpus.
        case useCacheAndRefresh
    }

    /// Decide how to open the catalog.
    ///
    /// A cache from a FUTURE version is treated as absent rather than trusted: a
    /// downgrade must not read a format it doesn't understand. An empty cache is
    /// likewise treated as absent — persisting a zero-template catalog and then
    /// honouring it would present the offline state as a legitimately empty corpus.
    public static func decide(cached: Cached?, now: Date) -> Decision {
        guard let cached, cached.version <= currentVersion, !cached.templates.isEmpty else {
            return .fetchNow
        }
        // A timestamp in the future (clock skew, a restored backup) is treated as
        // stale rather than infinitely fresh, so a bad clock can't pin the catalog.
        let age = now.timeIntervalSince(cached.fetchedAt)
        return (age >= 0 && age < maxAge) ? .useCache : .useCacheAndRefresh
    }

    /// What the user should be told when a refresh fails.
    ///
    /// The distinction is the whole point of the cache. With templates already on
    /// screen a failed refresh is a NON-EVENT and must not raise an error — v2's
    /// habit of reporting every fetch failure is what made a cold start look broken.
    /// With nothing on screen the failure is the only thing the user needs to know,
    /// and it must come with the fact that retrying is possible.
    public static func refreshFailureMessage(hasCachedTemplates: Bool, reason: String) -> String? {
        guard !hasCachedTemplates else { return nil }
        return "Couldn't load meme templates — \(reason) "
            + "Check your connection and press Retry, or import your own template."
    }

    /// The status line for a successful catalog open.
    ///
    /// Names the per-source counts because the corpus size IS the feature the owner
    /// asked for, and because seeing "0 from your library" is the discoverability
    /// nudge toward importing one.
    public static func summary(_ templates: [MemeTemplate]) -> String {
        guard !templates.isEmpty else { return "No templates available." }
        var counts: [MemeTemplateSource: Int] = [:]
        for template in templates { counts[template.source, default: 0] += 1 }

        let parts = MemeTemplateSource.allCases.compactMap { source -> String? in
            guard let count = counts[source], count > 0 else { return nil }
            return "\(count) \(source.label)"
        }
        return "\(templates.count) templates (\(parts.joined(separator: ", ")))."
    }
}
