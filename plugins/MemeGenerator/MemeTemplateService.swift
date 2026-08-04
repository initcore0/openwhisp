import AppKit
import Foundation

/// The Meme Generator's network access (spike v3).
///
/// Read-only GETs against two public, key-less catalogs plus their image CDNs:
///
/// * `https://api.imgflip.com/get_memes` — ~100 popular templates.
/// * `https://api.memegen.link/templates` — ~200 more, with keywords.
/// * the templates' own blank-image URLs.
///
/// **Nothing is ever uploaded.** The user's dictation, the LLM's captions, and the
/// finished meme all stay on the Mac — captioning is done locally by `MemeRenderer`
/// precisely so no text has to leave. Note memegen.link *offers* server-side
/// captioning via URL (`/images/<id>/<top>/<bottom>.jpg`) and this plugin deliberately
/// does NOT use it: that would put the user's words on someone else's server, which is
/// exactly what the local-first posture rules out.
///
/// The third provider, the user's own library, needs no network at all — it is read
/// from disk by `MemeLibraryStore`.
enum MemeTemplateService {

    /// Failures worth telling the user apart.
    enum ServiceError: LocalizedError {
        case badResponse(host: String, status: Int)
        case emptyCatalog
        case undecodableImage
        /// Every remote provider failed. Carries the first reason so the user gets a
        /// cause rather than a generic "couldn't load".
        case allProvidersFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let host, let status):
                return "\(host) replied with HTTP \(status)."
            case .emptyCatalog:
                return "the template service returned no templates."
            case .undecodableImage:
                return "the downloaded template wasn't a readable image."
            case .allProvidersFailed(let reason):
                return reason
            }
        }
    }

    static let imgflipCatalogURL = URL(string: "https://api.imgflip.com/get_memes")!
    static let memegenCatalogURL = URL(string: "https://api.memegen.link/templates")!

    // MARK: - Session

    /// The HTTP session, REPLACEABLE (v5).
    ///
    /// ## Why this stopped being a `static let`
    ///
    /// The owner's v5 report was "template downloads stop working after about a day
    /// of uptime, and Retry does nothing". A `URLSession` is a connection pool, and
    /// v4's was a process-lifetime `static let` that nothing could ever replace. A
    /// pooled connection can outlive its own validity — the Mac sleeps and wakes on a
    /// different network, a VPN comes up, a captive portal's lease expires, an
    /// interface changes — and once the pool is in that state EVERY request handed to
    /// the session fails identically, for as long as the app stays running. That is
    /// precisely the reported shape: fine all day, then permanently broken, with a
    /// relaunch as the only cure.
    ///
    /// It also explains the second half of the report. Retry re-ran the request
    /// through the SAME session, so it inherited exactly the pool that was broken —
    /// a no-op by construction, however many times the user pressed it.
    ///
    /// So the session is now rebuildable, and a transport-shaped failure throws it
    /// away (`invalidate`). The next request — including a Retry — builds a fresh one
    /// with a fresh pool. The decision of WHICH failures count is the pure,
    /// `swift test`-pinned `MemeGenerationState.isTransportFailure`; a 404 or an
    /// undecodable image says nothing about the transport and keeps the pool.
    private static var _session: URLSession?

    /// How many times the pool has been thrown away this launch.
    ///
    /// Not test-reachable (this file is behind `PLUGINS=1`, outside the `swift test`
    /// target), so it earns its place as a DIAGNOSTIC instead: if the owner reports
    /// downloads dying again, this number distinguishes "the pool was never recycled,
    /// so the recycle predicate is too narrow" from "it recycled repeatedly and still
    /// failed, so the problem is not the pool". Surfaced through `sessionDiagnostic`.
    private(set) static var sessionGeneration = 0

    /// A one-line description of the transport's history, for the status line when a
    /// download fails after the session has already been recycled at least once.
    static var sessionDiagnostic: String? {
        guard sessionGeneration > 0 else { return nil }
        return sessionGeneration == 1
            ? "(the connection was reset once)"
            : "(the connection was reset \(sessionGeneration) times)"
    }

    static var session: URLSession {
        if let existing = _session { return existing }
        let created = makeSession()
        _session = created
        return created
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // A short timeout: this sits in front of a user waiting on a meme, so failing
        // fast and saying so beats a long hang.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // Never hand back a response cached before the network went bad — the whole
        // point of rebuilding is to re-ask reality.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Fail rather than park a request until connectivity returns: this sits in
        // front of a waiting user, and a visible error with a Retry beats a spinner.
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Throw the current session away so the next request builds a fresh one.
    ///
    /// `invalidateAndCancel` rather than a bare drop: it tears down the pooled
    /// connections instead of leaving them alive until ARC gets around to the
    /// session, which matters because those connections are the thing being
    /// discarded.
    static func invalidateSession() {
        guard let existing = _session else { return }
        _session = nil
        sessionGeneration += 1
        existing.invalidateAndCancel()
    }

    /// Drop the session if `error` says the transport itself is suspect.
    ///
    /// One funnel, called from every fetch path, so no request can fail on a wedged
    /// pool without the pool being reconsidered.
    static func recycleSessionIfNeeded(after error: Error) {
        guard MemeGenerationState.isTransportFailure(error) else { return }
        invalidateSession()
    }

    // MARK: - Providers

    /// Fetch every remote catalog, then merge with the user's library.
    ///
    /// The providers run CONCURRENTLY and are tolerant of partial failure: if
    /// memegen is down, imgflip's hundred still arrive and the user still gets a
    /// working plugin. Only when EVERY remote provider fails does this throw — and
    /// even then the caller can fall back to the disk cache or the user's library,
    /// which is what makes the plugin work offline.
    ///
    /// Merge order encodes precedence (`MemeTemplateCatalog.merge`): the user's own
    /// templates win, then imgflip (popularity-ranked, and the corpus the prompt was
    /// tuned against), then memegen.
    static func fetchMergedCatalog(userTemplates: [MemeTemplate]) async throws -> [MemeTemplate] {
        async let imgflip = fetchImgflip()
        async let memegen = fetchMemegen()

        var groups: [[MemeTemplate]] = [userTemplates]
        var firstFailure: String?

        do { groups.append(try await imgflip) }
        catch { firstFailure = reason(error) }

        do { groups.append(try await memegen) }
        catch { firstFailure = firstFailure ?? reason(error) }

        let merged = MemeTemplateCatalog.merge(groups)

        // The user's own library alone is a legitimate corpus — an offline user with
        // imported templates is fully functional and must not see an error.
        if merged.isEmpty, let firstFailure {
            throw ServiceError.allProvidersFailed(reason: firstFailure)
        }
        guard !merged.isEmpty else { throw ServiceError.emptyCatalog }
        return merged
    }

    static func fetchImgflip() async throws -> [MemeTemplate] {
        let (data, response) = try await get(imgflipCatalogURL, host: "imgflip.com")
        _ = response

        let decoded = try JSONDecoder().decode(MemeTemplateCatalogResponse.self, from: data)
        let templates = decoded.templates
        guard !templates.isEmpty else { throw ServiceError.emptyCatalog }
        return templates
    }

    static func fetchMemegen() async throws -> [MemeTemplate] {
        let (data, response) = try await get(memegenCatalogURL, host: "memegen.link")
        _ = response

        let decoded = try JSONDecoder().decode(MemegenTemplateResponse.self, from: data)
        guard !decoded.templates.isEmpty else { throw ServiceError.emptyCatalog }
        return decoded.templates
    }

    /// One GET, through the current session, recycling it on a transport failure.
    ///
    /// Every network read in this file goes through here so the recycle rule cannot be
    /// forgotten on a path — which is how v4 ended up with a session nothing could
    /// replace. Each call builds its OWN `URLRequest` rather than reusing a stored one,
    /// so a Retry is a genuinely fresh request and not a replay of the wedged attempt.
    private static func get(
        _ url: URL, host: String, timeout: TimeInterval? = nil
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeout { request.timeoutInterval = timeout }

        do {
            let (data, response) = try await session.data(for: request)
            try check(response, host: host)
            return (data, response)
        } catch {
            recycleSessionIfNeeded(after: error)
            throw error
        }
    }

    // MARK: - Images

    /// Load a template's blank image — from disk for the user's library, over the
    /// network for the remote providers.
    ///
    /// One entry point for all three sources: the difference is a URL scheme, which
    /// is exactly the abstraction `MemeTemplate.url` was widened to carry. A
    /// user-library template therefore renders through the same path as an imgflip
    /// one, which is why importing your own template needs no changes anywhere in the
    /// render or export code.
    static func fetchImage(_ template: MemeTemplate) async throws -> NSImage {
        guard let url = URL(string: template.url) else {
            throw ServiceError.undecodableImage
        }

        if url.isFileURL {
            guard let image = NSImage(contentsOf: url) else {
                throw ServiceError.undecodableImage
            }
            return image
        }

        // A per-request ceiling on top of the session's, so one wedged image GET can't
        // outlive the UI's own download timeout and land a result into a surface that
        // has already recovered. A FRESH `URLRequest` every call (v5) — see `get` —
        // so pressing Retry re-asks rather than replaying the attempt that hung.
        let (data, _) = try await get(
            url, host: url.host ?? "the template host", timeout: imageTimeout)

        guard let image = NSImage(data: data) else { throw ServiceError.undecodableImage }
        return image
    }

    /// The ceiling on one template-image GET. Deliberately shorter than
    /// `MemeGenerationState.downloadTimeout` so the transport fails FIRST and the user
    /// gets a real reason ("the request timed out") rather than the UI's generic
    /// give-up message.
    static let imageTimeout: TimeInterval = 20

    private static func check(_ response: URLResponse, host: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.badResponse(host: host, status: http.statusCode)
        }
    }

    static func reason(_ error: Error) -> String {
        let described = (error as NSError).localizedDescription
        return described.isEmpty ? "the request failed." : described
    }
}
