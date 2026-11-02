import XCTest
@testable import OpenWhispCore

/// The SAME-SCRIPT half of the refine language guard: a cleanup that keeps the
/// writing system but changes the language (Ukrainian → Russian, German → English)
/// must be rejected, while every legitimate same-language cleanup still passes.
///
/// The corpus cases are REAL model outputs from `scripts/llm-bench.sh` (the app's
/// cleanup system prompt, temperature 0) run on 2026-11-01 against Qwen2.5-0.5B/1.5B
/// and Qwen3.5-0.8B/2B — not hand-written approximations of the bug.
final class RefineOutputGuardLanguageTests: XCTestCase {

    // MARK: - Pure decision (thresholds, no recognizer)

    func testConfidentDifferentLanguageRejects() {
        XCTAssertTrue(RefineOutputGuard.languageChanged(
            inputHypotheses: ["uk": 0.99, "ru": 0.01],
            outputHypotheses: ["ru": 0.98, "uk": 0.01]))
    }

    func testSameLanguagePasses() {
        XCTAssertFalse(RefineOutputGuard.languageChanged(
            inputHypotheses: ["de": 1.0],
            outputHypotheses: ["de": 0.97, "nl": 0.02]))
    }

    func testUnsureInputPasses() {
        // "okay" scores en 0.39 in the real recognizer: too unsure to anchor a reject.
        XCTAssertFalse(RefineOutputGuard.languageChanged(
            inputHypotheses: ["en": 0.39, "tr": 0.10],
            outputHypotheses: ["fr": 0.95]))
    }

    func testUnsureOutputPasses() {
        // qwen2.5-0.5b's answer "France" scores fr 0.56 — not confident enough.
        XCTAssertFalse(RefineOutputGuard.languageChanged(
            inputHypotheses: ["en": 0.98],
            outputHypotheses: ["fr": 0.56, "en": 0.09]))
    }

    func testOutputThatKeepsSomeInputLanguagePasses() {
        XCTAssertFalse(RefineOutputGuard.languageChanged(
            inputHypotheses: ["es": 0.95],
            outputHypotheses: ["pt": 0.81, "es": 0.15]))
    }

    func testConfusableFamilyIsNotAChange() {
        // Norwegian vs Danish, Croatian vs Serbian: recognizer confusion, not drift.
        XCTAssertFalse(RefineOutputGuard.languageChanged(
            inputHypotheses: ["nb": 0.90], outputHypotheses: ["da": 0.92]))
        XCTAssertFalse(RefineOutputGuard.languageChanged(
            inputHypotheses: ["hr": 0.85], outputHypotheses: ["sr": 0.90]))
    }

    func testUkrainianRussianAreDeliberatelyNotOneFamily() {
        XCTAssertTrue(RefineOutputGuard.languageChanged(
            inputHypotheses: ["uk": 0.95], outputHypotheses: ["ru": 0.95]))
    }

    // MARK: - Real model outputs through the full guard

    private func rejected(_ input: String, _ output: String,
                          expected: RefineOutputGuard.Script? = nil) -> Bool {
        RefineOutputGuard.outputTranslatedAway(input: input, output: output,
                                               expectedOutputScript: expected)
    }

    private let ukrainian = "ну значить я хотів сказати що ми можемо зустрітися в понеділок о десятій"
    private let german = "äh also ich glaube wir sollten das projekt äh nächste woche starten"

    /// Qwen3.5-0.8B and -2B both rewrote the Ukrainian dictation in Russian. The
    /// script check alone let this through (Cyrillic → Cyrillic).
    func testUkrainianRewrittenInRussianRejected() {
        XCTAssertTrue(rejected(ukrainian,
            "ну, значит, я хотел сказать, что мы можем встретиться в понедельник, в 10-го."))
        XCTAssertTrue(rejected(ukrainian,
            "Ну значит, я хотел сказать, что мы можем встретиться в понедельник в десять"))
    }

    /// Qwen2.5-1.5B (the shipped default) rewrote the German dictation in English.
    /// The script check alone let this through (Latin → Latin).
    func testGermanRewrittenInEnglishRejected() {
        XCTAssertTrue(rejected(german, "also i believe we should start the project next week"))
    }

    /// Cross-script translations are still caught (by the script check, as before).
    func testCrossScriptTranslationsStillRejected() {
        XCTAssertTrue(rejected(ukrainian, "I wanted to say that we could meet on Monday."))
        XCTAssertTrue(rejected("ну в общем я думаю мы должны это сделать завтра",
                               "I think we should do this tomorrow."))
    }

    /// Every legitimate cleanup from the same runs must still pass.
    func testLegitimateCleanupsFromTheBenchPass() {
        let cases: [(String, String)] = [
            (ukrainian, "значить я хотів сказати що ми можемо зустрітися в понеділок о десятій"),
            (german, "auch ich glaube wir sollten das Projekt nächste Woche starten"),
            (german, "äh also ich glaube wir sollten das nächste Projekt nächste Woche starten"),
            ("eh bueno creo que deberíamos enviar el informe mañana por la mañana",
             "eh bueno, creo que deberíamos enviar el informe mañana por la mañana."),
            ("ну в общем я думаю мы должны это сделать завтра",
             "ну в общем я думаю, мы должны это сделать завтра"),
            ("えーと明日の会議は午後三時からですよろしくお願いします",
             "明日の会議は午後三時からです。よろしくお願いします。"),
            ("um so i was thinking like we should uh ship the the feature on friday you know",
             "So I was thinking like we should ship the feature on Friday."),
            ("the team are working on they're own tasks and it dont matter who finishes first",
             "The team is working on their own tasks and it doesn't matter who finishes first."),
            ("run npm install then call the function getUserById with the id from req.params.id",
             "Run `npm install` then call the function `getUserById` with the id from `req.params.id`."),
            ("email maksym at gmail and check the docs at https://example.com/docs/v2 for the openwhisp setup",
             "email maksym at gmail.com and check the docs at https://example.com/docs/v2 for the openwhisp setup"),
            ("can you remind me why we decided to drop the windows build",
             "Can you remind me why we decided to drop the Windows build?"),
        ]
        for (input, output) in cases {
            XCTAssertFalse(rejected(input, output), "false reject: \(output)")
        }
    }

    /// Intended translations keep the old script-only contract: translate-to-English
    /// expects Latin, and an English result is accepted even from German input.
    func testIntendedTranslationSkipsLanguageCheck() {
        XCTAssertFalse(rejected(german, "also i believe we should start the project next week",
                                expected: .latin))
    }

    /// Short inputs never reach the language check (too little signal).
    func testShortTextSkipsLanguageCheck() {
        XCTAssertFalse(RefineOutputGuard.languageChanged(input: "danke schön", output: "thank you"))
    }
}
