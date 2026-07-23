import XCTest
@testable import OpenWhispCore

/// Tests for the model path/name helpers extracted from AppState under the
/// MAK-32 LOC ratchet (previously untestable inline statics).
final class WhisperModelPathsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelPathsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    // MARK: - Names

    func testModelFileNameMapsKnownModelsAndFallsBackToBase() {
        XCTAssertEqual(WhisperModelPaths.modelFileName(for: "tiny.en"), "ggml-tiny.en.bin")
        XCTAssertEqual(WhisperModelPaths.modelFileName(for: "large-v3-turbo"), "ggml-large-v3-turbo.bin")
        // Unknown ids fall back to base rather than producing a bogus path.
        XCTAssertEqual(WhisperModelPaths.modelFileName(for: "no-such-model"), "ggml-base.bin")
    }

    // MARK: - Path fallbacks

    func testPreferredModelPathHonorsExistingSavedPath() throws {
        let saved = dir.appendingPathComponent("my-model.bin")
        try Data("x".utf8).write(to: saved)
        XCTAssertEqual(
            WhisperModelPaths.preferredModelPath(savedPath: saved.path, fileName: "ggml-base.bin"),
            saved.path
        )
    }

    func testPreferredModelPathFallsBackToModelsDirectoryWhenSavedPathGone() {
        let gone = dir.appendingPathComponent("deleted.bin").path
        let resolved = WhisperModelPaths.preferredModelPath(savedPath: gone, fileName: "ggml-base.bin")
        XCTAssertNotEqual(resolved, gone, "a vanished saved path must not win")
        XCTAssertTrue(resolved.hasSuffix("ggml-base.bin"))
    }

    func testPreferredWhisperCLIPathHonorsExistingSavedPath() throws {
        let saved = dir.appendingPathComponent("whisper-cli")
        try Data("#!".utf8).write(to: saved)
        XCTAssertEqual(WhisperModelPaths.preferredWhisperCLIPath(savedPath: saved.path), saved.path)
    }

    // MARK: - Download validation

    func testValidateModelMagicAcceptsExpectedMagic() throws {
        let url = dir.appendingPathComponent("model.gguf")
        try Data("GGUF-rest-of-model".utf8).write(to: url)
        XCTAssertNoThrow(try WhisperModelPaths.validateModelMagic(at: url, expected: ["GGUF"], fileName: "model.gguf"))
    }

    func testValidateModelMagicRejectsErrorPageServedAs200() throws {
        // The exact captive-portal/error-page case the check exists for.
        let url = dir.appendingPathComponent("model.bin")
        try Data("<html><body>Rate limited</body></html>".utf8).write(to: url)
        XCTAssertThrowsError(
            try WhisperModelPaths.validateModelMagic(at: url, expected: ["lmgg", "GGUF"], fileName: "model.bin")
        ) { error in
            XCTAssertTrue(error is ModelDownloadError)
        }
    }
}
