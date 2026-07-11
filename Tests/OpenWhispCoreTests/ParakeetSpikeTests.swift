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

    // MARK: - Variant-aware language gate

    func testLanguageGateAllowsAutoAndEnglishOnEnglishVariant() {
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "auto", multilingual: false))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "", multilingual: false))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "en", multilingual: false))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "en-US", multilingual: false))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "EN_GB", multilingual: false))
    }

    func testLanguageGateRefusesFixedNonEnglishOnEnglishVariant() {
        // A fixed non-English language must refuse up front on an English-only
        // variant — never silently transcribe Russian into English-ish garbage.
        XCTAssertNotNil(ParakeetLanguageGate.refusalMessage(languageSetting: "ru", multilingual: false))
        XCTAssertNotNil(ParakeetLanguageGate.refusalMessage(languageSetting: "de-DE", multilingual: false))
        XCTAssertNotNil(ParakeetLanguageGate.refusalMessage(languageSetting: "es", multilingual: false))
        // The message should point the user at the multilingual variant.
        let msg = ParakeetLanguageGate.refusalMessage(languageSetting: "ru", multilingual: false)
        XCTAssertTrue(msg?.contains("Multilingual") ?? false)
    }

    func testLanguageGateAcceptsEverythingOnMultilingualVariant() {
        // The multilingual variant maps known codes to prompt ids and falls back
        // to auto-detect for unknowns, so it is never refused.
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "auto", multilingual: true))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "ru", multilingual: true))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "de-DE", multilingual: true))
        XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: "xx-YY", multilingual: true))
    }

    // MARK: - File-engine routing (meetings / queue / watch folders / re-transcribe)

    func testFileEngineChoiceRoutesParakeetToBatchEngine() {
        // The wiring that decides what transcribes meetings and file jobs.
        XCTAssertEqual(FileEngineChoice.choice(for: "parakeet"), .parakeet)
        XCTAssertEqual(FileEngineChoice.choice(for: "whisperKit"), .whisperKit)
        XCTAssertEqual(FileEngineChoice.choice(for: "whisper"), .whisperCpp)
        // Apple Speech never reaches the file path (always streams); its
        // fallback value is inert but must not crash or pick a CoreML engine.
        XCTAssertEqual(FileEngineChoice.choice(for: "appleSpeech"), .whisperCpp)
        XCTAssertEqual(FileEngineChoice.choice(for: ""), .whisperCpp)
    }

    // MARK: - EOU capability flag (agent auto-stop arming + engine poll gate)

    func testOnlyTheEouVariantEmitsEou() {
        XCTAssertTrue(ParakeetCatalog.emitsEou("parakeet-eou-320ms"))
        XCTAssertFalse(ParakeetCatalog.emitsEou("parakeet-unified-320ms"))
        XCTAssertFalse(ParakeetCatalog.emitsEou("nemotron-multilingual-1120ms"))
        // Unknown ids normalize to the (non-EOU) default — never spuriously EOU.
        XCTAssertFalse(ParakeetCatalog.emitsEou("bogus"))
    }

    // MARK: - Gate ↔ hint normalization coherence

    func testGateAndHintAgreeOnWhatCountsAsEnglish() {
        // The gate refuses exactly the settings whose base code is a fixed
        // non-"en" language; both sides go through ParakeetLanguageHint.baseCode.
        for setting in ["auto", "", "en", "en-US", "EN_GB"] {
            XCTAssertNil(ParakeetLanguageGate.refusalMessage(languageSetting: setting, multilingual: false))
            if let base = ParakeetLanguageHint.baseCode(from: setting) {
                XCTAssertEqual(base, "en")
            }
        }
        for setting in ["ru", "de-DE", "es_MX"] {
            XCTAssertNotNil(ParakeetLanguageGate.refusalMessage(languageSetting: setting, multilingual: false))
            XCTAssertNotEqual(ParakeetLanguageHint.baseCode(from: setting), "en")
        }
    }

    // MARK: - Multilingual catalog

    func testCatalogHasAMultilingualVariant() {
        XCTAssertTrue(ParakeetCatalog.variants.contains { $0.multilingual })
        let ml = ParakeetCatalog.variants.first { $0.multilingual }
        XCTAssertNotNil(ml?.multilingualChunkMs, "multilingual variant must carry a chunk tier")
    }

    func testEnglishVariantsAreNotMultilingual() {
        XCTAssertFalse(ParakeetCatalog.isMultilingual("parakeet-unified-320ms"))
        XCTAssertFalse(ParakeetCatalog.isMultilingual("parakeet-eou-320ms"))
        XCTAssertTrue(ParakeetCatalog.isMultilingual("nemotron-multilingual-1120ms"))
        // Unknown id normalizes to the default (English) variant → not multilingual.
        XCTAssertFalse(ParakeetCatalog.isMultilingual("bogus"))
    }

    // MARK: - Language-hint mapping (batch + multilingual codes)

    func testBatchLanguageCodeStripsRegionAndAutos() {
        XCTAssertNil(ParakeetLanguageHint.batchLanguageCode(from: "auto"))
        XCTAssertNil(ParakeetLanguageHint.batchLanguageCode(from: ""))
        XCTAssertEqual(ParakeetLanguageHint.batchLanguageCode(from: "en"), "en")
        XCTAssertEqual(ParakeetLanguageHint.batchLanguageCode(from: "de-DE"), "de")
        XCTAssertEqual(ParakeetLanguageHint.batchLanguageCode(from: "en_US"), "en")
        XCTAssertEqual(ParakeetLanguageHint.batchLanguageCode(from: "RU"), "ru")
    }

    func testBatchLanguageCodeSuppressesTranslateSentinel() {
        // Parakeet is ASR-only; a stray translate sentinel must degrade to auto,
        // never a bogus 2-letter code.
        XCTAssertNil(ParakeetLanguageHint.batchLanguageCode(from: WhisperTask.translateToEnglishSetting))
    }

    func testMultilingualLanguageCodeKeepsRegionAndAutos() {
        XCTAssertEqual(ParakeetLanguageHint.multilingualLanguageCode(from: "auto"), "auto")
        XCTAssertEqual(ParakeetLanguageHint.multilingualLanguageCode(from: ""), "auto")
        XCTAssertEqual(ParakeetLanguageHint.multilingualLanguageCode(from: "de-DE"), "de-de")
        XCTAssertEqual(ParakeetLanguageHint.multilingualLanguageCode(from: "en_US"), "en-us")
        XCTAssertEqual(ParakeetLanguageHint.multilingualLanguageCode(from: "ru"), "ru")
        XCTAssertEqual(
            ParakeetLanguageHint.multilingualLanguageCode(from: WhisperTask.translateToEnglishSetting),
            "auto"
        )
    }

    // MARK: - Download-state policy (Models pane badge, Phase 4)

    func testDownloadStateInstalledWhenFolderPresent() {
        let s = ParakeetDownloadStatePolicy.state(
            forVariant: "parakeet-unified-320ms",
            installedFolders: ["parakeet-unified-en-0.6b"],
            inFlightVariants: []
        )
        XCTAssertEqual(s, .installed)
        XCTAssertNil(s.badge, "installed variants get no badge")
    }

    func testDownloadStateDownloadingWhenInFlightAndNoFolder() {
        let s = ParakeetDownloadStatePolicy.state(
            forVariant: "nemotron-multilingual-1120ms",
            installedFolders: [],
            inFlightVariants: ["nemotron-multilingual-1120ms"]
        )
        XCTAssertEqual(s, .downloading)
        XCTAssertEqual(s.badge, "Downloading…")
    }

    func testDownloadStateNotDownloadedWhenAbsentAndIdle() {
        let s = ParakeetDownloadStatePolicy.state(
            forVariant: "parakeet-eou-320ms", installedFolders: [], inFlightVariants: []
        )
        XCTAssertEqual(s, .notDownloaded)
        XCTAssertEqual(s.badge, "Not downloaded")
    }

    func testDownloadStateInstalledWinsOverInFlight() {
        // Folder present + a stale in-flight flag → installed (bytes are down).
        let s = ParakeetDownloadStatePolicy.state(
            forVariant: "parakeet-unified-1120ms",
            installedFolders: ["parakeet-unified-en-0.6b"],
            inFlightVariants: ["parakeet-unified-1120ms"]
        )
        XCTAssertEqual(s, .installed)
    }

    func testUnifiedTiersShareARepoFolder() {
        // The two Unified tiers stage into ONE repo — installing either shows both
        // as installed.
        XCTAssertEqual(
            ParakeetDownloadStatePolicy.repoFolder(forVariant: "parakeet-unified-320ms"),
            ParakeetDownloadStatePolicy.repoFolder(forVariant: "parakeet-unified-1120ms")
        )
    }

    func testParakeetRepoLabelsAreHumanReadable() {
        XCTAssertEqual(
            ModelStorage.parakeetRepoLabel(forFolder: "parakeet-tdt-0.6b-v3"),
            "Parakeet TDT v3 (batch, 25 languages)"
        )
        // Unknown folders fall back to the raw name (nothing hidden).
        XCTAssertEqual(ModelStorage.parakeetRepoLabel(forFolder: "future-repo"), "future-repo")
    }

    func testParakeetStorageSortsAfterWhisperKit() {
        let items = [
            ModelStorage.Item(kind: .parakeet, label: "P", path: "/p", bytes: 100, isActive: false),
            ModelStorage.Item(kind: .whisperKit, label: "W", path: "/w", bytes: 100, isActive: false),
            ModelStorage.Item(kind: .whisperCpp, label: "C", path: "/c", bytes: 100, isActive: false),
        ]
        let sorted = ModelStorage.sorted(items)
        XCTAssertEqual(sorted.map(\.kind), [.whisperKit, .parakeet, .whisperCpp])
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
