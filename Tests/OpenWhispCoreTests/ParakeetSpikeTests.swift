import XCTest
@testable import OpenWhispCore

/// MAK-46 spike: the pure-core pieces of the Parakeet streaming engine — the
/// variant catalog, the streaming-session routing gate, the English-only
/// language gate, and Parakeet's translate suppression in LanguageResolver.
/// The FluidAudio-backed engine itself is app-only (`#if PARAKEET`) and is
/// exercised by the harness + manual runs (see docs/PARAKEET_SPIKE.md).
final class ParakeetSpikeTests: XCTestCase {

    // MARK: - Catalog

    func testCatalogDefaultIsAKnownVariant() {
        XCTAssertTrue(ParakeetCatalog.variants.contains { $0.id == ParakeetCatalog.defaultVariantID })
    }

    func testNormalizeKeepsKnownIDs() {
        for variant in ParakeetCatalog.variants {
            XCTAssertEqual(ParakeetCatalog.normalize(variant.id), variant.id)
        }
    }

    func testNormalizeSnapsUnknownIDToDefault() {
        // A stale stored id (e.g. a variant dropped after a FluidAudio bump)
        // must fall back to the default, not error a session.
        XCTAssertEqual(ParakeetCatalog.normalize("parakeet-eou-9000ms"), ParakeetCatalog.defaultVariantID)
        XCTAssertEqual(ParakeetCatalog.normalize(""), ParakeetCatalog.defaultVariantID)
    }

    func testVariantLookupNeverFails() {
        XCTAssertEqual(ParakeetCatalog.variant(for: "bogus").id, ParakeetCatalog.defaultVariantID)
        XCTAssertEqual(ParakeetCatalog.variant(for: "parakeet-eou-320ms").id, "parakeet-eou-320ms")
    }

    // MARK: - Streaming-session routing (the startDictation gate)

    func testParakeetAlwaysRoutesToStreamingSession() {
        // Parakeet has no file path at all — every output mode streams.
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: "parakeet", liveMode: true))
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: "parakeet", liveMode: false))
    }

    func testAppleSpeechAlwaysRoutesToStreamingSession() {
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: "appleSpeech", liveMode: true))
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: "appleSpeech", liveMode: false))
    }

    func testWhisperKitStreamsOnlyInLiveMode() {
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: "whisperKit", liveMode: true))
        XCTAssertFalse(StreamingRoutePolicy.usesStreamingSession(engine: "whisperKit", liveMode: false))
    }

    func testWhisperCppNeverRoutesToStreamingSession() {
        XCTAssertFalse(StreamingRoutePolicy.usesStreamingSession(engine: "whisper", liveMode: true))
        XCTAssertFalse(StreamingRoutePolicy.usesStreamingSession(engine: "whisper", liveMode: false))
    }

    func testOnlyAppleSpeechNeedsSpeechAuthorization() {
        XCTAssertTrue(StreamingRoutePolicy.needsSpeechAuthorization(engine: "appleSpeech"))
        XCTAssertFalse(StreamingRoutePolicy.needsSpeechAuthorization(engine: "parakeet"))
        XCTAssertFalse(StreamingRoutePolicy.needsSpeechAuthorization(engine: "whisperKit"))
    }

    // MARK: - English-only language gate

    func testLanguageGateAllowsAutoAndEnglish() {
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "auto"))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: ""))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "en"))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "en-US"))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "EN_GB"))
    }

    func testLanguageGateRefusesFixedNonEnglish() {
        // A fixed non-English language must refuse up front — never silently
        // transcribe Russian speech into English-ish garbage (the same
        // principle as the RefineOutputGuard language guard).
        XCTAssertNotNil(ParakeetLanguageGate.refusalMessage(languageSetting: "ru"))
        XCTAssertNotNil(ParakeetLanguageGate.refusalMessage(languageSetting: "de-DE"))
        XCTAssertNotNil(ParakeetLanguageGate.refusalMessage(languageSetting: "es"))
    }

    // MARK: - Translate suppression (LanguageResolver)

    func testParakeetSuppressesTranslateToEnglish() {
        // Parakeet is ASR-only: translateToEnglish must NOT map to the whisper
        // translate sentinel (which the language gate would then refuse) — the
        // plain language passes through, exactly like Apple Speech.
        XCTAssertEqual(
            LanguageResolver.engineLanguageSetting(
                language: "auto", translateToEnglish: true, transcriptionEngine: "parakeet"
            ),
            "auto"
        )
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "ru", translateToEnglish: true, transcriptionEngine: "parakeet"
            ),
            "ru"
        )
        XCTAssertFalse(LanguageResolver.supportsTranslation(transcriptionEngine: "parakeet"))
        XCTAssertFalse(LanguageResolver.supportsTranslation(transcriptionEngine: "appleSpeech"))
        XCTAssertTrue(LanguageResolver.supportsTranslation(transcriptionEngine: "whisperKit"))
        XCTAssertTrue(LanguageResolver.supportsTranslation(transcriptionEngine: "whisper"))
    }
}
