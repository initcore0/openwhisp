import Foundation

/// App-side webhook output target (MAK-14): POST a finished dictation to a
/// user-configured URL.
///
/// Deliberately THIN — all the deterministic logic (JSON body, `URLRequest`,
/// status → outcome classification) lives in the pure, unit-tested
/// `WebhookRequest` / `WebhookBody` in `OpenWhispCore`. This file only does the
/// one thing that isn't unit-testable without a network: fire the request through
/// `URLSession` off the main thread and map the response/error back through the
/// pure classifier.
///
/// **Fail-open by contract.** Anything that isn't a clean 2xx — an invalid URL,
/// a transport error, a timeout, a non-HTTP response, or a non-2xx status — is
/// reported as `.failedFallback(reason:)`, so `OutputRouter` re-routes the SAME
/// payload to the focused-app insert and the text is never dropped.
///
/// Lives OUTSIDE `OpenWhispCore` (not listed in Package.swift) so `swift test`
/// never compiles a real network call; it's built into the app by build.sh.
final class WebhookOutputTarget: OutputTarget {
    let kind: OutputTargetKind = .webhook

    private let config: WebhookConfig
    private let session: URLSession
    /// Supplies the ISO-8601 timestamp stamped into the body. Injected so the app
    /// stamps real time while the pure builder stays deterministic; tests could
    /// substitute a fixed clock, but the real network send itself is not exercised
    /// in the unit suite.
    private let now: () -> Date
    /// Where the completion is delivered. Defaults to main (mirrors `TextOutput`),
    /// so the router's fail-open re-route runs on the expected thread.
    private let completionQueue: DispatchQueue

    init(
        config: WebhookConfig,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        completionQueue: DispatchQueue = .main
    ) {
        self.config = config
        self.session = session
        self.now = now
        self.completionQueue = completionQueue
    }

    func deliver(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void) {
        let finish: (OutputDelivery) -> Void = { [completionQueue] outcome in
            completionQueue.async { completion(outcome) }
        }

        let timestamp = ISO8601DateFormatter().string(from: now())
        let request: URLRequest
        do {
            request = try WebhookRequest.build(payload: payload, config: config, timestamp: timestamp)
        } catch let error as WebhookRequest.BuildError {
            // No request could be built (e.g. empty/invalid URL) → fall back.
            finish(.failedFallback(reason: error.reason))
            return
        } catch {
            finish(.failedFallback(reason: "webhook request build failed: \(error.localizedDescription)"))
            return
        }

        session.dataTask(with: request) { _, response, error in
            if let error {
                finish(.failedFallback(reason: "webhook request failed: \(error.localizedDescription)"))
                return
            }
            // Map through the pure classifier: a missing HTTP response is treated as
            // status 0 (→ fallback), and the 2xx/non-2xx decision is shared with the
            // unit-tested core so app + tests can't drift.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(WebhookRequest.classify(statusCode: status))
        }.resume()
    }
}
