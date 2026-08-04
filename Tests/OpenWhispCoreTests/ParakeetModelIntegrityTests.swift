import XCTest
@testable import OpenWhispCore

/// Completeness verification for the Parakeet model cache (the fresh-install
/// onboarding fix): a torn first-run download leaves a repo folder FluidAudio's
/// presence gate accepts but `MLModel.load` can't open, and the app must never
/// call that state "installed". These pin the manifests, the generic bundle
/// rule, and the verdict→badge mapping.
final class ParakeetModelIntegrityTests: XCTestCase {

    /// A fully-staged Unified repo for the given encoder context suffix, plus
    /// the tier-independent shared files.
    private func unifiedListing(suffixes: [String]) -> Set<String> {
        var listing: Set<String> = [
            "parakeet_unified_decoder.mlmodelc/coremldata.bin",
            "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin",
            "vocab.json",
            "metadata.json",
        ]
        for suffix in suffixes {
            listing.insert("parakeet_unified_encoder_streaming_\(suffix)_int8.mlmodelc/coremldata.bin")
        }
        return listing
    }

    // MARK: - Manifest tier (Unified English — the default engine's variants)

    func testCompleteUnifiedRepoIsComplete() {
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(
                forVariant: "parakeet-unified-320ms",
                listing: unifiedListing(suffixes: ["70_2_2"])),
            .complete
        )
    }

    func testMissingFolderIsNotDownloaded() {
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(forVariant: "parakeet-unified-320ms", listing: nil),
            .notDownloaded
        )
    }

    func testTornEncoderBundleIsIncomplete() {
        // THE bug from the field: the encoder .mlmodelc directory exists (so
        // FluidAudio skips the download forever) but its coremldata.bin never
        // landed. The verdict must name the missing sentinel, not say installed.
        var listing = unifiedListing(suffixes: ["70_2_2"])
        listing.remove("parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/coremldata.bin")
        // The directory itself still shows up in a recursive walk via its other
        // partial contents.
        listing.insert("parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/model.mil")
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(forVariant: "parakeet-unified-320ms", listing: listing),
            .incomplete(missing: ["parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/coremldata.bin"])
        )
    }

    func testOtherTiersEncoderDoesNotSatisfyThisTier() {
        // Each latency tier bakes its attention context into a distinct encoder
        // bundle. A repo staged for the 640ms tier is NOT installed for 320ms —
        // FluidAudio still has this tier's encoder download ahead of it.
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(
                forVariant: "parakeet-unified-320ms",
                listing: unifiedListing(suffixes: ["70_7_1"])),
            .incomplete(missing: ["parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/coremldata.bin"])
        )
    }

    func testEachUnifiedTierMapsToItsOwnEncoderSuffix() {
        // Suffixes mirror FluidAudio's UnifiedConfig [left, chunk, right] per
        // tier (320ms → 70_2_2, 640ms → 70_7_1, 1120ms → 70_7_7).
        for (variant, suffix) in [
            ("parakeet-unified-320ms", "70_2_2"),
            ("parakeet-unified-640ms", "70_7_1"),
            ("parakeet-unified-1120ms", "70_7_7"),
        ] {
            XCTAssertEqual(
                ParakeetModelIntegrity.verdict(
                    forVariant: variant, listing: unifiedListing(suffixes: [suffix])),
                .complete, "variant \(variant) should be satisfied by suffix \(suffix)"
            )
        }
    }

    func testEouManifestIsNestedUnderTheChunkTierFolder() {
        let listing: Set<String> = [
            "320ms/streaming_encoder.mlmodelc/coremldata.bin",
            "320ms/decoder.mlmodelc/coremldata.bin",
            "320ms/joint_decision.mlmodelc/coremldata.bin",
            "320ms/vocab.json",
        ]
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(forVariant: "parakeet-eou-320ms", listing: listing),
            .complete
        )
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(forVariant: "parakeet-eou-320ms", listing: ["320ms/vocab.json"]),
            .incomplete(missing: [
                "320ms/decoder.mlmodelc/coremldata.bin",
                "320ms/joint_decision.mlmodelc/coremldata.bin",
                "320ms/streaming_encoder.mlmodelc/coremldata.bin",
            ])
        )
    }

    func testUnknownVariantNormalizesToTheDefaultManifest() {
        // A stale stored id snaps to the default variant (catalog behavior) —
        // its verdict must follow the default's manifest, not the generic rule.
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(
                forVariant: "made-up-variant",
                listing: unifiedListing(suffixes: ["70_2_2"])),
            .complete
        )
    }

    // MARK: - Generic tier (multilingual — language-dependent layout)

    func testMultilingualCompleteBundlesAreComplete() {
        let listing: Set<String> = [
            "multilingual/1120ms/encoder.mlmodelc/coremldata.bin",
            "multilingual/1120ms/decoder.mlmodelc/coremldata.bin",
            "multilingual/1120ms/joint.mlmodelc/coremldata.bin",
            "multilingual/1120ms/tokenizer.json",
        ]
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(forVariant: "nemotron-multilingual-1120ms", listing: listing),
            .complete
        )
    }

    func testMultilingualTornBundleIsIncomplete() {
        let listing: Set<String> = [
            "multilingual/1120ms/encoder.mlmodelc/model.mil",  // no coremldata.bin
            "multilingual/1120ms/decoder.mlmodelc/coremldata.bin",
        ]
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(forVariant: "nemotron-multilingual-1120ms", listing: listing),
            .incomplete(missing: ["multilingual/1120ms/encoder.mlmodelc/coremldata.bin"])
        )
    }

    func testMultilingualEmptyFolderIsIncomplete() {
        // The folder exists (listing non-nil) but holds no model bundle at all —
        // e.g. a download that died during the file listing phase.
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(
                forVariant: "nemotron-multilingual-1120ms", listing: ["metadata.json"]),
            .incomplete(missing: ["<any model bundle>"])
        )
    }

    func testMultilingualUncompiledPackageLayoutIsAccepted() {
        // FluidAudio accepts the uncompiled .mlpackage layout; it has no single
        // sentinel file, so its presence alone satisfies the generic rule.
        let listing: Set<String> = [
            "multilingual/1120ms/encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "multilingual/1120ms/tokenizer.json",
        ]
        XCTAssertEqual(
            ParakeetModelIntegrity.verdict(forVariant: "nemotron-multilingual-1120ms", listing: listing),
            .complete
        )
    }

    // MARK: - Verdict → badge mapping (the picker rows)

    func testVerdictStateMapping() {
        XCTAssertEqual(
            ParakeetDownloadStatePolicy.state(
                forVariant: "parakeet-unified-320ms", verdict: .complete, inFlightVariants: []),
            .installed
        )
        // Present-but-torn + repair in flight → downloading (the badge the old
        // folder-presence check couldn't show: it said installed).
        XCTAssertEqual(
            ParakeetDownloadStatePolicy.state(
                forVariant: "parakeet-unified-320ms",
                verdict: .incomplete(missing: ["x"]),
                inFlightVariants: ["parakeet-unified-320ms"]),
            .downloading
        )
        XCTAssertEqual(
            ParakeetDownloadStatePolicy.state(
                forVariant: "parakeet-unified-320ms",
                verdict: .incomplete(missing: ["x"]),
                inFlightVariants: []),
            .notDownloaded
        )
        XCTAssertEqual(
            ParakeetDownloadStatePolicy.state(
                forVariant: "parakeet-unified-320ms", verdict: .notDownloaded, inFlightVariants: []),
            .notDownloaded
        )
    }

    // MARK: - Failure copy

    func testFailureCopyNeverLeaksAFileURL() {
        // The menu bar previously rendered CoreML's raw "Unable to load model:
        // file:///Users/…" — the shared copy must stay path-free.
        XCTAssertFalse(ParakeetFailureCopy.downloadFailed.contains("file://"))
        XCTAssertFalse(ParakeetFailureCopy.loadFailed.contains("file://"))
    }
}
