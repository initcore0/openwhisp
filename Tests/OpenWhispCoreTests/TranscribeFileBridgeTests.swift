import XCTest
@testable import OpenWhispCore

/// MAK-83: the `transcribe.file` bridge verb. Covers (a) path validation
/// (rejections + the canonical happy path), and (b) a fixture-driven round trip
/// through the REAL router path — BridgeRouter decodes `transcribe.file`,
/// `TranscribeFileRequest` validates the path, and a real `FileTranscriptionEngine`
/// (the shared `ScriptedFileEngine` fixture double) transcribes an actual fixture
/// WAV — so a break anywhere in that chain fails here.
final class TranscribeFileBridgeTests: XCTestCase {

    // MARK: - Path validation (pure, no filesystem needed for rejections)

    /// A fake probe so the extension/absolute rules can be tested without touching
    /// disk; `exists`/`readable`/`size` are scripted per test.
    private struct FakeProbe: TranscribeFileRequest.FileProbing {
        var exists = true
        var readable = true
        var size: Int? = 1_000
        func regularFileExists(atPath path: String) -> Bool { exists }
        func isReadable(atPath path: String) -> Bool { readable }
        func fileSize(atPath path: String) -> Int? { size }
    }

    func testRejectsRelativePath() {
        let r = TranscribeFileRequest.validate(path: "clip.wav", language: nil, fileManager: FakeProbe())
        XCTAssertEqual(r, .failure(.notAbsolute))
    }

    func testRejectsEmptyPath() {
        XCTAssertEqual(TranscribeFileRequest.validate(path: "   ", language: nil, fileManager: FakeProbe()),
                       .failure(.notAbsolute))
    }

    func testRejectsUnsupportedExtension() {
        let r = TranscribeFileRequest.validate(path: "/tmp/secret.txt", language: nil, fileManager: FakeProbe())
        XCTAssertEqual(r, .failure(.unsupportedExtension("txt")))
    }

    func testRejectsMissingFile() {
        let r = TranscribeFileRequest.validate(
            path: "/tmp/missing.wav", language: nil, fileManager: FakeProbe(exists: false))
        XCTAssertEqual(r, .failure(.notFound))
    }

    func testRejectsUnreadableFile() {
        let r = TranscribeFileRequest.validate(
            path: "/tmp/locked.m4a", language: nil, fileManager: FakeProbe(readable: false))
        XCTAssertEqual(r, .failure(.notReadable))
    }

    func testRejectsOversizeFile() {
        let big = TranscribeFileRequest.maxFileSizeBytes + 1
        let r = TranscribeFileRequest.validate(
            path: "/tmp/huge.wav", language: nil, fileManager: FakeProbe(size: big))
        XCTAssertEqual(r, .failure(.tooLarge(bytes: big)))
    }

    func testTraversalIsCanonicalizedBeforeChecks() {
        // A path with `..` collapses; the extension check sees the real tail. Here
        // `/tmp/../etc/passwd` canonicalizes to `/etc/passwd` → no audio extension.
        let r = TranscribeFileRequest.validate(
            path: "/tmp/../etc/passwd", language: nil, fileManager: FakeProbe())
        XCTAssertEqual(r, .failure(.unsupportedExtension("")))
    }

    func testAcceptsSupportedExtensionsAndCanonicalizes() {
        for ext in ["wav", "mp3", "m4a", "mp4", "flac", "aiff"] {
            let r = TranscribeFileRequest.validate(
                path: "/tmp/sub/../clip.\(ext)", language: " en ", fileManager: FakeProbe())
            switch r {
            case .success(let v):
                XCTAssertEqual(v.canonicalPath, "/tmp/clip.\(ext)")  // `..` collapsed
                XCTAssertEqual(v.language, "en")                     // trimmed
            case .failure(let f):
                XCTFail("\(ext) should validate, got \(f)")
            }
        }
    }

    func testEmptyLanguageBecomesNil() {
        let r = TranscribeFileRequest.validate(path: "/tmp/clip.wav", language: "  ", fileManager: FakeProbe())
        guard case .success(let v) = r else { return XCTFail("expected success") }
        XCTAssertNil(v.language)
    }

    func testRejectionMapsToUnsupportedFormatWireError() {
        let err = TranscribeFileRequest.Rejection.unsupportedExtension("txt").errorObject
        XCTAssertEqual(err.data?.reason, .unsupportedFormat)
        XCTAssertEqual(err.code, BridgeWire.ErrorObject.serverError)

        let bad = TranscribeFileRequest.Rejection.notFound.errorObject
        XCTAssertEqual(bad.data?.reason, .malformedRequest)
        XCTAssertEqual(bad.code, BridgeWire.ErrorObject.invalidParams)
    }

    // MARK: - Real router path → validate → fixture engine round trip

    /// Drive an actual `transcribe.file` NDJSON line through BridgeRouter, validate
    /// the routed path, then transcribe the real fixture WAV with a
    /// `FileTranscriptionEngine` fixture double — the same engine seam
    /// `AgentFileTranscriber` uses. Asserts the transcript comes back out.
    func testRouterToFixtureEngineRoundTrip() throws {
        let fixture = FileAudioCaptureTests.fixture("plain_speech.wav")
        let jsonPath = fixture.path.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\"")
        let line = Data(#"{"id":7,"method":"transcribe.file","params":{"path":"\#(jsonPath)","language":"en"}}"#.utf8)

        // 1. Router decodes the verb into a typed intent.
        let routed = BridgeRouter.route(line: line, hasHandshaken: true)
        guard case let .intent(.transcribeFile(id, params)) = routed else {
            return XCTFail("expected transcribeFile intent, got \(routed)")
        }
        XCTAssertEqual(id, .number(7))

        // 2. Validation accepts the real fixture path.
        guard case let .success(validated) = TranscribeFileRequest.validate(
            path: params.path, language: params.language) else {
            return XCTFail("fixture path should validate")
        }
        XCTAssertEqual(validated.canonicalPath, fixture.resolvingSymlinksInPath().path)
        XCTAssertEqual(validated.language, "en")

        // 3. The engine seam returns the transcript (fixture double stands in for
        //    the user's configured engine; the WAV is real, already 16 kHz mono).
        let engine = ScriptedFileEngine(constant: "the quick brown fox")
        let done = expectation(description: "transcribed")
        var out = ""
        engine.onTranscriptionComplete = { _, text in out = text; done.fulfill() }
        engine.transcribe(
            requestID: UUID(), binaryPath: "", modelPath: "",
            language: validated.language ?? "", wavPath: validated.canonicalPath,
            deleteWhenDone: false, backend: .cli, prompt: "")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(out, "the quick brown fox")
    }
}
