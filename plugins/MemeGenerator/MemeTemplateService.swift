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

    /// A short timeout: this sits in front of a user waiting on a meme, so failing
    /// fast and saying so beats a long hang.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

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
        let (data, response) = try await session.data(from: imgflipCatalogURL)
        try check(response, host: "imgflip.com")

        let decoded = try JSONDecoder().decode(MemeTemplateCatalogResponse.self, from: data)
        let templates = decoded.templates
        guard !templates.isEmpty else { throw ServiceError.emptyCatalog }
        return templates
    }

    static func fetchMemegen() async throws -> [MemeTemplate] {
        let (data, response) = try await session.data(from: memegenCatalogURL)
        try check(response, host: "memegen.link")

        let decoded = try JSONDecoder().decode(MemegenTemplateResponse.self, from: data)
        guard !decoded.templates.isEmpty else { throw ServiceError.emptyCatalog }
        return decoded.templates
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
        // has already recovered.
        var request = URLRequest(url: url)
        request.timeoutInterval = imageTimeout

        let (data, response) = try await session.data(for: request)
        try check(response, host: url.host ?? "the template host")

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
