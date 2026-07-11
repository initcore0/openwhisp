import XCTest
@testable import OpenWhispCore

/// Tests for `MeetingSummarizer`: sentence-boundary segment planning, prompt
/// assembly, and the map/reduce `run` orchestration over a scripted LLM call.
/// MAK-50.
final class MeetingSummarizerTests: XCTestCase {

    // MARK: - Planning

    func testEmptyTranscriptYieldsNoSegments() {
        XCTAssertTrue(MeetingSummarizer.plan(transcript: "   \n  ").isEmpty)
    }

    func testShortTranscriptIsSingleSegment() {
        let t = "We met. We decided to ship. Alice will write the docs."
        let segments = MeetingSummarizer.plan(transcript: t)
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(MeetingSummarizer.isSingleSegment(transcript: t))
    }

    func testLongTranscriptSplitsOnSentenceBoundaries() {
        // Build many sentences so the total exceeds a small segment size.
        let sentence = "This is a sentence about the quarterly plan and its details. "
        let transcript = String(repeating: sentence, count: 40)
        let segments = MeetingSummarizer.plan(transcript: transcript, segmentChars: 300)
        XCTAssertGreaterThan(segments.count, 1)
        // No segment exceeds the limit unless it's a single oversized sentence.
        for seg in segments {
            XCTAssertLessThanOrEqual(seg.text.count, 300 + sentence.count)
        }
        // Indices are contiguous from 0.
        XCTAssertEqual(segments.map(\.index), Array(0..<segments.count))
        // No sentence is cut mid-way: each segment ends at a sentence boundary
        // (period) after trimming.
        for seg in segments {
            XCTAssertTrue(seg.text.hasSuffix("."), "segment should end on a sentence boundary")
        }
    }

    func testOversizedSingleSentenceBecomesOwnSegment() {
        let huge = String(repeating: "word ", count: 200) // no sentence break, > limit
        let segments = MeetingSummarizer.plan(transcript: huge, segmentChars: 100)
        XCTAssertEqual(segments.count, 1)
        XCTAssertGreaterThan(segments[0].text.count, 100)
    }

    func testNewlineSeparatedUnpunctuatedLinesSegment() {
        let transcript = "first line of notes\nsecond line of notes\nthird line here"
        let segments = MeetingSummarizer.plan(transcript: transcript, segmentChars: 25)
        XCTAssertGreaterThan(segments.count, 1)
    }

    // MARK: - Prompts

    func testPromptsDemandSameLanguageAndMarkdownHeadings() {
        for prompt in [MeetingSummarizer.directSummaryPrompt(), MeetingSummarizer.combinePrompt()] {
            XCTAssertTrue(prompt.contains("## Summary"))
            XCTAssertTrue(prompt.contains("## Decisions"))
            XCTAssertTrue(prompt.contains("## Action items"))
            XCTAssertTrue(prompt.lowercased().contains("same language"))
        }
        XCTAssertTrue(MeetingSummarizer.mapPrompt().lowercased().contains("same language"))
    }

    func testCombineInputNumbersPartialsInOrder() {
        let input = MeetingSummarizer.combineInput(partials: ["one", "two", "three"])
        XCTAssertTrue(input.contains("Part 1:"))
        XCTAssertTrue(input.contains("Part 2:"))
        XCTAssertTrue(input.contains("Part 3:"))
        XCTAssertLessThan(input.range(of: "Part 1:")!.lowerBound, input.range(of: "Part 2:")!.lowerBound)
    }

    // MARK: - run() map/reduce

    func testRunSingleSegmentUsesDirectPrompt() async throws {
        var seenInstructions: [String] = []
        let out = try await MeetingSummarizer.run(transcript: "Short meeting. Done.") { instruction, _ in
            seenInstructions.append(instruction)
            return "## Summary\nok"
        }
        XCTAssertEqual(out, "## Summary\nok")
        XCTAssertEqual(seenInstructions.count, 1)
        XCTAssertEqual(seenInstructions.first, MeetingSummarizer.directSummaryPrompt())
    }

    func testRunLongTranscriptMapsThenCombines() async throws {
        let sentence = "The team discussed the roadmap and made a plan for the sprint. "
        let transcript = String(repeating: sentence, count: 40)
        var mapCalls = 0
        var combineCalls = 0
        let out = try await MeetingSummarizer.run(transcript: transcript, segmentChars: 300) { instruction, _ in
            if instruction == MeetingSummarizer.mapPrompt() { mapCalls += 1; return "partial" }
            if instruction == MeetingSummarizer.combinePrompt() { combineCalls += 1; return "## Summary\ncombined" }
            return ""
        }
        XCTAssertGreaterThan(mapCalls, 1)
        XCTAssertEqual(combineCalls, 1)
        XCTAssertEqual(out, "## Summary\ncombined")
    }

    func testRunPropagatesLLMError() async {
        struct E: Error {}
        do {
            _ = try await MeetingSummarizer.run(transcript: "Short. Done.") { _, _ in throw E() }
            XCTFail("expected throw")
        } catch { /* ok */ }
    }
}
