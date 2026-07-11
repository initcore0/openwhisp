import XCTest
@testable import OpenWhispCore

/// Tests for the `Meeting` model (Codable round-trip, forward-compat decode, status
/// coding) and `MeetingSessionStore` (upsert/delete persistence, corrupt-file
/// quarantine, leaf-guard WAV deletion). MAK-50.
final class MeetingStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    private func store() -> MeetingSessionStore { MeetingSessionStore(baseDirectory: dir) }

    // MARK: - Model

    func testCodableRoundTrip() throws {
        let m = Meeting(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 123, wavFileName: "meeting-x.wav",
            transcript: "hello world", summary: "## Summary\nHi", status: .done
        )
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(Meeting.self, from: data)
        XCTAssertEqual(m, back)
    }

    func testFailedStatusRoundTripKeepsReason() throws {
        let m = Meeting(status: .failed(reason: "boom"))
        let back = try JSONDecoder().decode(Meeting.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back.status, .failed(reason: "boom"))
    }

    func testForwardCompatUnknownStatusDecodesToFailed() throws {
        // A record written by a newer build with a status this build doesn't know.
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":0,"duration":0,"status":{"kind":"archived"}}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(Meeting.self, from: json)
        if case .failed = m.status { /* ok */ } else { XCTFail("expected .failed for unknown status") }
    }

    func testForwardCompatExtraFieldsIgnored() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":0,"duration":5,"status":{"kind":"recorded"},"futureField":true}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(Meeting.self, from: json)
        XCTAssertEqual(m.status, .recorded)
        XCTAssertEqual(m.duration, 5)
    }

    func testMissingOptionalsDecodeToNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":0,"duration":0,"status":{"kind":"recorded"}}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(Meeting.self, from: json)
        XCTAssertNil(m.transcript)
        XCTAssertNil(m.summary)
        XCTAssertNil(m.wavFileName)
    }

    // MARK: - WAV leaf guard

    func testWAVNameGuard() {
        XCTAssertTrue(MeetingWAVName.isValid("meeting-abc.wav"))
        XCTAssertFalse(MeetingWAVName.isValid("../escape.wav"))
        XCTAssertFalse(MeetingWAVName.isValid("dir/meeting.wav"))
        XCTAssertFalse(MeetingWAVName.isValid("meeting.txt"))
        XCTAssertFalse(MeetingWAVName.isValid(""))
        XCTAssertFalse(MeetingWAVName.isValid("bad\0.wav"))
    }

    // MARK: - Store

    func testUpsertAndLoadNewestFirst() {
        let s = store()
        let older = Meeting(startedAt: Date(timeIntervalSince1970: 100))
        let newer = Meeting(startedAt: Date(timeIntervalSince1970: 200))
        s.upsert(older)
        let all = s.upsert(newer)
        XCTAssertEqual(all.map(\.id), [newer.id, older.id])
        XCTAssertEqual(s.load().first?.id, newer.id)
    }

    func testUpsertReplacesByID() {
        let s = store()
        var m = Meeting(status: .recorded)
        s.upsert(m)
        m.status = .done
        m.transcript = "done text"
        let all = s.upsert(m)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.status, .done)
        XCTAssertEqual(all.first?.transcript, "done text")
    }

    func testDeleteRemovesRecordAndWAV() throws {
        let s = store()
        let id = UUID()
        let name = MeetingWAVName.fileName(for: id)
        try FileManager.default.createDirectory(at: s.audioDirectory, withIntermediateDirectories: true)
        let wav = s.audioDirectory.appendingPathComponent(name)
        try Data([0x1]).write(to: wav)
        s.upsert(Meeting(id: id, wavFileName: name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))

        let remaining = s.delete(id: id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    }

    func testCorruptFileQuarantined() throws {
        let s = store()
        let fileURL = dir.appendingPathComponent("meetings.json")
        try Data("{ not json".utf8).write(to: fileURL)
        // Load must not crash and returns empty; the bad file is moved aside.
        XCTAssertTrue(s.load().isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.contains("meetings.json.corrupt-") })
    }

    func testWAVURLRejectsUnsafeName() {
        let s = store()
        let bad = Meeting(wavFileName: "../evil.wav")
        XCTAssertNil(s.wavURL(for: bad))
        let good = Meeting(wavFileName: "meeting-ok.wav")
        XCTAssertEqual(s.wavURL(for: good)?.lastPathComponent, "meeting-ok.wav")
    }
}
