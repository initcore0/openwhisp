import XCTest
@testable import OpenWhispCore

/// The minimal per-purpose router (MAK-69). Translation is the only purpose that
/// still needs routing once vocabulary/language are handled by offered-iff-honored
/// gating, so these tests pin exactly that case and its honest disclosure.
final class EnginePurposeRouterTests: XCTestCase {

    func testTranslateOnCapableEngineStaysPut() {
        for engine in [EngineCapabilities.whisperKit, EngineCapabilities.whisperCpp] {
            XCTAssertEqual(
                EnginePurposeRouter.routeTranslation(currentEngine: engine),
                .useCurrent,
                "\(engine) translates — a translate request must not reroute")
        }
    }

    func testTranslateOnAsrOnlyEngineReroutesWithDisclosure() {
        for engine in [EngineCapabilities.parakeet,
                       EngineCapabilities.appleSpeech,
                       EngineCapabilities.speechAnalyzer] {
            let routing = EnginePurposeRouter.routeTranslation(currentEngine: engine)
            guard case let .reroute(target, disclosure) = routing else {
                return XCTFail("\(engine) can't translate — expected a reroute, got \(routing)")
            }
            // Routes to a translation-capable engine…
            XCTAssertTrue(
                EngineCapabilities.capabilities(for: target).translation,
                "\(engine) rerouted to \(target), which itself can't translate")
            // …and never silently: the disclosure names both engines.
            XCTAssertFalse(disclosure.isEmpty)
            XCTAssertTrue(
                disclosure.contains(EngineCapabilities.displayName(transcriptionEngine: engine)),
                "disclosure must name the engine the user is on")
        }
    }

    func testDefaultTargetPrefersWhisperKit() {
        let routing = EnginePurposeRouter.routeTranslation(currentEngine: EngineCapabilities.parakeet)
        XCTAssertEqual(routing, .reroute(
            to: EngineCapabilities.whisperKit,
            disclosure: "Parakeet can't translate speech to English, so this request uses WhisperKit."))
    }

    func testNoCapableEngineAvailableIsUnavailableNotSilent() {
        // Only ASR-only engines available → can't honor translate; must refuse
        // (the LanguageResolver suppression path), not pretend it worked.
        let routing = EnginePurposeRouter.routeTranslation(
            currentEngine: EngineCapabilities.parakeet,
            availableEngines: [EngineCapabilities.parakeet, EngineCapabilities.appleSpeech])
        guard case let .unavailable(reason) = routing else {
            return XCTFail("no translation-capable engine available — expected .unavailable, got \(routing)")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}
