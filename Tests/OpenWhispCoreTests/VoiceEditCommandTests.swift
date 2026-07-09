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

    // MARK: - Review fix #3: non-ASCII trailing punctuation still matches

    func testParseEllipsisTrailingPunctuation() {
        // Whisper commonly emits a Unicode ellipsis; the command must still match
        // rather than being pasted as literal text.
        XCTAssertEqual(VoiceEditCommand.parse("Scratch that…"), .scratchThat)
        XCTAssertEqual(VoiceEditCommand.parse("Undo…"), .undo)
    }

    func testParseCurlyQuoteTrailingPunctuation() {
        XCTAssertEqual(VoiceEditCommand.parse("“scratch that”"), .scratchThat)
        XCTAssertEqual(VoiceEditCommand.parse("‘new line’"), .newLine)
        XCTAssertEqual(VoiceEditCommand.parse("delete last word’"), .deleteLastWord)
    }

    func testParseCJKTrailingPunctuation() {
        XCTAssertEqual(VoiceEditCommand.parse("scratch that。"), .scratchThat)
        XCTAssertEqual(VoiceEditCommand.parse("undo！"), .undo)
        XCTAssertEqual(VoiceEditCommand.parse("new paragraph？"), .newParagraph)
    }

    func testParseMixedUnicodeAndAsciiTrailingPunctuation() {
        XCTAssertEqual(VoiceEditCommand.parse("  Scratch that…”  "), .scratchThat)
    }

    // MARK: - Review fix #1: sentence boundaries ignore decimals & abbreviations

    func testDeleteLastSentenceKeepsDecimalIntact() {
        var buffer = VoiceEditBuffer(utterances: ["The price is 3.50 dollars."])
        buffer.apply(.deleteLastSentence)
        // A single sentence containing a decimal empties, not "The price is 3."
        XCTAssertEqual(buffer.text, "")
    }

    func testDeleteLastSentenceDecimalAfterFirstSentence() {
        var buffer = VoiceEditBuffer(utterances: ["Here is one. The price is 3.50 dollars."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "Here is one.")
    }

    func testDeleteLastSentenceKeepsAbbreviationIntact() {
        var buffer = VoiceEditBuffer(utterances: ["I met Mr. Smith today."])
        buffer.apply(.deleteLastSentence)
        // Must not split at "Mr." — the whole thing is one sentence.
        XCTAssertEqual(buffer.text, "")
    }

    func testDeleteLastSentenceAbbreviationAfterFirstSentence() {
        var buffer = VoiceEditBuffer(utterances: ["Hello there. I met Dr. Smith today."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "Hello there.")
    }

    func testDeleteLastSentenceCapitalInitialNotABoundary() {
        var buffer = VoiceEditBuffer(utterances: ["I saw J. Smith yesterday."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "")
    }

    func testDeleteLastSentenceRealBoundaryStillSplitsAfterDecimal() {
        // The decimal is mid-sentence; a genuine "." must still end the prior one.
        var buffer = VoiceEditBuffer(utterances: ["It costs 3.50. Ship it now."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "It costs 3.50.")
    }

    func testDeleteLastSentenceExclamationStillSplits() {
        var buffer = VoiceEditBuffer(utterances: ["I met Mr. Smith! He is nice."])
        buffer.apply(.deleteLastSentence)
        XCTAssertEqual(buffer.text, "I met Mr. Smith!")
    }

    // MARK: - Review fix #4: delete-last-word after a break removes the break only

    func testDeleteLastWordAfterNewParagraphRemovesBreakOnly() {
        var buffer = VoiceEditBuffer(utterances: ["First para"])
        buffer.apply(.newParagraph)             // text: "First para\n\n"
        buffer.apply(.deleteLastWord)
        // The break goes; the preceding word stays.
        XCTAssertEqual(buffer.text, "First para")
    }

    func testDeleteLastWordAfterNewLineRemovesBreakOnly() {
        var buffer = VoiceEditBuffer(utterances: ["Line one"])
        buffer.apply(.newLine)                  // text: "Line one\n"
        buffer.apply(.deleteLastWord)
        XCTAssertEqual(buffer.text, "Line one")
    }

    func testDeleteLastWordAfterBreakThenAgainDeletesTheWord() {
        var buffer = VoiceEditBuffer(utterances: ["First para"])
        buffer.apply(.newParagraph)
        buffer.apply(.deleteLastWord)           // removes the break -> "First para"
        buffer.apply(.deleteLastWord)           // now removes the word -> "First"
        XCTAssertEqual(buffer.text, "First")
    }

    func testDeleteLastWordMidBufferBreakSurvives() {
        // A break earlier in the buffer must not be touched when a trailing word
        // is deleted.
        var buffer = VoiceEditBuffer(utterances: ["Para one"])
        buffer.apply(.newParagraph)
        buffer.append("second chunk here")
        buffer.apply(.deleteLastWord)
        XCTAssertEqual(buffer.text, "Para one\n\nsecond chunk")
    }

    // MARK: - Review fix #2: deletes preserve utterance boundaries for scratch-that

    func testScratchThatAfterDeleteWordDropsOnlyLastChunk() {
        var buffer = VoiceEditBuffer(utterances: ["first chunk", "second chunk here"])
        buffer.apply(.deleteLastWord)           // -> "first chunk second chunk"
        // Structure is preserved: the collapsed edit is still two utterances, so
        // "scratch that" drops only the trailing one, not the whole dictation.
        buffer.apply(.scratchThat)
        XCTAssertEqual(buffer.text, "first chunk")
    }

    func testScratchThatAfterDeleteSentenceDropsOnlyLastChunk() {
        var buffer = VoiceEditBuffer(utterances: ["First chunk here.", "Second chunk. Trailing note."])
        buffer.apply(.deleteLastSentence)       // drops "Trailing note." within the 2nd chunk
        XCTAssertEqual(buffer.text, "First chunk here. Second chunk.")
        // The two original chunks are still distinct elements — the sentence
        // delete truncated only the last one — so "scratch that" drops just it,
        // not the whole dictation.
        buffer.apply(.scratchThat)
        XCTAssertEqual(buffer.text, "First chunk here.")
    }

    func testDeletePreservesParagraphBreaksAsMarkers() {
        var buffer = VoiceEditBuffer(utterances: ["alpha beta"])
        buffer.apply(.newParagraph)
        buffer.append("gamma delta")
        buffer.apply(.deleteLastWord)           // -> "alpha beta\n\ngamma"
        // The paragraph break is kept as its own element, so "scratch that"
        // peels back to just before it.
        buffer.apply(.scratchThat)              // drop "gamma"
        buffer.apply(.scratchThat)              // drop the break marker
        XCTAssertEqual(buffer.text, "alpha beta")
    }

    func testDeleteWordThenScratchThatUndoRestoresPreEdit() {
        var buffer = VoiceEditBuffer(utterances: ["first chunk", "second chunk here"])
        buffer.apply(.deleteLastWord)
        buffer.apply(.scratchThat)
        buffer.apply(.undo)                     // restore the scratch-that
        XCTAssertEqual(buffer.text, "first chunk second chunk")
    }

    // MARK: - reapplyTrim (structure-preserving suffix removal)

    func testReapplyTrimKeepsEarlierElementsVerbatim() {
        let original = ["first chunk", "second chunk here"]
        // "first chunk second chunk here" trimmed to "first chunk second chunk"
        let result = VoiceEditBuffer.reapplyTrim(
            original: original,
            editedFlattened: "first chunk second chunk"
        )
        XCTAssertEqual(result, ["first chunk", "second chunk"])
    }

    func testReapplyTrimDropsFullyRemovedElement() {
        let original = ["hello there", "friend"]
        let result = VoiceEditBuffer.reapplyTrim(
            original: original,
            editedFlattened: "hello there"
        )
        XCTAssertEqual(result, ["hello there"])
    }

    func testReapplyTrimPreservesBreakMarkers() {
        let original = ["alpha beta", "\n\n", "gamma delta"]
        let result = VoiceEditBuffer.reapplyTrim(
            original: original,
            editedFlattened: "alpha beta\n\ngamma"
        )
        XCTAssertEqual(result, ["alpha beta", "\n\n", "gamma"])
    }

    func testReapplyTrimDropsDanglingTrailingBreak() {
        let original = ["alpha", "\n\n"]
        let result = VoiceEditBuffer.reapplyTrim(
            original: original,
            editedFlattened: "alpha"
        )
        XCTAssertEqual(result, ["alpha"])
    }

    func testReapplyTrimEmptyResult() {
        let original = ["only"]
        let result = VoiceEditBuffer.reapplyTrim(original: original, editedFlattened: "")
        XCTAssertEqual(result, [])
    }
}
