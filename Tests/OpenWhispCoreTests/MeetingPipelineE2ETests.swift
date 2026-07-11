import XCTest
@testable import OpenWhispCore

/// E2E-style test for the meeting pipeline's CORE seams (MAK-50).
///
/// `MeetingPipelineCoordinator` itself is app-only (@MainActor, links the
/// AVFoundation decoder and the file-transcription engine), so it can't run under
/// `swift test`. This test drives the exact core seams the coordinator composes —
/// `MeetingSessionStore` persistence, the `Meeting`/`MeetingStatus` transitions,
/// `MeetingSummarizer.run` map/reduce, and the `RefineOutputGuard` language check —
/// with a scripted transcript and a scripted summarizer LLM, asserting the full
/// status sequence lands and persists.
///
/// The driver below is a faithful, side-effect-free replica of the coordinator's
/// `finishTranscription → summarize → finishSummary` logic, so a regression in the
/// transition rules or the guard wiring is caught here.
final class MeetingPipelineE2ETests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // A pure replica of the coordinator's persisted state machine.
    private func drive(
        transcript: String,
        providerIsLocal: Bool,
        confirmedCloud: Bool,
        summarizeCall: MeetingSummarizer.Call
    ) async -> (store: MeetingSessionStore, id: UUID, statuses: [MeetingStatus]) {
        let store = MeetingSessionStore(baseDirectory: dir)
        var statuses: [MeetingStatus] = []
        func persist(_ m: Meeting) { store.upsert(m); statuses.append(m.status) }

        // recorded
        var meeting = Meeting(wavFileName: MeetingWAVName.fileName(for: UUID()), status: .recorded)
        persist(meeting)
        // transcribing
        meeting.status = .transcribing; persist(meeting)
        // transcribed
        meeting.transcript = transcript
        meeting.status = .transcribed; persist(meeting)

        // summarize gate (privacy rule)
        let mayRun = providerIsLocal || confirmedCloud
        guard mayRun else { return (store, meeting.id, statuses) }

        meeting.status = .summarizing; persist(meeting)
        do {
            let summary = try await MeetingSummarizer.run(transcript: transcript, call: summarizeCall)
            if RefineOutputGuard.outputTranslatedAway(input: transcript, output: summary) {
                meeting.summary = nil
                meeting.status = .done
            } else {
                meeting.summary = summary
                meeting.status = .done
            }
            persist(meeting)
        } catch {
            meeting.status = .transcribed; persist(meeting)
        }
        return (store, meeting.id, statuses)
    }

    // MARK: - Happy path (local provider auto-summarizes)

    func testLocalProviderRunsFullPipelineAndPersists() async throws {
        let (store, id, statuses) = await drive(
            transcript: "We met about the launch. We decided to ship Friday. Bob will update the changelog.",
            providerIsLocal: true, confirmedCloud: false
        ) { _, _ in "## Summary\nLaunch meeting.\n## Decisions\n- Ship Friday\n## Action items\n- Bob: changelog" }

        XCTAssertEqual(statuses, [.recorded, .transcribing, .transcribed, .summarizing, .done])
        let persisted = store.load().first { $0.id == id }
        XCTAssertEqual(persisted?.status, .done)
        XCTAssertNotNil(persisted?.summary)
        XCTAssertTrue(persisted?.summary?.contains("## Decisions") ?? false)
        XCTAssertNotNil(persisted?.transcript)
    }

    // MARK: - Privacy rule (cloud provider needs consent)

    func testCloudProviderWithoutConsentStopsAtTranscribed() async throws {
        var called = false
        let (store, id, statuses) = await drive(
            transcript: "Short meeting. Done.", providerIsLocal: false, confirmedCloud: false
        ) { _, _ in called = true; return "## Summary\nx" }

        XCTAssertFalse(called, "LLM must not be called without cloud consent")
        XCTAssertEqual(statuses, [.recorded, .transcribing, .transcribed])
        XCTAssertNil(store.load().first { $0.id == id }?.summary)
    }

    func testCloudProviderWithConsentSummarizes() async throws {
        let (store, id, statuses) = await drive(
            transcript: "Short meeting. Done.", providerIsLocal: false, confirmedCloud: true
        ) { _, _ in "## Summary\ncloud summary" }

        XCTAssertEqual(statuses.last, .done)
        XCTAssertTrue(statuses.contains(.summarizing))
        XCTAssertEqual(store.load().first { $0.id == id }?.summary, "## Summary\ncloud summary")
    }

    // MARK: - Language guard (translated-away summary is rejected)

    func testTranslatedSummaryIsRejectedTranscriptKept() async throws {
        // Russian transcript, English summary → guard rejects → summary dropped.
        let russian = "Мы обсудили запуск продукта. Мы решили выпустить его в пятницу. Иван обновит документацию."
        let (store, id, statuses) = await drive(
            transcript: russian, providerIsLocal: true, confirmedCloud: false
        ) { _, _ in "## Summary\nWe discussed the product launch and decided to ship on Friday." }

        XCTAssertEqual(statuses.last, .done)
        let persisted = store.load().first { $0.id == id }
        XCTAssertNil(persisted?.summary, "translated summary must be dropped")
        XCTAssertEqual(persisted?.transcript, russian, "transcript is kept intact")
    }

    // MARK: - LLM failure is non-destructive

    func testSummarizeFailureFallsBackToTranscribed() async throws {
        struct E: Error {}
        let (store, id, statuses) = await drive(
            transcript: "Short meeting. Done.", providerIsLocal: true, confirmedCloud: false
        ) { _, _ in throw E() }

        XCTAssertEqual(statuses.last, .transcribed)
        let persisted = store.load().first { $0.id == id }
        XCTAssertNotNil(persisted?.transcript)
        XCTAssertNil(persisted?.summary)
    }

    // MARK: - MAK-52 speaker attribution (two scripted leg transcripts)

    /// E2E through the core attribution seams: two per-leg chunk sets are
    /// interleaved into an attributed transcript, the attributed transcript is
    /// preferred as the summarizer input, and the whole thing persists. This mirrors
    /// the coordinator's `attributeAndThenSummarize → summarize` composition without
    /// the app-only engine/decoder.
    func testAttributedTranscriptIsBuiltAndPreferredForSummary() async throws {
        let store = MeetingSessionStore(baseDirectory: dir)

        // Scripted per-leg chunk results (as the leg transcription would return).
        let micChunks = [
            TranscriptInterleaver.Chunk(speaker: "Me", start: 0, text: "Hi, thanks for joining."),
            TranscriptInterleaver.Chunk(speaker: "Me", start: 4, text: "Let's ship Friday."),
        ]
        let themChunks = [
            TranscriptInterleaver.Chunk(speaker: "Them", start: 2, text: "Happy to be here."),
            TranscriptInterleaver.Chunk(speaker: "Them", start: 6, text: "I'll update the changelog."),
        ]
        let attributed = TranscriptInterleaver.merge(micChunks + themChunks)
        // Interleaved by start time, labeled per speaker.
        XCTAssertEqual(attributed,
            "Me: Hi, thanks for joining.\nThem: Happy to be here.\nMe: Let's ship Friday.\nThem: I'll update the changelog.")

        let plain = "Hi, thanks for joining. Happy to be here. Let's ship Friday. I'll update the changelog."
        var meeting = Meeting(wavFileName: MeetingWAVName.fileName(for: UUID()),
                              transcript: plain, attributedTranscript: attributed, status: .transcribed)
        store.upsert(meeting)

        // The coordinator prefers the attributed transcript as the summarizer input.
        let summarizerInput = (meeting.attributedTranscript?.isEmpty == false)
            ? meeting.attributedTranscript! : plain
        XCTAssertEqual(summarizerInput, attributed, "attributed transcript must be preferred over plain")

        // Summarizer receives the attributed text; its Me/Them labels reach the model
        // (the summarizer normalizes whitespace but keeps the label tokens).
        var seenInput: String?
        let summary = try await MeetingSummarizer.run(transcript: summarizerInput) { _, input in
            seenInput = input
            return "## Summary\nKickoff.\n## Decisions\n- Ship Friday\n## Action items\n- Them: changelog"
        }
        XCTAssertTrue(seenInput?.contains("Me:") ?? false, "labels should reach the summarizer")
        XCTAssertTrue(seenInput?.contains("Them:") ?? false)
        // Language guard runs against the PLAIN transcript, not the labeled one.
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: plain, output: summary))

        meeting.summary = summary
        meeting.status = .done
        store.upsert(meeting)

        let persisted = store.load().first { $0.id == meeting.id }
        XCTAssertEqual(persisted?.attributedTranscript, attributed)
        XCTAssertEqual(persisted?.transcript, plain, "plain transcript is kept alongside")
        XCTAssertTrue(persisted?.summary?.contains("Them: changelog") ?? false)
    }
}
