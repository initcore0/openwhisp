import XCTest
@testable import OpenWhispCore

/// ConfigBundle schema v3 (MAK-51 WP0b): `updatedAt` stamps on
/// `Vocabulary.Substitution`, `AppProfile`, and `Mode`, with a v2 decode fallback
/// to the epoch (so unstamped legacy data always loses the sync last-writer-wins
/// race) and the preserved reject-a-future-schema behavior.
final class ConfigBundleV3StampTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 0)

    // MARK: currentSchemaVersion bumped to 3

    func testCurrentSchemaVersionIsThree() {
        XCTAssertEqual(ConfigBundle.currentSchemaVersion, 3)
    }

    // MARK: v2 decode fallback — missing updatedAt → epoch

    func testSubstitutionWithoutUpdatedAtDecodesAsEpoch() throws {
        // A v2 substitution JSON (no updatedAt key at all).
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","from":"clod","to":"Claude"}"#
        let sub = try JSONDecoder().decode(Vocabulary.Substitution.self, from: Data(json.utf8))
        XCTAssertEqual(sub.updatedAt, epoch)
    }

    func testProfileWithoutUpdatedAtDecodesAsEpoch() throws {
        let json = #"{"id":"22222222-2222-2222-2222-222222222222","appBundleID":"com.apple.mail","displayName":"Mail"}"#
        let profile = try JSONDecoder().decode(AppProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.updatedAt, epoch)
    }

    func testModeWithoutUpdatedAtDecodesAsEpoch() throws {
        let json = #"{"id":"33333333-3333-3333-3333-333333333333","key":"email","name":"Email"}"#
        let mode = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        XCTAssertEqual(mode.updatedAt, epoch)
    }

    func testWholeV2BundleDecodesWithEpochStamps() throws {
        // A hand-written v2 bundle: schemaVersion 2, no updatedAt anywhere.
        let json = """
        {
          "schemaVersion": 2,
          "vocabulary": { "terms": ["x"], "substitutions": [
            {"id":"44444444-4444-4444-4444-444444444444","from":"a","to":"b"}
          ]},
          "profiles": [
            {"id":"55555555-5555-5555-5555-555555555555","appBundleID":"com.x","displayName":"X"}
          ],
          "modes": [
            {"id":"66666666-6666-6666-6666-666666666666","key":"k","name":"K"}
          ]
        }
        """
        let bundle = try ConfigBundle.decode(from: Data(json.utf8))
        XCTAssertEqual(bundle.schemaVersion, 2)  // preserved, not rewritten
        XCTAssertEqual(bundle.vocabulary?.substitutions.first?.updatedAt, epoch)
        XCTAssertEqual(bundle.profiles?.first?.updatedAt, epoch)
        XCTAssertEqual(bundle.modes?.first?.updatedAt, epoch)
    }

    // MARK: epoch-stamped v2 data always loses LWW to any stamped v3 edit

    func testEpochStampLosesToAnyStampedEdit() {
        let legacy = Vocabulary.Substitution(from: "a", to: "old", updatedAt: epoch)
        let edited = legacy.stamped(Date(timeIntervalSince1970: 1))  // one second after epoch
        XCTAssertGreaterThan(edited.updatedAt, legacy.updatedAt)
    }

    // MARK: round-trip preserves stamps (v3 encode always includes updatedAt)

    func testV3EncodeIncludesUpdatedAt() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sub = Vocabulary.Substitution(from: "a", to: "b", updatedAt: stamp)
        let data = try JSONEncoder().encode(sub)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("updatedAt"), "v3 must always encode updatedAt, got: \(text)")
    }

    func testStampedTypesRoundTripThroughBundle() throws {
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)
        let bundle = ConfigBundle(
            profiles: [AppProfile(appBundleID: "com.x", displayName: "X", updatedAt: stamp)],
            modes: [Mode(key: "k", name: "K", updatedAt: stamp)],
            vocabulary: Vocabulary(terms: [], substitutions: [
                Vocabulary.Substitution(from: "a", to: "b", updatedAt: stamp)
            ])
        )
        let data = try bundle.jsonData()
        let back = try ConfigBundle.decode(from: data)
        let subStamp = try XCTUnwrap(back.vocabulary?.substitutions.first?.updatedAt)
        let profStamp = try XCTUnwrap(back.profiles?.first?.updatedAt)
        let modeStamp = try XCTUnwrap(back.modes?.first?.updatedAt)
        XCTAssertEqual(subStamp.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(profStamp.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(modeStamp.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: reject-from-the-future preserved (v3 app rejects v4 bundle)

    func testV4BundleRejected() {
        let json = #"{"schemaVersion": 4}"#
        XCTAssertThrowsError(try ConfigBundle.decode(from: Data(json.utf8))) { error in
            guard case ConfigBundle.DecodeError.unsupportedVersion(let found, let supported) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(found, 4)
            XCTAssertEqual(supported, 3)
        }
    }

    func testV3BundleAccepted() throws {
        let json = #"{"schemaVersion": 3}"#
        let bundle = try ConfigBundle.decode(from: Data(json.utf8))
        XCTAssertEqual(bundle.schemaVersion, 3)
    }
}
