import XCTest
@testable import OpenWhispCore

final class SubtitleFormatterTests: XCTestCase {

    private func sampleChunks() -> ([FileChunkPlan], [Int: String]) {
        let chunks = [
            FileChunkPlan(index: 0, start: 0, end: 2),
            FileChunkPlan(index: 1, start: 2, end: 5),
            FileChunkPlan(index: 2, start: 5, end: 6.5),
        ]
        let texts: [Int: String] = [0: "Hello there.", 1: "  ", 2: "General Kenobi."]
        return (chunks, texts)
    }

    func testCuesSkipEmptyChunks() {
        let (chunks, texts) = sampleChunks()
        let cues = SubtitleFormatter.cues(chunks: chunks, chunkTexts: texts)
        // Chunk 1 is whitespace-only → skipped.
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello there.")
        XCTAssertEqual(cues[1].text, "General Kenobi.")
        XCTAssertEqual(cues[1].start, 5)
    }

    func testTxtRender() {
        let (chunks, texts) = sampleChunks()
        let out = SubtitleFormatter.render(.txt, chunks: chunks, chunkTexts: texts)
        XCTAssertEqual(out, "Hello there.\nGeneral Kenobi.\n")
    }

    func testSRTRender() {
        let (chunks, texts) = sampleChunks()
        let out = SubtitleFormatter.render(.srt, chunks: chunks, chunkTexts: texts)
        let expected = """
        1
        00:00:00,000 --> 00:00:02,000
        Hello there.

        2
        00:00:05,000 --> 00:00:06,500
        General Kenobi.


        """
        XCTAssertEqual(out, expected)
    }

    func testVTTRender() {
        let (chunks, texts) = sampleChunks()
        let out = SubtitleFormatter.render(.vtt, chunks: chunks, chunkTexts: texts)
        XCTAssertTrue(out.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(out.contains("00:00:05.000 --> 00:00:06.500\nGeneral Kenobi."))
    }

    func testTimestampFormatting() {
        XCTAssertEqual(SubtitleFormatter.srtTimestamp(3661.25), "01:01:01,250")
        XCTAssertEqual(SubtitleFormatter.vttTimestamp(3661.25), "01:01:01.250")
        XCTAssertEqual(SubtitleFormatter.srtTimestamp(0), "00:00:00,000")
    }

    func testEmptyTranscriptRenders() {
        XCTAssertEqual(SubtitleFormatter.render(.txt, cues: []), "")
        XCTAssertEqual(SubtitleFormatter.render(.vtt, cues: []), "WEBVTT\n\n")
    }

    // MARK: - Export naming

    func testExportFileName() {
        XCTAssertEqual(TranscriptExportNaming.exportFileName(sourcePath: "/a/b/talk.mp4", format: .srt), "talk.srt")
        XCTAssertEqual(TranscriptExportNaming.exportFileName(sourcePath: "/a/b/interview.m4a", format: .txt), "interview.txt")
    }

    func testExportPathDefaultsToSourceDir() {
        XCTAssertEqual(
            TranscriptExportNaming.exportPath(sourcePath: "/a/b/talk.mp4", format: .vtt),
            "/a/b/talk.vtt"
        )
        XCTAssertEqual(
            TranscriptExportNaming.exportPath(sourcePath: "/a/b/talk.mp4", format: .vtt, directory: "/out"),
            "/out/talk.vtt"
        )
    }
}
