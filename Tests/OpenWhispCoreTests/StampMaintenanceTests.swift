import XCTest
@testable import OpenWhispCore

/// The wiring-lesson guard for MAK-51 WP0b: every USER mutation path must advance
/// the entry's `updatedAt`, or sync's last-writer-wins silently keeps stale data.
/// These tests pin the pure edit helpers the AppState editors (CleanupPane /
/// ProfilesPane / ModesPane) route through — one test per mutation path proving
/// the stamp advanced (edit) or the entry was added stamped / removed.
final class StampMaintenanceTests: XCTestCase {

    private let past = Date(timeIntervalSince1970: 1_000)
    private let now = Date(timeIntervalSince1970: 2_000)

    // MARK: Vocabulary.Substitution

    func testAddingSubstitutionStampsNow() {
        // Even a substitution whose own updatedAt was stale gets re-stamped on add.
        let stale = Vocabulary.Substitution(from: "a", to: "b", updatedAt: past)
        let vocab = Vocabulary(terms: [], substitutions: []).addingSubstitution(stale, now: now)
        XCTAssertEqual(vocab.substitutions.count, 1)
        XCTAssertEqual(vocab.substitutions.first?.updatedAt, now)
    }

    func testEditingSubstitutionFieldAdvancesStamp() {
        let sub = Vocabulary.Substitution(from: "clod", to: "cloud", updatedAt: past)
        let vocab = Vocabulary(terms: [], substitutions: [sub])
        let edited = vocab.editingSubstitution(sub.id, now: now) { $0.to = "Claude" }
        XCTAssertEqual(edited.substitutions.first?.to, "Claude")
        XCTAssertEqual(edited.substitutions.first?.updatedAt, now)
        XCTAssertGreaterThan(edited.substitutions.first!.updatedAt, past)
    }

    func testEditingSubstitutionStarredAdvancesStamp() {
        let sub = Vocabulary.Substitution(from: "a", to: "b", starred: false, updatedAt: past)
        let vocab = Vocabulary(terms: [], substitutions: [sub])
        let edited = vocab.editingSubstitution(sub.id, now: now) { $0.starred.toggle() }
        XCTAssertTrue(edited.substitutions.first!.starred)
        XCTAssertEqual(edited.substitutions.first?.updatedAt, now)
    }

    func testEditingUnknownSubstitutionIsNoOp() {
        let sub = Vocabulary.Substitution(from: "a", to: "b", updatedAt: past)
        let vocab = Vocabulary(terms: [], substitutions: [sub])
        let out = vocab.editingSubstitution(UUID(), now: now) { $0.to = "x" }
        XCTAssertEqual(out, vocab)  // untouched, stamp not advanced
    }

    func testRemovingSubstitution() {
        let a = Vocabulary.Substitution(from: "a", to: "1")
        let b = Vocabulary.Substitution(from: "b", to: "2")
        let vocab = Vocabulary(terms: [], substitutions: [a, b]).removingSubstitution(a.id)
        XCTAssertEqual(vocab.substitutions.map(\.id), [b.id])
    }

    func testUsageBumpDoesNotAdvanceStamp() {
        // A machine-driven usage bump must NOT restamp — else a passive dictation
        // would win the merge over a real remote edit.
        let sub = Vocabulary.Substitution(from: "a", to: "b", updatedAt: past)
        let vocab = Vocabulary(terms: [], substitutions: [sub])
        let bumped = vocab.incrementingUsage(of: sub.id)
        XCTAssertEqual(bumped.substitutions.first?.usageCount, 1)
        XCTAssertEqual(bumped.substitutions.first?.updatedAt, past)  // unchanged
    }

    // MARK: AppProfile

    func testAddingProfileStampsNow() {
        let stale = AppProfile(appBundleID: "com.x", displayName: "X", updatedAt: past)
        let profiles = [AppProfile]().addingProfile(stale, now: now)
        XCTAssertEqual(profiles.first?.updatedAt, now)
    }

    func testEditingProfileAdvancesStamp() {
        let p = AppProfile(appBundleID: "com.x", displayName: "X", updatedAt: past)
        let edited = [p].editingProfile(p.id, now: now) { $0.language = "en" }
        XCTAssertEqual(edited.first?.language, "en")
        XCTAssertEqual(edited.first?.updatedAt, now)
    }

    func testEditingUnknownProfileIsNoOp() {
        let p = AppProfile(appBundleID: "com.x", displayName: "X", updatedAt: past)
        let out = [p].editingProfile(UUID(), now: now) { $0.language = "en" }
        XCTAssertEqual(out, [p])
    }

    func testRemovingProfile() {
        let a = AppProfile(appBundleID: "a", displayName: "A")
        let b = AppProfile(appBundleID: "b", displayName: "B")
        XCTAssertEqual([a, b].removingProfile(a.id).map(\.id), [b.id])
    }

    // MARK: Mode

    func testAddingModeStampsNow() {
        let stale = Mode(key: "k", name: "K", updatedAt: past)
        let modes = [Mode]().addingMode(stale, now: now)
        XCTAssertEqual(modes.first?.updatedAt, now)
    }

    func testEditingModeAdvancesStamp() {
        let m = Mode(key: "k", name: "K", updatedAt: past)
        let edited = [m].editingMode(m.id, now: now) { $0.name = "Kite" }
        XCTAssertEqual(edited.first?.name, "Kite")
        XCTAssertEqual(edited.first?.updatedAt, now)
    }

    func testEditingUnknownModeIsNoOp() {
        let m = Mode(key: "k", name: "K", updatedAt: past)
        let out = [m].editingMode(UUID(), now: now) { $0.name = "X" }
        XCTAssertEqual(out, [m])
    }

    func testRemovingMode() {
        let a = Mode(key: "a", name: "A")
        let b = Mode(key: "b", name: "B")
        XCTAssertEqual([a, b].removingMode(a.id).map(\.id), [b.id])
    }

    // MARK: stamped(_:) helpers

    func testStampedHelpersSetExactDate() {
        XCTAssertEqual(Vocabulary.Substitution(from: "a", to: "b").stamped(now).updatedAt, now)
        XCTAssertEqual(AppProfile(appBundleID: "x", displayName: "X").stamped(now).updatedAt, now)
        XCTAssertEqual(Mode(key: "k", name: "K").stamped(now).updatedAt, now)
    }
}
