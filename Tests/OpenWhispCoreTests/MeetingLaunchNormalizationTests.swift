import XCTest
@testable import OpenWhispCore

/// `MeetingStatus.normalizedForLaunch`: a persisted mid-work stage found at launch
/// means the app died mid-work — it must roll back to its resting predecessor so
/// the list doesn't show a permanent spinner over work nobody is doing, and the
/// work can simply be rerun. Resting/terminal stages pass through unchanged.
final class MeetingLaunchNormalizationTests: XCTestCase {

    func testTranscribingRollsBackToRecorded() {
        XCTAssertEqual(MeetingStatus.transcribing.normalizedForLaunch, .recorded)
    }

    func testSummarizingRollsBackToTranscribed() {
        XCTAssertEqual(MeetingStatus.summarizing.normalizedForLaunch, .transcribed)
    }

    func testRestingAndTerminalStagesAreUnchanged() {
        XCTAssertEqual(MeetingStatus.recorded.normalizedForLaunch, .recorded)
        XCTAssertEqual(MeetingStatus.transcribed.normalizedForLaunch, .transcribed)
        XCTAssertEqual(MeetingStatus.done.normalizedForLaunch, .done)
        XCTAssertEqual(MeetingStatus.failed(reason: "boom").normalizedForLaunch,
                       .failed(reason: "boom"),
                       "failure reason must survive normalization")
    }

    /// Store round-trip of the launch sweep the coordinator performs: a meeting
    /// persisted as `.transcribing` (crash mid-transcription) is normalized and
    /// re-persisted as `.recorded`, ready for auto-transcribe to rerun.
    func testPersistedMidWorkMeetingNormalizesThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingLaunchNorm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MeetingSessionStore(baseDirectory: dir)
        let stuck = Meeting(wavFileName: MeetingWAVName.fileName(for: UUID()), status: .transcribing)
        let doneMeeting = Meeting(status: .done)
        store.upsert(stuck)
        store.upsert(doneMeeting)

        // The coordinator's init sweep, replicated over the core seams.
        var loaded = store.load()
        for i in loaded.indices where loaded[i].status.normalizedForLaunch != loaded[i].status {
            loaded[i].status = loaded[i].status.normalizedForLaunch
            store.upsert(loaded[i])
        }

        let after = store.load()
        XCTAssertEqual(after.first { $0.id == stuck.id }?.status, .recorded)
        XCTAssertEqual(after.first { $0.id == doneMeeting.id }?.status, .done)
    }
}
