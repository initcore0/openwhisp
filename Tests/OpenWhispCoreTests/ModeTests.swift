import XCTest
@testable import OpenWhispCore

/// Unit tests for first-class Modes (MAK-39): key normalization/lookup, activation
/// precedence vs. app auto-activation, tone → instruction composition, the
/// AppProfile bridge, and ConfigBundle round-trip (export/import + packs).
final class ModeTests: XCTestCase {

    // MARK: Key normalization

    func testKeyNormalization() {
        XCTAssertEqual(Mode.normalizeKey("Email Reply"), "email-reply")
        XCTAssertEqual(Mode.normalizeKey("  Legal   Brief "), "legal-brief")
        XCTAssertEqual(Mode.normalizeKey("chat"), "chat")
        XCTAssertEqual(Mode.normalizeKey("ALREADY-hyphen"), "already-hyphen")
    }

    func testInitNormalizesKey() {
        let m = Mode(key: "Email Reply", name: "Email Reply")
        XCTAssertEqual(m.key, "email-reply")
    }

    // MARK: Key lookup

    func testModeLookupByKeyIsNormalized() {
        let modes = [
            Mode(key: "email-reply", name: "Email"),
            Mode(key: "legal", name: "Legal")
        ]
        XCTAssertEqual(ModeResolver.mode(forKey: "Email Reply", in: modes)?.name, "Email")
        XCTAssertEqual(ModeResolver.mode(forKey: "LEGAL", in: modes)?.name, "Legal")
        XCTAssertNil(ModeResolver.mode(forKey: "nope", in: modes))
    }

    // MARK: Activation precedence

    func testExplicitKeyBeatsAppAutoActivation() {
        let email = Mode(key: "email", name: "Email")
        let slackMode = Mode(key: "slack", name: "Slack", appBundleID: "com.tinyspeck.slackmacgap")
        let modes = [email, slackMode]

        // Frontmost app is Slack, but the user explicitly invoked "email".
        let resolved = ModeResolver.resolveActive(
            explicitKey: "email",
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            perAppModesEnabled: true,
            modes: modes
        )
        XCTAssertEqual(resolved?.key, "email")
    }

    func testAppAutoActivationWhenNoExplicitKey() {
        let slackMode = Mode(key: "slack", name: "Slack", appBundleID: "com.tinyspeck.slackmacgap")
        let resolved = ModeResolver.resolveActive(
            explicitKey: nil,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            perAppModesEnabled: true,
            modes: [slackMode]
        )
        XCTAssertEqual(resolved?.key, "slack")
    }

    func testAutoActivationSuppressedWhenPerAppModesOff() {
        let slackMode = Mode(key: "slack", name: "Slack", appBundleID: "com.tinyspeck.slackmacgap")
        XCTAssertNil(ModeResolver.resolveActive(
            explicitKey: nil,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            perAppModesEnabled: false,
            modes: [slackMode]
        ))
    }

    func testUnknownExplicitKeyFallsBackToAutoActivation() {
        let slackMode = Mode(key: "slack", name: "Slack", appBundleID: "com.tinyspeck.slackmacgap")
        let resolved = ModeResolver.resolveActive(
            explicitKey: "does-not-exist",
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            perAppModesEnabled: true,
            modes: [slackMode]
        )
        XCTAssertEqual(resolved?.key, "slack")
    }

    func testNoModeResolvesToNil() {
        XCTAssertNil(ModeResolver.resolveActive(
            explicitKey: nil, frontmostBundleID: "com.unknown.app",
            perAppModesEnabled: true, modes: []))
    }

    // MARK: Tone → instruction composition

    func testToneOnlyProducesDirective() {
        let m = Mode(key: "legal", name: "Legal", tone: .legal)
        let instruction = ModeResolver.refineInstruction(for: m)
        XCTAssertEqual(instruction, Tone.legal.directive)
    }

    func testInstructionOnlyProducesInstruction() {
        let m = Mode(key: "x", name: "X", instruction: "Use British spelling.")
        XCTAssertEqual(ModeResolver.refineInstruction(for: m), "Use British spelling.")
    }

    func testToneAndInstructionComposeToneFirst() {
        let m = Mode(key: "x", name: "X", instruction: "Sign off with 'Best'.", tone: .formal)
        let composed = ModeResolver.refineInstruction(for: m)
        XCTAssertNotNil(composed)
        XCTAssertTrue(composed!.hasPrefix(Tone.formal.directive))
        XCTAssertTrue(composed!.hasSuffix("Sign off with 'Best'."))
        XCTAssertTrue(composed!.contains("\n\n"))
    }

    func testNoToneNoInstructionInheritsGlobal() {
        let m = Mode(key: "x", name: "X")
        XCTAssertNil(ModeResolver.refineInstruction(for: m))
    }

    func testWhitespaceOnlyInstructionIgnored() {
        let m = Mode(key: "x", name: "X", instruction: "   \n ", tone: .casual)
        XCTAssertEqual(ModeResolver.refineInstruction(for: m), Tone.casual.directive)
    }

    func testEveryToneHasNonEmptyDirective() {
        for tone in Tone.allCases {
            XCTAssertFalse(tone.directive.isEmpty, "\(tone) directive empty")
            XCTAssertFalse(tone.label.isEmpty)
            XCTAssertFalse(tone.defaultIcon.isEmpty)
        }
    }

    // MARK: AppProfile bridge

    func testModeFromProfileRoundTrips() {
        let profile = AppProfile(appBundleID: "com.apple.mail", displayName: "Mail",
                                 language: "en", outputMode: "preview", aiCleanupEnabled: true)
        let mode = Mode(fromProfile: profile)
        XCTAssertEqual(mode.appBundleID, "com.apple.mail")
        XCTAssertEqual(mode.name, "Mail")
        XCTAssertEqual(mode.key, "mail")
        XCTAssertEqual(mode.language, "en")
        XCTAssertEqual(mode.outputMode, "preview")
        XCTAssertEqual(mode.aiCleanupEnabled, true)

        let back = mode.asAppProfile
        XCTAssertEqual(back, profile)
    }

    func testAsAppProfileNilWithoutBinding() {
        let m = Mode(key: "email", name: "Email")
        XCTAssertNil(m.asAppProfile)
    }

    // MARK: ConfigBundle round-trip (export/import + packs)

    func testConfigBundleCarriesModes() throws {
        let modes = [
            Mode(key: "email", name: "Email", iconSymbol: "envelope",
                 instruction: "Be concise.", tone: .formal,
                 language: "en", outputMode: "finalOnly", aiCleanupEnabled: true,
                 appBundleID: "com.apple.mail"),
            Mode(key: "chat", name: "Chat", tone: .chat)
        ]
        let bundle = ConfigBundle(modes: modes)
        XCTAssertEqual(bundle.schemaVersion, ConfigBundle.currentSchemaVersion)
        let decoded = try ConfigBundle.decode(from: bundle.jsonData())
        XCTAssertEqual(decoded.modes, modes)
        XCTAssertNil(decoded.profiles)
        XCTAssertNil(decoded.vocabulary)
    }

    func testV1BundleWithoutModesStillDecodes() throws {
        // A v1 bundle (profiles-only, no modes key) must still decode tolerantly.
        let json = #"{"schemaVersion":1,"profiles":[{"id":"\#(UUID().uuidString)","appBundleID":"com.apple.mail","displayName":"Mail"}]}"#
        let decoded = try ConfigBundle.decode(from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.modes)
        XCTAssertEqual(decoded.profiles?.count, 1)
    }

    func testFutureSchemaRejected() {
        let json = #"{"schemaVersion":99}"#
        XCTAssertThrowsError(try ConfigBundle.decode(from: Data(json.utf8))) { error in
            guard case ConfigBundle.DecodeError.unsupportedVersion(let found, let supported) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, ConfigBundle.currentSchemaVersion)
        }
    }

    func testSummaryIncludesModeCount() {
        let bundle = ConfigBundle(modes: [Mode(key: "a", name: "A"), Mode(key: "b", name: "B")])
        XCTAssertTrue(bundle.summary.contains("2 modes"))
    }
}
