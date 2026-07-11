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
}
