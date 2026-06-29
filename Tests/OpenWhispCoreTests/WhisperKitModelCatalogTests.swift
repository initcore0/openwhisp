import XCTest
@testable import OpenWhispCore

/// Pure logic of the WhisperKit model catalog: staged-detection (with injected fs)
/// and display labels/ordering. The on-disk listing isn't tested here (it touches
/// the real filesystem); the predicate it relies on is.
final class WhisperKitModelCatalogTests: XCTestCase {
    func testIsStagedRequiresAllThreeSubmodels() {
        let model = "openai_whisper-small"
        let folder = WhisperKitModelCatalog.baseDir.appendingPathComponent(model).path

        // All three present → staged.
        let complete: (String) -> Bool = { $0.hasPrefix(folder) }
        XCTAssertTrue(WhisperKitModelCatalog.isStaged(model, fileExists: complete))

        // Missing the AudioEncoder → not staged.
        let missingEncoder: (String) -> Bool = { path in
            path.hasPrefix(folder) && !path.hasSuffix("AudioEncoder.mlmodelc")
        }
        XCTAssertFalse(WhisperKitModelCatalog.isStaged(model, fileExists: missingEncoder))

        // Nothing present → not staged.
        XCTAssertFalse(WhisperKitModelCatalog.isStaged(model, fileExists: { _ in false }))
    }

    func testDisplayInfoKnownModels() {
        XCTAssertTrue(WhisperKitModelCatalog.displayInfo(for: "openai_whisper-small").label.contains("Small"))
        XCTAssertTrue(WhisperKitModelCatalog.displayInfo(for: "openai_whisper-tiny.en").label.contains("English"))
        XCTAssertTrue(WhisperKitModelCatalog.displayInfo(for: "openai_whisper-large-v3-turbo").label.contains("Turbo"))
    }

    func testDisplayInfoUnknownModelPrettifies() {
        let info = WhisperKitModelCatalog.displayInfo(for: "openai_whisper-medium")
        XCTAssertEqual(info.label, "medium")
        XCTAssertNil(info.hint)
    }

    func testDownloadableModelsAreTheCuratedSet() {
        let d = WhisperKitModelCatalog.downloadableModels
        XCTAssertTrue(d.contains("openai_whisper-small"))
        XCTAssertTrue(d.contains("openai_whisper-tiny.en"))
        XCTAssertTrue(d.contains("openai_whisper-large-v3-turbo"))
        // Small ranks before tiny ranks before turbo (preferred display order).
        XCTAssertEqual(d.first, "openai_whisper-small")
    }

    /// selectableModels merges curated downloadables with whatever is staged on disk.
    /// In a clean test environment nothing is staged, so it equals the curated set in
    /// preferred order — and it must never contain duplicates regardless.
    func testSelectableModelsContainsDownloadablesNoDuplicates() {
        let s = WhisperKitModelCatalog.selectableModels()
        for model in WhisperKitModelCatalog.downloadableModels {
            XCTAssertTrue(s.contains(model), "missing \(model)")
        }
        XCTAssertEqual(s.count, Set(s).count, "selectableModels must not contain duplicates")
        // Ordered: small (rank 0) precedes tiny (1) precedes turbo (2).
        if let si = s.firstIndex(of: "openai_whisper-small"),
           let ti = s.firstIndex(of: "openai_whisper-tiny.en"),
           let ui = s.firstIndex(of: "openai_whisper-large-v3-turbo") {
            XCTAssertLessThan(si, ti)
            XCTAssertLessThan(ti, ui)
        } else {
            XCTFail("expected all three curated models present")
        }
    }
}
