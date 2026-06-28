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
}
