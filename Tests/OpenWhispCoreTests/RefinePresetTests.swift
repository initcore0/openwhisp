import XCTest
import Foundation
@testable import OpenWhispCore

/// MAK-77 — per-app refine tone/formatting presets.
///
/// Three concerns, mirroring the ticket's requirements:
///  1. JSON contract: `refinePreset`/`refineCustomPrompt` are ADDITIVE optional
///     fields on `AppProfile`; a pre-MAK-77 profiles.json decodes with nil
///     (inherit) and round-trips unchanged.
///  2. Resolver: frontmost-app → profile → preset outcome, including the
///     bundled terminal/IDE verbatim default and the global-`.none` degrade.
///  3. Guard interplay: every preset prompt stays under the RefineOutputGuard
///     (conservative, same-language) — a translated output is still rejected.
final class RefinePresetTests: XCTestCase {

    // MARK: - (1) JSON contract (iOS companion)

    /// A profiles.json entry written BEFORE the preset fields existed must decode
    /// with both fields nil — "inherit the global setting".
    func testPreMAK77ProfileDecodesWithNilPreset() throws {
        let legacyJSON = """
        {
          "id": "6F9B25B4-9E75-4C2A-8E2B-0B2C6A6D9E01",
          "appBundleID": "com.tinyspeck.slackmacgap",
          "displayName": "Slack",
          "language": "en",
          "aiCleanupEnabled": true
        }
        """
        let profile = try JSONDecoder().decode(AppProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(profile.refinePreset, "missing field must decode as inherit")
        XCTAssertNil(profile.refineCustomPrompt)
        // Untouched legacy fields still decode.
        XCTAssertEqual(profile.appBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(profile.aiCleanupEnabled, true)
        // Unstamped legacy data keeps the epoch sentinel (v3 contract).
        XCTAssertEqual(profile.updatedAt, AppProfile.unstampedEpoch)
    }

    /// An old profile round-trips unchanged: encoding a profile with nil preset
    /// fields must NOT emit the new keys (additive contract — an old iOS build
    /// reading the file sees exactly the shape it always did).
    func testNilPresetFieldsAreOmittedOnEncode() throws {
        let profile = AppProfile(appBundleID: "com.apple.mail", displayName: "Mail")
        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["refinePreset"], "nil preset must be omitted, not null")
        XCTAssertNil(object["refineCustomPrompt"])
    }

    /// A profile WITH a preset + custom prompt round-trips losslessly.
    func testPresetFieldsRoundTrip() throws {
        let original = AppProfile(
            appBundleID: "com.tinyspeck.slackmacgap", displayName: "Slack",
            refinePreset: RefinePreset.custom.rawValue,
            refineCustomPrompt: "Clean up the text. Keep it short."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppProfile.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.refinePreset, "custom")
        XCTAssertEqual(decoded.refineCustomPrompt, "Clean up the text. Keep it short.")
    }

    /// An UNKNOWN future preset value (from a newer peer) decodes fine and
    /// resolves to inherit rather than failing — forward compatibility.
    func testUnknownPresetValueDegradesToInherit() throws {
        let json = """
        {"id":"6F9B25B4-9E75-4C2A-8E2B-0B2C6A6D9E02","appBundleID":"a.b.c",
         "displayName":"X","refinePreset":"hyperbolic-slang-3000"}
        """
        let profile = try JSONDecoder().decode(AppProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.refinePreset, "hyperbolic-slang-3000")
        let outcome = RefinePresetResolver.resolve(
            profile: profile, frontmostBundleID: "a.b.c",
            perAppProfilesEnabled: true, globalIntensity: .medium)
        XCTAssertEqual(outcome, .inherit)
    }

    // MARK: - (2) Resolver: app → preset

    private func profile(_ bundleID: String, preset: RefinePreset?, custom: String? = nil) -> AppProfile {
        AppProfile(appBundleID: bundleID, displayName: bundleID,
                   refinePreset: preset?.rawValue, refineCustomPrompt: custom)
    }

    func testCasualProfileYieldsCasualPrompt() {
        let outcome = RefinePresetResolver.resolve(
            profile: profile("com.tinyspeck.slackmacgap", preset: .casual),
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            perAppProfilesEnabled: true, globalIntensity: .medium)
        XCTAssertEqual(outcome, .prompt(RefinePreset.casual.sessionPrompt!))
    }

    func testFormalAndMinimalYieldTheirPrompts() {
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: profile("com.apple.mail", preset: .formal),
                frontmostBundleID: "com.apple.mail",
                perAppProfilesEnabled: true, globalIntensity: .low),
            .prompt(RefinePreset.formal.sessionPrompt!))
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: profile("com.apple.Notes", preset: .minimalCleanup),
                frontmostBundleID: "com.apple.Notes",
                perAppProfilesEnabled: true, globalIntensity: .high),
            .prompt(CleanupIntensity.systemPrompt(for: .low)!))
    }

    func testVerbatimProfileSkipsRefine() {
        let outcome = RefinePresetResolver.resolve(
            profile: profile("com.apple.mail", preset: .verbatim),
            frontmostBundleID: "com.apple.mail",
            perAppProfilesEnabled: true, globalIntensity: .medium)
        XCTAssertEqual(outcome, .verbatim)
    }

    func testCustomPresetUsesTheProfilePrompt() {
        let outcome = RefinePresetResolver.resolve(
            profile: profile("a.b.c", preset: .custom, custom: "  Tidy the text.  "),
            frontmostBundleID: "a.b.c",
            perAppProfilesEnabled: true, globalIntensity: .medium)
        XCTAssertEqual(outcome, .prompt("Tidy the text."))
    }

    func testCustomPresetWithEmptyPromptInherits() {
        let outcome = RefinePresetResolver.resolve(
            profile: profile("a.b.c", preset: .custom, custom: "   "),
            frontmostBundleID: "a.b.c",
            perAppProfilesEnabled: true, globalIntensity: .medium)
        XCTAssertEqual(outcome, .inherit)
    }

    /// A prompt-style preset only SHAPES a refine pass that's already running:
    /// global `.none` means the user turned cleanup off, and one app's tone
    /// preset must not silently switch the LLM back on.
    func testPromptPresetsDegradeToInheritWhenGlobalCleanupIsOff() {
        for preset: RefinePreset in [.minimalCleanup, .casual, .formal] {
            XCTAssertEqual(
                RefinePresetResolver.resolve(
                    profile: profile("a.b.c", preset: preset),
                    frontmostBundleID: "a.b.c",
                    perAppProfilesEnabled: true, globalIntensity: .none),
                .inherit, "\(preset) must not enable the LLM when global is off")
        }
        // Verbatim is a pure "off" and stays meaningful regardless.
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: profile("a.b.c", preset: .verbatim),
                frontmostBundleID: "a.b.c",
                perAppProfilesEnabled: true, globalIntensity: .none),
            .verbatim)
    }

    /// No profile, ordinary app → inherit.
    func testNoProfileOrdinaryAppInherits() {
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: nil, frontmostBundleID: "com.tinyspeck.slackmacgap",
                perAppProfilesEnabled: true, globalIntensity: .medium),
            .inherit)
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: nil, frontmostBundleID: nil,
                perAppProfilesEnabled: true, globalIntensity: .medium),
            .inherit)
    }

    // MARK: - Terminal/IDE verbatim default

    func testTerminalAndIDEAppsDefaultToVerbatimWithoutAProfile() {
        for bid in ["com.apple.Terminal", "com.googlecode.iterm2",
                    "com.microsoft.VSCode", "com.apple.dt.Xcode",
                    "com.jetbrains.intellij", "com.jetbrains.pycharm.ce",
                    "dev.zed.Zed", "com.mitchellh.ghostty"] {
            XCTAssertEqual(
                RefinePresetResolver.resolve(
                    profile: nil, frontmostBundleID: bid,
                    perAppProfilesEnabled: true, globalIntensity: .medium),
                .verbatim, "\(bid) should default to verbatim")
        }
    }

    /// The terminal default is a safety default for code contexts, applied even
    /// when the per-app profiles toggle is off.
    func testTerminalDefaultAppliesEvenWithPerAppProfilesDisabled() {
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: nil, frontmostBundleID: "com.apple.Terminal",
                perAppProfilesEnabled: false, globalIntensity: .medium),
            .verbatim)
    }

    /// An explicit profile preset OVERRIDES the terminal default (the user asked
    /// for it): casual-in-iTerm is honored when profiles are enabled.
    func testExplicitPresetOverridesTerminalDefault() {
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: profile("com.googlecode.iterm2", preset: .casual),
                frontmostBundleID: "com.googlecode.iterm2",
                perAppProfilesEnabled: true, globalIntensity: .medium),
            .prompt(RefinePreset.casual.sessionPrompt!))
    }

    /// With the toggle OFF, profile presets are inert and the terminal default
    /// still wins for terminal apps (documented toggle semantics).
    func testProfilePresetInertWhenToggleOff() {
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: profile("com.googlecode.iterm2", preset: .casual),
                frontmostBundleID: "com.googlecode.iterm2",
                perAppProfilesEnabled: false, globalIntensity: .medium),
            .verbatim)
        XCTAssertEqual(
            RefinePresetResolver.resolve(
                profile: profile("com.tinyspeck.slackmacgap", preset: .casual),
                frontmostBundleID: "com.tinyspeck.slackmacgap",
                perAppProfilesEnabled: false, globalIntensity: .medium),
            .inherit)
    }

    func testTerminalPolicyFailsOpenForUnknownAndNilBundleIDs() {
        XCTAssertFalse(TerminalAppPolicy.isVerbatimByDefault(bundleID: nil))
        XCTAssertFalse(TerminalAppPolicy.isVerbatimByDefault(bundleID: ""))
        XCTAssertFalse(TerminalAppPolicy.isVerbatimByDefault(bundleID: "com.apple.mail"))
    }

    // MARK: - (3) Guard interplay (PR #157 lesson)

    /// Every prompt-bearing preset stays CONSERVATIVE: it demands same-language
    /// output and carries the transform-only guardrails the CleanupIntensity
    /// prompts established for tiny local models.
    func testPresetPromptsKeepTheConservativeGuardrails() throws {
        for preset: RefinePreset in [.minimalCleanup, .casual, .formal] {
            let prompt = try XCTUnwrap(preset.sessionPrompt)
            XCTAssertTrue(prompt.contains("SAME language"),
                          "\(preset) prompt must demand same-language output")
            XCTAssertTrue(prompt.contains("Do NOT answer questions"),
                          "\(preset) prompt must forbid answering the text")
            XCTAssertTrue(prompt.contains("Output ONLY the cleaned text"),
                          "\(preset) prompt must forbid preamble/quoting")
        }
        XCTAssertNil(RefinePreset.verbatim.sessionPrompt)
        XCTAssertNil(RefinePreset.custom.sessionPrompt, "custom uses the profile's own prompt")
    }

    /// Preset sessions keep the language guard ACTIVE: unlike a Mode's free-form
    /// instruction (hasCustomModeInstruction exemption), a preset prompt is a
    /// same-language cleanup, so the guard machinery still rejects a drifted
    /// (translated) output for every preset.
    func testGuardStaysActiveAndRejectsTranslationForEveryPreset() {
        let russianInput = "привет команда, я сегодня болею и работаю из дома"
        let translatedOutput = "Hi team, I am sick today and working from home."
        let cleanedOutput = "Привет, команда! Я сегодня болею и работаю из дома."

        for preset in RefinePreset.allCases {
            // The session flag AppState passes for a preset-driven cleanup is
            // hasCustomModeInstruction=false — presets never exempt the guard.
            XCTAssertTrue(
                RefineOutputGuard.shouldLanguageGuard(
                    isSpokenInstructionRefine: false,
                    isAgentBridgeRefine: false,
                    hasCustomModeInstruction: false),
                "\(preset): guard must stay on for preset sessions")
            // And the guard's decision still catches a translation drift…
            XCTAssertTrue(
                RefineOutputGuard.outputTranslatedAway(
                    input: russianInput, output: translatedOutput),
                "\(preset): translated output must be rejected")
            // …while a legitimate same-language cleanup passes.
            XCTAssertFalse(
                RefineOutputGuard.outputTranslatedAway(
                    input: russianInput, output: cleanedOutput),
                "\(preset): same-language cleanup must pass")
        }
    }

    // MARK: - Session application (the apply step AppState performs)

    func testApplicationMapsOutcomesToSessionChanges() {
        XCTAssertEqual(
            RefinePresetResolver.application(outcome: .inherit, modePinsCleanupOn: false),
            .init(disableRefine: false, presetPrompt: nil))
        XCTAssertEqual(
            RefinePresetResolver.application(outcome: .verbatim, modePinsCleanupOn: false),
            .init(disableRefine: true, presetPrompt: nil))
        // An explicit Mode that pins AI cleanup ON beats the verbatim preset.
        XCTAssertEqual(
            RefinePresetResolver.application(outcome: .verbatim, modePinsCleanupOn: true),
            .init(disableRefine: false, presetPrompt: nil))
        XCTAssertEqual(
            RefinePresetResolver.application(outcome: .prompt("P"), modePinsCleanupOn: false),
            .init(disableRefine: false, presetPrompt: "P"))
    }

    // MARK: - Composer precedence (the funnel AppState feeds the refiner from)

    func testComposerPrecedenceModeThenPresetThenDial() {
        XCTAssertEqual(
            RefineInstructionComposer.baseInstruction(
                modeOverride: "MODE", presetOverride: "PRESET", dialInstruction: "DIAL"),
            "MODE")
        XCTAssertEqual(
            RefineInstructionComposer.baseInstruction(
                modeOverride: nil, presetOverride: "PRESET", dialInstruction: "DIAL"),
            "PRESET")
        XCTAssertEqual(
            RefineInstructionComposer.baseInstruction(
                modeOverride: nil, presetOverride: nil, dialInstruction: "DIAL"),
            "DIAL")
        XCTAssertNil(RefineInstructionComposer.baseInstruction(
            modeOverride: nil, presetOverride: nil, dialInstruction: nil))
    }
}
