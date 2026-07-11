import XCTest
@testable import OpenWhispCore

/// MAK-52: crash-recovery name parsing + leg grouping (`MeetingOrphanScan`).
final class MeetingOrphanScanTests: XCTestCase {

    private let id = UUID()

    func testParsesMixedMicAndSystem() {
        let mixed = "meeting_1700000000_\(id.uuidString).wav"
        let mic = "meeting_1700000000_\(id.uuidString)_mic.wav"
        let sys = "meeting_1700000000_\(id.uuidString)_sys.wav"
        XCTAssertEqual(MeetingOrphanScan.parse(mixed)?.kind, .mixed)
        XCTAssertEqual(MeetingOrphanScan.parse(mic)?.kind, .mic)
        XCTAssertEqual(MeetingOrphanScan.parse(sys)?.kind, .system)
        XCTAssertEqual(MeetingOrphanScan.parse(mixed)?.id, id)
        XCTAssertEqual(MeetingOrphanScan.parse(mixed)?.stamp, 1_700_000_000)
    }

    func testRejectsNonMeetingNames() {
        XCTAssertNil(MeetingOrphanScan.parse("notes.wav"))
        XCTAssertNil(MeetingOrphanScan.parse("meeting_abc_\(id.uuidString).wav"))   // bad stamp
        XCTAssertNil(MeetingOrphanScan.parse("meeting_1700000000_not-a-uuid.wav"))
        XCTAssertNil(MeetingOrphanScan.parse("meeting-\(id.uuidString).wav"))       // canonical (already ingested)
    }

    func testGroupsLegsWithTheirMixedRecording() {
        let names = [
            "meeting_1700000000_\(id.uuidString).wav",
            "meeting_1700000000_\(id.uuidString)_mic.wav",
            "meeting_1700000000_\(id.uuidString)_sys.wav",
            "unrelated.txt",
        ]
        let groups = MeetingOrphanScan.group(names)
        XCTAssertEqual(groups.count, 1)
        let g = try? XCTUnwrap(groups.first)
        XCTAssertEqual(g?.id, id)
        XCTAssertNotNil(g?.mixed)
        XCTAssertNotNil(g?.mic)
        XCTAssertNotNil(g?.system)
    }

    func testGroupsLegOnlyRecording() {
        // A leg survived but the mixed WAV didn't — still one group (no audio lost).
        let names = ["meeting_1700000000_\(id.uuidString)_mic.wav"]
        let groups = MeetingOrphanScan.group(names)
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups.first?.mixed)
        XCTAssertEqual(groups.first?.mic, names[0])
    }

    func testTwoDistinctMeetingsGroupSeparately() {
        let other = UUID()
        let names = [
            "meeting_100_\(id.uuidString).wav",
            "meeting_200_\(other.uuidString).wav",
        ]
        XCTAssertEqual(Set(MeetingOrphanScan.group(names).map(\.id)), [id, other])
    }
}
