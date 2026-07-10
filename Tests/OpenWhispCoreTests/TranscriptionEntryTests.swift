import XCTest
@testable import OpenWhispCore

/// Tests for the pure `TranscriptionEntry` decisions: revert target (MAK-35),
/// re-transcribe patching (MAK-40), and backward-compatible decoding of legacy
/// history.json files that predate the `rawText` / `audioFileName` fields.
final class TranscriptionEntryTests: XCTestCase {

    private func entry(text: String, raw: String? = nil, audio: String? = nil) -> TranscriptionEntry {
        TranscriptionEntry(text: text, date: Date(), appBundleID: nil, appName: nil,
                           rawText: raw, audioFileName: audio)
    }

    // MARK: - revertTarget (MAK-35)

    func testRevertTargetNilWhenNoRaw() {
        XCTAssertNil(entry(text: "hello").revertTarget)
    }

    func testRevertTargetNilWhenRawEqualsText() {
        XCTAssertNil(entry(text: "hello", raw: "hello").revertTarget)
    }

    func testRevertTargetWhenRawDiffers() {
        XCTAssertEqual(entry(text: "Hello.", raw: "hello").revertTarget, "hello")
    }

    // MARK: - reTranscribed (MAK-40)

    func testReTranscribeKeepsOldTextAsRevertBaseline() {
        let e = entry(text: "old words", audio: "retained-x.wav")
        let updated = e.reTranscribed(withNewText: "new words")
        XCTAssertEqual(updated.text, "new words")
        XCTAssertEqual(updated.revertTarget, "old words")   // can undo the re-transcribe
        XCTAssertEqual(updated.audioFileName, "retained-x.wav") // clip carried through
        XCTAssertEqual(updated.id, e.id)
    }

    func testReTranscribeNoChangePreservesPriorRaw() {
        let e = entry(text: "same", raw: "prior raw", audio: "retained-y.wav")
        let updated = e.reTranscribed(withNewText: "same")
        XCTAssertEqual(updated.text, "same")
        XCTAssertEqual(updated.rawText, "prior raw") // unchanged: nothing to newly revert
    }

    // MARK: - Codable back-compat

    func testDecodesLegacyEntryWithoutNewFields() throws {
        // A pre-MAK-35/40 entry: no rawText, no audioFileName.
        let json = Data(#"""
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","text":"legacy","date":0}
        """#.utf8)
        let e = try JSONDecoder().decode(TranscriptionEntry.self, from: json)
        XCTAssertEqual(e.text, "legacy")
        XCTAssertNil(e.rawText)
        XCTAssertNil(e.audioFileName)
    }

    func testAudioFileNameRoundTrips() throws {
        let e = entry(text: "hi", audio: "retained-\(UUID().uuidString).wav")
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(TranscriptionEntry.self, from: data)
        XCTAssertEqual(back.audioFileName, e.audioFileName)
        XCTAssertEqual(back, e)
    }
}
