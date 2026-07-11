import XCTest
@testable import OpenWhispCore

/// MAK-52: `TranscriptInterleaver` merges per-leg chunks into an attributed
/// transcript. Covers ordering, same-speaker merging, tie stability, and empties.
final class TranscriptInterleaverTests: XCTestCase {

    private func chunk(_ speaker: String, _ start: TimeInterval, _ text: String) -> TranscriptInterleaver.Chunk {
        TranscriptInterleaver.Chunk(speaker: speaker, start: start, text: text)
    }

    func testOrdersByStartTimeAcrossSpeakers() {
        let merged = TranscriptInterleaver.merge([
            chunk("Them", 2, "Sounds good."),
            chunk("Me", 0, "Hi there."),
            chunk("Me", 1, "Quick note."),
            chunk("Them", 4, "Bye."),
        ])
        // Ordered by start time; the two adjacent Me chunks (0,1) fold together, and
        // the two Them chunks (2,4) fold together — three lines, correct order.
        XCTAssertEqual(merged, "Me: Hi there. Quick note.\nThem: Sounds good. Bye.")
    }

    func testMergesConsecutiveSameSpeaker() {
        let merged = TranscriptInterleaver.merge([
            chunk("Me", 0, "First."),
            chunk("Me", 1, "Second."),
            chunk("Them", 2, "Reply."),
            chunk("Me", 3, "Third."),
        ])
        // The two adjacent Me chunks fold into one line; the later Me is separate.
        XCTAssertEqual(merged, "Me: First. Second.\nThem: Reply.\nMe: Third.")
    }

    func testSkipsEmptyAndWhitespaceChunks() {
        let merged = TranscriptInterleaver.merge([
            chunk("Me", 0, "Real."),
            chunk("Them", 1, "   "),
            chunk("Them", 2, ""),
            chunk("Me", 3, "More."),
        ])
        // The empty Them chunks vanish AND don't break the Me run around them.
        XCTAssertEqual(merged, "Me: Real. More.")
    }

    func testStableOrderOnStartTies() {
        // Equal start times keep input order (stable), so Me precedes Them here.
        let merged = TranscriptInterleaver.merge([
            chunk("Me", 5, "A"),
            chunk("Them", 5, "B"),
        ])
        XCTAssertEqual(merged, "Me: A\nThem: B")

        // And the reverse input order is preserved too — proving it's input order,
        // not an alphabetical or speaker-priority sort.
        let reversed = TranscriptInterleaver.merge([
            chunk("Them", 5, "B"),
            chunk("Me", 5, "A"),
        ])
        XCTAssertEqual(reversed, "Them: B\nMe: A")
    }

    func testEmptyInputYieldsEmptyString() {
        XCTAssertEqual(TranscriptInterleaver.merge([]), "")
        XCTAssertEqual(TranscriptInterleaver.merge([chunk("Me", 0, "  ")]), "")
    }

    func testTrimsChunkTextButKeepsInternalSpacing() {
        let merged = TranscriptInterleaver.merge([
            chunk("Me", 0, "  padded  "),
        ])
        XCTAssertEqual(merged, "Me: padded")
    }

    // MARK: - mergePlain (plain transcript derived from the legs, MAK-52 perf)

    func testMergePlainOrdersTrimsAndDropsEmptiesWithoutLabels() {
        let plain = TranscriptInterleaver.mergePlain([
            chunk("Them", 2, "Sounds good."),
            chunk("Me", 0, "  Hi there.  "),
            chunk("Them", 1, "   "),
            chunk("Me", 4, "Bye."),
        ])
        XCTAssertEqual(plain, "Hi there. Sounds good. Bye.")
        XCTAssertFalse(plain.contains("Me:"), "plain merge must carry no speaker labels")
    }

    func testMergePlainEmptyInputYieldsEmptyString() {
        XCTAssertEqual(TranscriptInterleaver.mergePlain([]), "")
        XCTAssertEqual(TranscriptInterleaver.mergePlain([chunk("Me", 0, " \n ")]), "")
    }

    func testMergePlainMatchesMergeOrderingOnTies() {
        let chunks = [chunk("Them", 5, "B"), chunk("Me", 5, "A")]
        XCTAssertEqual(TranscriptInterleaver.mergePlain(chunks), "B A")
    }

    // MARK: - failed-segment placeholder + hasMeaningfulText

    func testFailedSegmentPlaceholderSurvivesMerge() {
        let merged = TranscriptInterleaver.merge([
            chunk("Me", 0, "Before."),
            chunk("Me", 1, TranscriptInterleaver.failedSegmentPlaceholder),
            chunk("Me", 2, "After."),
        ])
        XCTAssertTrue(merged.contains(TranscriptInterleaver.failedSegmentPlaceholder),
                      "a failed chunk must be a visible hole, not a silent gap")
    }

    func testHasMeaningfulTextIgnoresBlanksAndPlaceholders() {
        XCTAssertFalse(TranscriptInterleaver.hasMeaningfulText([]))
        XCTAssertFalse(TranscriptInterleaver.hasMeaningfulText([
            chunk("Me", 0, "   "),
            chunk("Them", 1, TranscriptInterleaver.failedSegmentPlaceholder),
        ]))
        XCTAssertTrue(TranscriptInterleaver.hasMeaningfulText([
            chunk("Me", 0, TranscriptInterleaver.failedSegmentPlaceholder),
            chunk("Them", 1, "Real words."),
        ]))
    }
}
