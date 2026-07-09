import Foundation

/// Pure, testable core for the webhook output target (MAK-14).
///
/// The webhook target POSTs a finished dictation to a user-configured URL — for
/// Notion / an Obsidian webhook / Zapier / n8n / a self-hosted endpoint. This file
/// holds ONLY the deterministic, network-free half: build the JSON body, build the
/// `URLRequest`, and classify an HTTP status into the fail-open `OutputDelivery`
/// contract. The actual `URLSession` call lives in `WebhookOutputTarget` (app-side,
/// built by build.sh) so nothing here ever touches the network — every function
/// below is a pure input→output mapping and is unit-tested as such.
///
/// Foundation-only, so it lives in `OpenWhispCore` and is `swift test`-able.

// MARK: - Configuration

/// User-configured webhook destination: the URL to POST to, any custom headers
/// (e.g. an `Authorization` token), and a request timeout.
///
/// `Codable` so a future Settings surface can persist it. The token itself is
/// expected to live in the Keychain in the shipping app; this struct just carries
/// the header values a request needs at send time. Deliberately standalone (not
/// folded into `AppProfile`'s stored schema), mirroring `OutputTargetSelection`.
struct WebhookConfig: Codable, Equatable {
    /// The endpoint to POST the transcript to. Stored as a string (not `URL`) so an
    /// empty/invalid value round-trips and is caught at request-build time rather
    /// than silently dropped on decode.
    var url: String
    /// Extra headers to apply verbatim to the request (e.g. `["Authorization":
    /// "Bearer …"]`). `Content-Type: application/json` is always set by the builder
    /// and need not be listed here.
    var headers: [String: String]
    /// Request timeout in seconds. Kept short — a slow endpoint should fail open to
    /// normal insertion quickly rather than stalling the dictation.
    var timeout: TimeInterval

    /// A sensible default timeout for a fire-and-forget POST from a dictation flow.
    static let defaultTimeout: TimeInterval = 10

    init(url: String, headers: [String: String] = [:], timeout: TimeInterval = WebhookConfig.defaultTimeout) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
    }
}

// MARK: - JSON body

/// The exact JSON body the ticket names: `{ text, language, appBundleID, timestamp }`.
///
/// `Codable` with an explicit `CodingKeys` order so the encoded key order is
/// deterministic (via `.sortedKeys` at encode time) and the shape is a stable
/// contract for the endpoints consuming it. `appBundleID` is optional — omitted
/// from the JSON when the frontmost app was unknown at dictation start.
struct WebhookBody: Codable, Equatable {
    /// The dictated text.
    let text: String
    /// BCP-47-ish language code of the transcription (e.g. "en", "auto").
    let language: String
    /// Bundle ID of the app frontmost at dictation start, if known (else absent).
    let appBundleID: String?
    /// ISO-8601 timestamp of delivery, passed in by the caller (the app-side target
    /// stamps the real `Date()`) so this builder stays pure and deterministic.
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case text
        case language
        case appBundleID
        case timestamp
    }

    /// Build the body from a payload + a caller-supplied ISO-8601 timestamp. Pure:
    /// no `Date()` call here, so the same inputs always encode to the same bytes.
    init(payload: OutputPayload, timestamp: String) {
        self.text = payload.text
        self.language = payload.language
        self.appBundleID = payload.targetAppBundleID
        self.timestamp = timestamp
    }

    init(text: String, language: String, appBundleID: String?, timestamp: String) {
        self.text = text
        self.language = language
        self.appBundleID = appBundleID
        self.timestamp = timestamp
    }

    /// Encode to JSON with deterministic key order. A nil `appBundleID` is omitted
    /// from the object (Swift's synthesized encoder skips a nil optional), so an
    /// unknown-app dictation produces a clean three-key body.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Request builder

/// Pure builders + status classifier for the webhook POST. No I/O, no `URLSession`,
/// no `Date()` — everything here is a deterministic mapping over its inputs so the
/// whole surface is unit-testable without a network.
enum WebhookRequest {

    /// Why a request couldn't be built. Surfaced as the `.failedFallback` reason so
    /// a misconfigured webhook fails open to normal insertion instead of dropping text.
    enum BuildError: Error, Equatable {
        /// The configured URL was empty or not a valid absolute URL.
        case invalidURL(String)

        /// A short human-readable note for the fail-open reason / logging.
        var reason: String {
            switch self {
            case .invalidURL(let raw):
                let shown = raw.isEmpty ? "(empty)" : raw
                return "invalid webhook URL: \(shown)"
            }
        }
    }

    /// Build the POST `URLRequest` for `payload` against `config`, stamped with
    /// `timestamp` (ISO-8601, supplied by the caller so this stays pure).
    ///
    /// - Sets method `POST`, `Content-Type: application/json`, the JSON body, and
    ///   the config's timeout.
    /// - Applies every custom header verbatim. `Content-Type` is set first so a
    ///   custom header of the same name would win — but callers shouldn't rely on
    ///   overriding it; the body is always JSON.
    /// - Throws `BuildError.invalidURL` when `config.url` is empty or not a valid
    ///   absolute URL, so no request is built and the caller falls back.
    static func build(payload: OutputPayload, config: WebhookConfig, timestamp: String) throws -> URLRequest {
        let trimmed = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw BuildError.invalidURL(config.url)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try WebhookBody(payload: payload, timestamp: timestamp).encoded()
        return request
    }

    /// Classify an HTTP status code into the fail-open `OutputDelivery` contract:
    /// any 2xx → `.delivered`; anything else → `.failedFallback` with a reason so
    /// the router re-routes to normal insertion. A status of `0` (used by the
    /// app-side sender to mean "no HTTP response — network error/timeout") also
    /// maps to fallback.
    static func classify(statusCode: Int) -> OutputDelivery {
        if (200...299).contains(statusCode) {
            return .delivered
        }
        if statusCode <= 0 {
            return .failedFallback(reason: "webhook request failed (no HTTP response)")
        }
        return .failedFallback(reason: "webhook returned HTTP \(statusCode)")
    }
}
