import XCTest
@testable import OpenWhispCore

/// Tests for the pure retention-policy logic (MAK-40): the filename-scheme guard
/// that keeps the disk sweep from ever touching a non-app file, and the sweep
/// decision (age cap deletes whole entries; count cap prunes only surplus audio).
/// No AppKit, no disk — the sweep takes an injected `now`.
final class AudioRetentionPolicyTests: XCTestCase {

    // MARK: - Filename scheme (the delete guard)

    func testFileNameRoundTrips() {
        let id = UUID()
        let name = AudioRetentionPolicy.fileName(for: id, ext: "wav")
        XCTAssertEqual(name, "retained-\(id.uuidString).wav")
        XCTAssertTrue(AudioRetentionPolicy.isRetainedAudioFileName(name))
        XCTAssertEqual(AudioRetentionPolicy.parseEntryID(fromFileName: name), id)
    }

    func testFileNameAcceptsM4A() {
        let id = UUID()
        let name = AudioRetentionPolicy.fileName(for: id, ext: "M4A") // case-insensitive
        XCTAssertEqual(name, "retained-\(id.uuidString).m4a")
        XCTAssertEqual(AudioRetentionPolicy.parseEntryID(fromFileName: name), id)
    }

    func testRejectsForeignFilenames() {
        // The sweep must never delete files it didn't create.
        XCTAssertFalse(AudioRetentionPolicy.isRetainedAudioFileName("history.json"))
        XCTAssertFalse(AudioRetentionPolicy.isRetainedAudioFileName("recording_123.wav"))
        XCTAssertFalse(AudioRetentionPolicy.isRetainedAudioFileName("chunk_0_123.wav"))
        // Right prefix, but not a valid UUID → reject.
        XCTAssertFalse(AudioRetentionPolicy.isRetainedAudioFileName("retained-not-a-uuid.wav"))
        // Right prefix + UUID, but a disallowed extension → reject.
        XCTAssertFalse(AudioRetentionPolicy.isRetainedAudioFileName("retained-\(UUID().uuidString).sh"))
        // A traversal-ish name must not sneak past (prefix check + UUID parse fail).
        XCTAssertFalse(AudioRetentionPolicy.isRetainedAudioFileName("retained-../../etc/passwd.wav"))
        XCTAssertNil(AudioRetentionPolicy.parseEntryID(fromFileName: "history.json"))
    }

    // MARK: - Disabled → never deletes

    func testDisabledYieldsEmptySweep() {
        let c = [AudioRetentionPolicy.Candidate(id: UUID(), date: Date(), hasAudio: true)]
        let settings = AudioRetentionSettings(enabled: false, maxAgeDays: 1, maxEntries: 1)
        let sweep = AudioRetentionPolicy.evaluate(candidates: c, settings: settings, now: Date())
        XCTAssertTrue(sweep.isEmpty)
    }

    // MARK: - Age cap deletes whole entries (audio + history)

    func testAgeCapDeletesOldEntriesEntirely() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-1 * 86_400), hasAudio: true)
        let old = AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-10 * 86_400), hasAudio: true)
        let settings = AudioRetentionSettings(enabled: true, maxAgeDays: 7, maxEntries: 0)
        let sweep = AudioRetentionPolicy.evaluate(candidates: [fresh, old], settings: settings, now: now)
        XCTAssertEqual(sweep.entriesToDelete, [old.id])
        XCTAssertEqual(sweep.audioToDelete, [old.id])
        XCTAssertFalse(sweep.entriesToDelete.contains(fresh.id))
    }

    func testAgeCapDropsTextOnlyOldEntryButNoAudioDelete() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldNoAudio = AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-30 * 86_400), hasAudio: false)
        let settings = AudioRetentionSettings(enabled: true, maxAgeDays: 7, maxEntries: 0)
        let sweep = AudioRetentionPolicy.evaluate(candidates: [oldNoAudio], settings: settings, now: now)
        XCTAssertEqual(sweep.entriesToDelete, [oldNoAudio.id])
        XCTAssertTrue(sweep.audioToDelete.isEmpty)
    }

    // MARK: - Count cap prunes only surplus audio, keeps text

    func testCountCapKeepsNewestNClips() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Five audio clips, newest first by date.
        let clips = (0..<5).map {
            AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-Double($0) * 3_600), hasAudio: true)
        }
        let settings = AudioRetentionSettings(enabled: true, maxAgeDays: 0, maxEntries: 2)
        let sweep = AudioRetentionPolicy.evaluate(candidates: clips, settings: settings, now: now)
        // Newest 2 kept; oldest 3 have audio pruned; no whole-entry deletion.
        XCTAssertEqual(sweep.audioToDelete, Set(clips[2...].map { $0.id }))
        XCTAssertTrue(sweep.entriesToDelete.isEmpty)
        XCTAssertFalse(sweep.audioToDelete.contains(clips[0].id))
        XCTAssertFalse(sweep.audioToDelete.contains(clips[1].id))
    }

    func testCountCapIgnoresTextOnlyEntries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let audio = (0..<2).map { AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-Double($0)), hasAudio: true) }
        let textOnly = (0..<5).map { AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-Double($0)), hasAudio: false) }
        let settings = AudioRetentionSettings(enabled: true, maxAgeDays: 0, maxEntries: 3)
        let sweep = AudioRetentionPolicy.evaluate(candidates: audio + textOnly, settings: settings, now: now)
        // Only 2 clips, cap is 3 → nothing pruned; text-only entries never counted.
        XCTAssertTrue(sweep.isEmpty)
    }

    // MARK: - Caps compose

    func testAgeAndCountCapsCompose() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-30 * 86_400), hasAudio: true)
        let recent = (0..<4).map {
            AudioRetentionPolicy.Candidate(id: UUID(), date: now.addingTimeInterval(-Double($0) * 3_600), hasAudio: true)
        }
        let settings = AudioRetentionSettings(enabled: true, maxAgeDays: 7, maxEntries: 2)
        let sweep = AudioRetentionPolicy.evaluate(candidates: [old] + recent, settings: settings, now: now)
        // `old` deleted entirely; among the 4 recent, newest 2 kept, oldest 2 audio pruned.
        XCTAssertEqual(sweep.entriesToDelete, [old.id])
        XCTAssertTrue(sweep.audioToDelete.contains(old.id))
        XCTAssertTrue(sweep.audioToDelete.contains(recent[2].id))
        XCTAssertTrue(sweep.audioToDelete.contains(recent[3].id))
        XCTAssertFalse(sweep.audioToDelete.contains(recent[0].id))
        XCTAssertFalse(sweep.audioToDelete.contains(recent[1].id))
    }

    // MARK: - Settings decode tolerance

    func testSettingsDecodesPartialBlobWithDefaults() throws {
        let json = Data(#"{"enabled":true}"#.utf8)
        let s = try JSONDecoder().decode(AudioRetentionSettings.self, from: json)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.maxAgeDays, 0)
        XCTAssertEqual(s.maxEntries, 50)
    }
}
