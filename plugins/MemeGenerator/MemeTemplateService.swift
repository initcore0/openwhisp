import AppKit
import Foundation

/// The Meme Generator's only network access (spike).
///
/// Two GETs against imgflip's public, key-less endpoints:
///
/// * `https://api.imgflip.com/get_memes` — the template catalog (~100 popular
///   templates as JSON). No auth, no account, read-only.
/// * `https://i.imgflip.com/<id>.jpg` — the blank template image.
///
/// **Nothing is ever uploaded.** The user's dictation, the LLM's captions, and the
/// finished meme all stay on the Mac — captioning is done locally by `MemeRenderer`
/// precisely so no text has to leave. The app is local-first; this plugin's Settings
/// row states its network use, and the plugin is off by default.
enum MemeTemplateService {

    /// Failures worth telling the user apart.
    enum ServiceError: LocalizedError {
        case badResponse(status: Int)
        case emptyCatalog
        case undecodableImage

        var errorDescription: String? {
            switch self {
            case .badResponse(let status):
                return "imgflip.com replied with HTTP \(status)."
            case .emptyCatalog:
                return "imgflip.com returned no templates."
            case .undecodableImage:
                return "the downloaded template wasn't a readable image."
            }
        }
    }

    static let catalogURL = URL(string: "https://api.imgflip.com/get_memes")!

    /// A short timeout: this sits in front of a user waiting on a meme, so failing
    /// fast and saying so beats a long hang.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// Fetch the template catalog. Throws on transport failure, non-200, or an
    /// `{"success": false}` envelope — all of which surface to the user verbatim.
    static func fetchCatalog() async throws -> [MemeTemplate] {
        let (data, response) = try await session.data(from: catalogURL)
        try check(response)

        let decoded = try JSONDecoder().decode(MemeTemplateCatalogResponse.self, from: data)
        let templates = decoded.templates
        guard !templates.isEmpty else { throw ServiceError.emptyCatalog }
        return templates
    }

    /// Download a template's blank image.
    static func fetchImage(_ template: MemeTemplate) async throws -> NSImage {
        guard let url = URL(string: template.url) else {
            throw ServiceError.undecodableImage
        }
        let (data, response) = try await session.data(from: url)
        try check(response)

        guard let image = NSImage(data: data) else { throw ServiceError.undecodableImage }
        return image
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.badResponse(status: http.statusCode)
        }
    }
}
