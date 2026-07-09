import XCTest
@testable import OpenWhispCore

/// Tests for the spoken-filename → `@`-mention transform (MAK-48).
///
/// The two halves matter equally: the positive cases prove the intended
/// rewrites fire, and the (larger) negative section proves the transform never
/// mangles ordinary prose. The "at noon"-style boundary is documented and
/// tested explicitly.
final class FileTagTransformTests: XCTestCase {

    // MARK: - Positive: "<name> dot <ext>" with spelled-out letter extensions

    func testMainDotTS() {
        XCTAssertEqual(FileTagTransform.transform("main dot t s"), "@main.ts")
    }

    func testIndexDotJSX() {
        XCTAssertEqual(FileTagTransform.transform("index dot j s x"), "@index.jsx")
    }

    func testAppDotTSX() {
        XCTAssertEqual(FileTagTransform.transform("app dot t s x"), "@app.tsx")
    }

    func testScriptDotPY() {
        XCTAssertEqual(FileTagTransform.transform("script dot p y"), "@script.py")
    }

    func testServerDotJS() {
        XCTAssertEqual(FileTagTransform.transform("server dot j s"), "@server.js")
    }

    func testLibDotRS() {
        XCTAssertEqual(FileTagTransform.transform("lib dot r s"), "@lib.rs")
    }

    // MARK: - Positive: "<name> dot <ext>" with a whole-word extension

    func testWholeWordSwift() {
        XCTAssertEqual(FileTagTransform.transform("main dot swift"), "@main.swift")
    }

    func testWholeWordJSON() {
        XCTAssertEqual(FileTagTransform.transform("package dot json"), "@package.json")
    }

    func testWholeWordCSS() {
        XCTAssertEqual(FileTagTransform.transform("styles dot css"), "@styles.css")
    }

    func testWholeWordHTML() {
        XCTAssertEqual(FileTagTransform.transform("index dot html"), "@index.html")
    }

    func testWholeWordMarkdown() {
        XCTAssertEqual(FileTagTransform.transform("readme dot md"), "@readme.md")
    }

    // MARK: - Positive: leading "at" cue

    func testAtMain() {
        XCTAssertEqual(FileTagTransform.transform("at main"), "@main")
    }

    func testAtConfig() {
        XCTAssertEqual(FileTagTransform.transform("at config"), "@config")
    }

    func testAtNameWithDotExtIsUnambiguous() {
        // "at <name> dot <ext>" always fires — the "dot <ext>" is its own strong
        // cue, so even a name that would be a stop-word bare is fine here.
        XCTAssertEqual(FileTagTransform.transform("at main dot t s"), "@main.ts")
    }

    // MARK: - Positive: mixed in a sentence

    func testMixedInSentence() {
        XCTAssertEqual(
            FileTagTransform.transform("open main dot t s and fix it"),
            "open @main.ts and fix it")
    }

    func testMixedTwoFilesInSentence() {
        XCTAssertEqual(
            FileTagTransform.transform("compare index dot j s x with app dot t s x"),
            "compare @index.jsx with @app.tsx")
    }

    func testAtMentionMidSentence() {
        XCTAssertEqual(
            FileTagTransform.transform("please look at config and tell me"),
            "please look @config and tell me")
    }

    func testNameAndAtFormTogether() {
        XCTAssertEqual(
            FileTagTransform.transform("edit main dot swift then open at helpers"),
            "edit @main.swift then open @helpers")
    }

    // MARK: - Punctuation handling

    func testTrailingPunctuationAfterExtensionPreserved() {
        // A period after the extension is sentence punctuation, kept OUTSIDE the
        // mention. "main dot t s." -> "@main.ts." A comma likewise.
        XCTAssertEqual(
            FileTagTransform.transform("open main dot t s, then run it"),
            "open @main.ts, then run it")
    }

    func testAtFormAbsorbsThePrecedingAt() {
        // "look at main dot t s." is the unambiguous "at <name> dot <ext>" form,
        // so the "at" is absorbed into the mention: "look @main.ts." (not
        // "look at @main.ts."). The trailing period stays outside the mention.
        XCTAssertEqual(
            FileTagTransform.transform("look at main dot t s."),
            "look @main.ts.")
    }

    func testTrailingPunctuationAfterBareAtMention() {
        XCTAssertEqual(FileTagTransform.transform("at main."), "@main.")
        XCTAssertEqual(FileTagTransform.transform("open at config, please"), "open @config, please")
    }

    // MARK: - Negative: ordinary prose must be left ALONE

    func testIAteLunchNotMangled() {
        // "ate" is not "at" (different token), and even the "at" branch would
        // stop on "lunch". Ordinary sentence, unchanged.
        let s = "I ate lunch"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testTheMainPointNotAFilename() {
        // No "dot <ext>" and no "at" cue -> "main" is just a word.
        let s = "the main point is clear"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testTheMainIdeaNotAFilename() {
        let s = "the main idea"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testDotProductNotAFilename() {
        // "dot product" — "product" is not a known extension, so no rewrite.
        let s = "compute the dot product of the vectors"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testAtNoonLeftAlone() {
        // The documented boundary: "noon" is a common "at <word>" prose word, so
        // "at noon" is NOT turned into a file mention.
        let s = "the meeting is at noon"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testAtLunchLeftAlone() {
        let s = "let's meet at lunch"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testAtLeastLeftAlone() {
        let s = "at least it works"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testAtHomeLeftAlone() {
        let s = "I will be at home tomorrow"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testAtOnceLeftAlone() {
        let s = "do it at once"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testAtTheLeftAlone() {
        let s = "look at the sky"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testAtNightLeftAlone() {
        let s = "we ship at night"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testBareAtSingleLetterLeftAlone() {
        // "at a" — single letter is too short to be a filename.
        let s = "point at a star"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testNumberDotNumberNotAFilename() {
        // "twelve dot five" -> the name must be identifier-shaped and the ext
        // recognized; "five" is neither a known ext nor letters, so unchanged.
        let s = "the value is twelve dot five"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testDigitDotDigitNotAFilename() {
        let s = "version 3 dot 2"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testDotFollowedByUnknownWordNotRewritten() {
        // "dot com" — "com" is not in the known-extension set, so left alone
        // rather than guessing.
        let s = "go to example dot com"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testDotFollowedBySingleLetterOnlyNotRewritten() {
        // A single stray letter after "dot" is not an extension (need ≥2 that
        // join into a known ext).
        let s = "the file main dot x here"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testTwoLettersThatDontFormKnownExtNotRewritten() {
        // "q w" doesn't join into any known extension -> untouched.
        let s = "main dot q w"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testNamePunctuationBreaksTheForm() {
        // Punctuation between name and "dot" means it isn't a filename form.
        let s = "that is the main, dot t s notation"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    func testEmptyInput() {
        XCTAssertEqual(FileTagTransform.transform(""), "")
    }

    func testPlainSentenceUnchanged() {
        let s = "just a normal note about the project status"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    // MARK: - Letter-run boundaries

    func testLetterRunStopsAtNonLetterWord() {
        // "main dot t s here" -> extension is the "t s" run; "here" is untouched.
        XCTAssertEqual(
            FileTagTransform.transform("main dot t s here"),
            "@main.ts here")
    }

    func testLongestKnownExtensionPrefixWins() {
        // "j s x" should prefer "jsx" over "js" (longest known prefix).
        XCTAssertEqual(FileTagTransform.transform("comp dot j s x"), "@comp.jsx")
    }

    func testGoExtension() {
        XCTAssertEqual(FileTagTransform.transform("server dot g o"), "@server.go")
    }

    // MARK: - Idempotence / already-a-mention

    func testAlreadyMentionedFileIsStable() {
        // No spoken form present; an already-typed @mention passes through.
        let s = "open @main.ts and edit"
        XCTAssertEqual(FileTagTransform.transform(s), s)
    }

    // MARK: - Per-app enablement: appliesTo(bundleID:)
    //
    // The gating crux: file-tagging must fire ONLY when the frontmost app is a
    // known AI-native editor, so a spoken "@main.ts" never lands in a Slack
    // message or a doc. These verify the pure decision used by AppState.

    func testAppliesToCursorBundleID() {
        // The real Cursor bundle id (Cursor ships via ToDesktop), verified from
        // the installed /Applications/Cursor.app Info.plist.
        XCTAssertTrue(FileTagTransform.appliesTo(bundleID: "com.todesktop.230313mzl4w4u92"))
    }

    func testAppliesToWindsurfBundleID() {
        XCTAssertTrue(FileTagTransform.appliesTo(bundleID: "com.exafunction.windsurf"))
    }

    func testDoesNotApplyToChatApp() {
        // Slack, Messages, a browser, TextEdit — anywhere an @-mention is prose.
        XCTAssertFalse(FileTagTransform.appliesTo(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(FileTagTransform.appliesTo(bundleID: "com.apple.MobileSMS"))
        XCTAssertFalse(FileTagTransform.appliesTo(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(FileTagTransform.appliesTo(bundleID: "com.google.Chrome"))
    }

    func testDoesNotApplyToNilBundleID() {
        // No identifiable frontmost app (nil) → never rewrite.
        XCTAssertFalse(FileTagTransform.appliesTo(bundleID: nil))
    }

    func testDoesNotApplyToEmptyBundleID() {
        XCTAssertFalse(FileTagTransform.appliesTo(bundleID: ""))
    }

    func testKnownEditorSetContainsBothEditors() {
        // The set is the single source of truth AppState reads; guard it doesn't
        // silently lose an editor.
        XCTAssertTrue(FileTagTransform.editorBundleIDs.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(FileTagTransform.editorBundleIDs.contains("com.exafunction.windsurf"))
    }
}
