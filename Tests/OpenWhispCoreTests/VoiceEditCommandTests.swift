import XCTest
@testable import OpenWhispCore

final class VoiceEditCommandTests: XCTestCase {

    // MARK: - Parsing: each command recognized

    func testParseScratchThat() {
        XCTAssertEqual(VoiceEditCommand.parse("scratch that"), .scratchThat)
    }

    func testParseDeleteLastWord() {
        XCTAssertEqual(VoiceEditCommand.parse("delete last word"), .deleteLastWord)
        XCTAssertEqual(VoiceEditCommand.parse("delete the last word"), .deleteLastWord)
    }

    func testParseDeleteLastSentence() {
        XCTAssertEqual(VoiceEditCommand.parse("delete last sentence"), .deleteLastSentence)
        XCTAssertEqual(VoiceEditCommand.parse("delete the last sentence"), .deleteLastSentence)
    }

    func testParseNewParagraph() {
        XCTAssertEqual(VoiceEditCommand.parse("new paragraph"), .newParagraph)
    }

    func testParseNewLine() {
        XCTAssertEqual(VoiceEditCommand.parse("new line"), .newLine)
        XCTAssertEqual(VoiceEditCommand.parse("newline"), .newLine)
    }

    func testParseUndo() {
        XCTAssertEqual(VoiceEditCommand.parse("undo"), .undo)
        XCTAssertEqual(VoiceEditCommand.parse("undo that"), .undo)
    }

    // MARK: - Parsing: case / punctuation / whitespace tolerance

    func testParseCaseInsensitive() {
        XCTAssertEqual(VoiceEditCommand.parse("Scratch That"), .scratchThat)
        XCTAssertEqual(VoiceEditCommand.parse("UNDO"), .undo)
    }

    func testParseTrailingPunctuation() {
        XCTAssertEqual(VoiceEditCommand.parse("Scratch that."), .scratchThat)
        XCTAssertEqual(VoiceEditCommand.parse("New line!"), .newLine)
        XCTAssertEqual(VoiceEditCommand.parse("Undo?"), .undo)
    }

    func testParseSurroundingWhitespace() {
        XCTAssertEqual(VoiceEditCommand.parse("   undo   "), .undo)
        XCTAssertEqual(VoiceEditCommand.parse("\n scratch that \t"), .scratchThat)
    }

    func testParseCollapsesInternalWhitespace() {
        XCTAssertEqual(VoiceEditCommand.parse("delete   last    word"), .deleteLastWord)
    }

    // MARK: - Parsing: near-misses are NOT commands

    func testScratchTheSurfaceIsNotACommand() {
        XCTAssertNil(VoiceEditCommand.parse("scratch the surface"))
    }

    func testCommandAsSubstringIsNotACommand() {
        // Ordinary dictation that merely contains the words must survive.
        XCTAssertNil(VoiceEditCommand.parse("please scratch that itch for me"))
        XCTAssertNil(VoiceEditCommand.parse("delete the last word from the file"))
        XCTAssertNil(VoiceEditCommand.parse("let's start a new paragraph in the essay"))
        XCTAssertNil(VoiceEditCommand.parse("I need to undo my mistake later"))
    }

    func testEmptyAndWhitespaceAreNotCommands() {
        XCTAssertNil(VoiceEditCommand.parse(""))
        XCTAssertNil(VoiceEditCommand.parse("   "))
        XCTAssertNil(VoiceEditCommand.parse("\n\t"))
    }

    func testPlainDictationIsNotACommand() {
        XCTAssertNil(VoiceEditCommand.parse("the meeting is at noon tomorrow"))
    }

    // MARK: - Application: scratch that / undo

    func testScratchThatDropsLastUtterance() {
        var buffer = VoiceEditBuffer(utterances: ["Hello world", "this is wrong"])
        buffer.apply(.scratchThat)
        XCTAssertEqual(buffer.utterances, ["Hello world"])
        XCTAssertEqual(buffer.text, "Hello world")
    }

    func testUndoRestoresScratchThat() {
        var buffer = VoiceEditBuffer(utterances: ["Hello world", "this is wrong"])
        buffer.apply(.scratchThat)
        XCTAssertEqual(buffer.utterances, ["Hello world"])
        buffer.apply(.undo)
        XCTAssertEqual(buffer.utterances, ["Hello world", "this is wrong"])
    }

    func testScratchThatOnEmptyBufferIsNoOp() {
        var buffer = VoiceEditBuffer()
        buffer.apply(.scratchThat)
        XCTAssertEqual(buffer.utterances, [])
        XCTAssertEqual(buffer.text, "")
    }

    func testUndoOnEmptyHistoryIsNoOp() {
        var buffer = VoiceEditBuffer(utterances: ["Hello"])
        buffer.apply(.undo)
        XCTAssertEqual(buffer.utterances, ["Hello"])
    }

    func testUndoIsOneLevelOnly() {
        var buffer = VoiceEditBuffer(utterances: ["a", "b", "c"])
        buffer.apply(.scratchThat)          // -> [a, b]
        buffer.apply(.undo)                 // -> [a, b, c]
        buffer.apply(.undo)                 // second undo is a no-op (not a redo)
        XCTAssertEqual(buffer.utterances, ["a", "b", "c"])
    }

    func testNewDictationClearsUndoSnapshot() {
        var buffer = VoiceEditBuffer(utterances: ["a", "b"])
        buffer.apply(.scratchThat)          // -> [a], snapshot = [a, b]
        buffer.append("c")                  // -> [a, c], snapshot cleared
        buffer.apply(.undo)                 // nothing to undo
        XCTAssertEqual(buffer.utterances, ["a", "c"])
    }

    // MARK: - Application: delete last word

    func testDeleteLastWord() {
        var buffer = VoiceEditBuffer(utterances: ["the quick brown fox"])
        buffer.apply(.deleteLastWord)
        XCTAssertEqual(buffer.text, "the quick brown")
    }

    func testDeleteLastWordAcrossUtterances() {
        var buffer = VoiceEditBuffer(utterances: ["hello there", "friend"])
        buffer.apply(.deleteLastWord)
        XCTAssertEqual(buffer.text, "hello there")
    }

    func testDeleteLastWordDownToEmpty() {
        var buffer = VoiceEditBuffer(utterances: ["only"])
        buffer.apply(.deleteLastWord)
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.utterances, [])
    }

    func testDeleteLastWordUndo() {
        var buffer = VoiceEditBuffer(utterances: ["one two three"])
        buffer.apply(.deleteLastWord)
        XCTAssertEqual(buffer.text, "one two")
        buffer.apply(.undo)
        XCTAssertEqual(buffer.text, "one two three")
    }

    func testDeleteLastWordOnEmptyBufferIsNoOp() {
        var buffer = VoiceEditBuffer()
        buffer.apply(.deleteLastWord)
        XCTAssertEqual(buffer.text, "")
    }

    // MARK: - Application: delete last sentence

    func testDeleteLastSentenceMultiSentence() {
        var buffer = VoiceEditBuffer(utterances: ["First sentence. Second sentence."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "First sentence.")
    }

    func testDeleteLastSentenceWithQuestionMark() {
        var buffer = VoiceEditBuffer(utterances: ["Are you sure? Yes I am."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "Are you sure?")
    }

    func testDeleteLastSentenceSingleSentenceEmpties() {
        var buffer = VoiceEditBuffer(utterances: ["Just one sentence."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "")
    }

    func testDeleteLastSentenceNoTerminatorEmpties() {
        var buffer = VoiceEditBuffer(utterances: ["a running note with no period"])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "")
    }

    func testDeleteLastSentenceAcrossThree() {
        var buffer = VoiceEditBuffer(utterances: ["One. Two. Three."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "One. Two.")
    }

    func testDeleteLastSentenceUndo() {
        var buffer = VoiceEditBuffer(utterances: ["First sentence. Second sentence."])
        buffer.apply(.deleteLastSentence)
        buffer.apply(.undo)
        XCTAssertEqual(buffer.text, "First sentence. Second sentence.")
    }

    func testDeleteLastSentenceOnEmptyBufferIsNoOp() {
        var buffer = VoiceEditBuffer()
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "")
    }

    // MARK: - Application: new paragraph / new line

    func testNewParagraphAppendsDoubleNewline() {
        var buffer = VoiceEditBuffer(utterances: ["First para"])
        buffer.apply(.newParagraph)
        buffer.append("Second para")
        XCTAssertEqual(buffer.text, "First para\n\nSecond para")
    }

    func testNewLineAppendsSingleNewline() {
        var buffer = VoiceEditBuffer(utterances: ["Line one"])
        buffer.apply(.newLine)
        buffer.append("Line two")
        XCTAssertEqual(buffer.text, "Line one\nLine two")
    }

    func testNewLineOnEmptyBuffer() {
        var buffer = VoiceEditBuffer()
        buffer.apply(.newLine)
        buffer.append("text")
        XCTAssertEqual(buffer.text, "\ntext")
    }

    func testNewParagraphCanBeUndone() {
        var buffer = VoiceEditBuffer(utterances: ["Only para"])
        buffer.apply(.newParagraph)
        buffer.apply(.undo)
        XCTAssertEqual(buffer.utterances, ["Only para"])
        XCTAssertEqual(buffer.text, "Only para")
    }

    func testScratchThatDropsABreakMarker() {
        var buffer = VoiceEditBuffer(utterances: ["Para"])
        buffer.apply(.newParagraph)         // -> ["Para", "\n\n"]
        buffer.apply(.scratchThat)          // drops the break marker
        XCTAssertEqual(buffer.utterances, ["Para"])
        XCTAssertEqual(buffer.text, "Para")
    }

    // MARK: - Buffer bookkeeping

    func testAppendIgnoresEmptyUtterances() {
        var buffer = VoiceEditBuffer()
        buffer.append("   ")
        buffer.append("")
        buffer.append("real")
        XCTAssertEqual(buffer.utterances, ["real"])
    }

    func testAppendTrimsWhitespace() {
        var buffer = VoiceEditBuffer()
        buffer.append("  padded  ")
        XCTAssertEqual(buffer.utterances, ["padded"])
    }

    func testTextJoinsUtterancesWithSpaces() {
        let buffer = VoiceEditBuffer(utterances: ["Hello", "world", "again"])
        XCTAssertEqual(buffer.text, "Hello world again")
    }

    // MARK: - End-to-end: parse then apply

    func testParseThenApplyScratchThat() {
        var buffer = VoiceEditBuffer(utterances: ["keep this", "drop this"])
        if let command = VoiceEditCommand.parse("Scratch that.") {
            buffer.apply(command)
        } else {
            XCTFail("expected a command")
        }
        XCTAssertEqual(buffer.text, "keep this")
    }
}
