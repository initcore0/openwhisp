import XCTest
@testable import OpenWhispCore

/// Unit tests for the pure whisper-server response classifier (MAK-23): a 200
/// with no speech must be a **clean empty** (not an error), while genuine
/// failures — non-200, malformed body — must still classify as errors. This is
/// what makes silence behave identically on the server path and the CLI path
/// (both "quietly nothing").
final class WhisperResponseClassifierTests: XCTestCase {

    private func body(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Real transcript → .transcript(trimmed)

    func testRealTranscriptReturnsText() {
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":"hello world"}"#)
        )
        XCTAssertEqual(outcome, .transcript("hello world"))
    }

    func testTranscriptIsTrimmed() {
        // whisper-server commonly returns a leading space; the classifier trims
        // it, matching the CLI path's trimming.
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":"  hello world \n"}"#)
        )
        XCTAssertEqual(outcome, .transcript("hello world"))
    }

    func testTranscriptWithOtherFieldsStillParses() {
        // Extra JSON keys must not break decoding (only `text` is read).
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":"transcribed speech","language":"en","duration":1.2}"#)
        )
        XCTAssertEqual(outcome, .transcript("transcribed speech"))
    }

    // MARK: - No speech (200) → .cleanEmpty (the MAK-23 fix)

    func testEmptyTextIsCleanEmpty() {
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":""}"#)
        )
        XCTAssertEqual(outcome, .cleanEmpty)
    }

    func testWhitespaceOnlyTextIsCleanEmpty() {
        // A body of only spaces/newlines/tabs is "no speech", not a transcript.
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":"   \n\t  "}"#)
        )
        XCTAssertEqual(outcome, .cleanEmpty)
    }

    func testSingleSpaceTextIsCleanEmpty() {
        // whisper-server often emits just " " for pure silence.
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":" "}"#)
        )
        XCTAssertEqual(outcome, .cleanEmpty)
    }

    func testNullTextIsCleanEmpty() {
        // JSON null (or a missing key) decodes to nil → treated as no speech,
        // NOT malformed, because the body is still valid `{ "text": ... }` JSON.
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":null}"#)
        )
        XCTAssertEqual(outcome, .cleanEmpty)
    }

    func testMissingTextKeyIsCleanEmpty() {
        // `text` is optional in the decodable shape, so `{}` parses with nil
        // text → clean empty, consistent with the null case.
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body("{}")
        )
        XCTAssertEqual(outcome, .cleanEmpty)
    }

    // MARK: - Genuine failures → .error (must NOT be swallowed as empty)

    func testNon200IsError() {
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 500,
            body: body("internal server error")
        )
        XCTAssertEqual(outcome, .error(message: "internal server error"))
    }

    func testNon200WithEmptyBodyReportsStatusCode() {
        // A non-200 with a blank body is STILL an error — never mistaken for the
        // clean-empty "no speech" case (which requires a 200).
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 404,
            body: Data()
        )
        XCTAssertEqual(outcome, .error(message: "HTTP 404"))
    }

    func testNon200With200LikeBodyStillErrors() {
        // Even if a non-200 response carries an empty-transcript JSON body, the
        // non-200 status makes it a failure, not a clean empty.
        let outcome = WhisperResponseClassifier.classify(
            statusCode: 503,
            body: body(#"{"text":""}"#)
        )
        XCTAssertEqual(outcome, .error(message: #"{"text":""}"#))
    }

    func testMalformed200BodyIsError() {
        // A 200 whose body is not the expected JSON shape is a genuine failure
        // (unexpected payload), NOT silence.
        if case .error = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body("this is not json")
        ) {
            // expected
        } else {
            XCTFail("Malformed 200 body should classify as .error")
        }
    }

    func testEmpty200BodyIsError() {
        // A 200 with a 0-byte body has nothing to decode → malformed → error.
        // This is distinct from a 200 whose JSON `text` is empty (clean empty).
        if case .error = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: Data()
        ) {
            // expected
        } else {
            XCTFail("Empty 200 body should classify as .error, not .cleanEmpty")
        }
    }

    func testWrongJSONTypeForTextIsError() {
        // `text` present but the wrong type (number, not string/null) fails to
        // decode → treated as a malformed payload, not clean empty.
        if case .error = WhisperResponseClassifier.classify(
            statusCode: 200,
            body: body(#"{"text":42}"#)
        ) {
            // expected
        } else {
            XCTFail("Wrong-typed text field should classify as .error")
        }
    }
}
