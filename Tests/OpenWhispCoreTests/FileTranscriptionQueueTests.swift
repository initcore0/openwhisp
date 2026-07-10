import XCTest
@testable import OpenWhispCore

final class FileTranscriptionQueueTests: XCTestCase {

    // MARK: - Chunk planning

    func testShortFileIsSingleChunk() {
        let plan = FileChunkPlanner.plan(duration: 12, chunkSeconds: 30)
        XCTAssertEqual(plan, [FileChunkPlan(index: 0, start: 0, end: 12)])
    }

    func testLongFileSplitsIntoWindowsWithRemainder() {
        let plan = FileChunkPlanner.plan(duration: 70, chunkSeconds: 30)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[0], FileChunkPlan(index: 0, start: 0, end: 30))
        XCTAssertEqual(plan[1], FileChunkPlan(index: 1, start: 30, end: 60))
        XCTAssertEqual(plan[2], FileChunkPlan(index: 2, start: 60, end: 70))
    }

    func testExactMultipleHasNoTrailingEmptyChunk() {
        let plan = FileChunkPlanner.plan(duration: 60, chunkSeconds: 30)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.last?.end, 60)
    }

    func testZeroDurationYieldsOneSlot() {
        let plan = FileChunkPlanner.plan(duration: 0)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].duration, 0)
    }

    // MARK: - Queue lifecycle

    func testSingleActiveJobScheduling() {
        var q = FileTranscriptionQueue()
        let a = FileTranscriptionJob(sourcePath: "/tmp/a.mp3")
        let b = FileTranscriptionJob(sourcePath: "/tmp/b.mp4")
        q.add(a); q.add(b)

        // First next() is the first queued job.
        XCTAssertEqual(q.next()?.id, a.id)
        q.beginLoading(a.id, duration: 10)
        // While a is active, next() returns nil (single-active policy).
        XCTAssertNil(q.next())
        q.beginTranscribing(a.id)
        XCTAssertNil(q.next())
        q.completeChunk(a.id, chunkIndex: 0, text: "hello")
        q.finishTranscription(a.id)
        XCTAssertEqual(q.job(a.id)?.stage, .done)
        // Now b is schedulable.
        XCTAssertEqual(q.next()?.id, b.id)
    }

    func testFullTranscriptConcatenatesChunksInOrder() {
        var q = FileTranscriptionQueue()
        let j = FileTranscriptionJob(sourcePath: "/tmp/long.mp4")
        q.add(j)
        q.beginLoading(j.id, duration: 70, chunkSeconds: 30) // 3 chunks
        q.beginTranscribing(j.id)
        // Complete out of order; fullText must still be in chunk order.
        q.completeChunk(j.id, chunkIndex: 2, text: "three")
        q.completeChunk(j.id, chunkIndex: 0, text: "one")
        q.completeChunk(j.id, chunkIndex: 1, text: "two")
        XCTAssertTrue(q.job(j.id)!.allChunksComplete)
        XCTAssertEqual(q.job(j.id)?.fullText, "one two three")
    }

    func testEnhanceEnabledRoutesThroughEnhancing() {
        var q = FileTranscriptionQueue(enhanceEnabled: true)
        let j = FileTranscriptionJob(sourcePath: "/tmp/a.wav")
        q.add(j)
        q.beginLoading(j.id, duration: 5)
        q.beginTranscribing(j.id)
        q.completeChunk(j.id, chunkIndex: 0, text: "raw text")
        let needsEnhance = q.finishTranscription(j.id)
        XCTAssertTrue(needsEnhance)
        XCTAssertEqual(q.job(j.id)?.stage, .enhancing)
        q.finishEnhancing(j.id, enhancedText: "Polished text.")
        XCTAssertEqual(q.job(j.id)?.stage, .done)
        XCTAssertEqual(q.job(j.id)?.fullText, "Polished text.")
    }

    func testFailureIsTerminalAndUnblocksNext() {
        var q = FileTranscriptionQueue()
        let a = FileTranscriptionJob(sourcePath: "/tmp/a.mp3")
        let b = FileTranscriptionJob(sourcePath: "/tmp/b.mp3")
        q.add(a); q.add(b)
        q.beginLoading(a.id, duration: 5)
        q.fail(a.id, message: "decode error")
        XCTAssertEqual(q.job(a.id)?.stage, .failed)
        XCTAssertEqual(q.job(a.id)?.errorMessage, "decode error")
        XCTAssertEqual(q.failedCount, 1)
        XCTAssertEqual(q.next()?.id, b.id)
    }

    func testDedupeByPath() {
        var q = FileTranscriptionQueue()
        XCTAssertNotNil(q.add(FileTranscriptionJob(sourcePath: "/tmp/x.mp3")))
        XCTAssertNil(q.add(FileTranscriptionJob(sourcePath: "/tmp/x.mp3")))
        XCTAssertEqual(q.jobs.count, 1)
    }

    func testClearFinishedKeepsPending() {
        var q = FileTranscriptionQueue()
        let a = FileTranscriptionJob(sourcePath: "/tmp/a.mp3")
        let b = FileTranscriptionJob(sourcePath: "/tmp/b.mp3")
        q.add(a); q.add(b)
        q.beginLoading(a.id, duration: 1); q.beginTranscribing(a.id)
        q.completeChunk(a.id, chunkIndex: 0, text: "hi"); q.finishTranscription(a.id)
        q.clearFinished()
        XCTAssertEqual(q.jobs.count, 1)
        XCTAssertEqual(q.jobs.first?.id, b.id)
    }

    // MARK: - Persistence round-trip

    // MARK: - End-to-end: queue lifecycle → subtitle export

    /// Drive a long file all the way through the queue and export it to SRT, proving
    /// chunk-level timing maps onto cue timestamps (the SRT/VTT path MAK-36 ships).
    func testLongFileQueueToSRTExport() {
        var q = FileTranscriptionQueue()
        let j = FileTranscriptionJob(sourcePath: "/tmp/lecture.mp4")
        q.add(j)
        q.beginLoading(j.id, duration: 65, chunkSeconds: 30) // chunks: [0,30],[30,60],[60,65]
        q.beginTranscribing(j.id)
        q.completeChunk(j.id, chunkIndex: 0, text: "Welcome.")
        q.completeChunk(j.id, chunkIndex: 1, text: "Chapter two.")
        q.completeChunk(j.id, chunkIndex: 2, text: "The end.")
        q.finishTranscription(j.id)
        let done = q.job(j.id)!
        XCTAssertEqual(done.stage, .done)

        let srt = SubtitleFormatter.render(.srt, chunks: done.chunks, chunkTexts: done.chunkTexts)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:30,000\nWelcome."))
        XCTAssertTrue(srt.contains("00:00:30,000 --> 00:01:00,000\nChapter two."))
        XCTAssertTrue(srt.contains("00:01:00,000 --> 00:01:05,000\nThe end."))

        XCTAssertEqual(
            TranscriptExportNaming.exportPath(sourcePath: done.sourcePath, format: .srt),
            "/tmp/lecture.srt"
        )
    }

    func testJobCodableRoundTrip() throws {
        var j = FileTranscriptionJob(sourcePath: "/tmp/talk.mp4", durationSeconds: 70, fromWatchFolder: true)
        j.chunks = FileChunkPlanner.plan(duration: 70, chunkSeconds: 30)
        j.chunkTexts = [0: "one", 1: "two"]
        j.stage = .transcribing
        let data = try JSONEncoder().encode(j)
        let back = try JSONDecoder().decode(FileTranscriptionJob.self, from: data)
        XCTAssertEqual(back, j)
    }
}
