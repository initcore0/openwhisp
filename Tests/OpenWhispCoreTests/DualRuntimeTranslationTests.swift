import XCTest
@testable import OpenWhispCore

/// The dual-runtime live-translation core: the arm policy, the utterance chunker,
/// and the ordered translate queue.
final class DualRuntimeTranslationTests: XCTestCase {

    // MARK: - Policy (capability matrix)

    func testPolicyRunsForParakeetNonEnglishTranslate() {
        // Parakeet: ASR-only (can't translate) + provides an audio tap → dual path.
        XCTAssertTrue(DualRuntimeTranslationPolicy.shouldRun(
            translateToEnglish: true, language: "ru",
            transcriptionEngine: EngineCapabilities.parakeet))
        // "auto" is a non-English source too (the speaker may dictate any language).
        XCTAssertTrue(DualRuntimeTranslationPolicy.shouldRun(
            translateToEnglish: true, language: "auto",
            transcriptionEngine: EngineCapabilities.parakeet))
    }

    func testPolicyOffWhenTranslateDisabled() {
        XCTAssertFalse(DualRuntimeTranslationPolicy.shouldRun(
            translateToEnglish: false, language: "ru",
            transcriptionEngine: EngineCapabilities.parakeet))
    }

    func testPolicyOffForEnglishSource() {
        // en→en is a no-op; a regional tag counts as English too.
        XCTAssertFalse(DualRuntimeTranslationPolicy.shouldRun(
            translateToEnglish: true, language: "en",
            transcriptionEngine: EngineCapabilities.parakeet))
        XCTAssertFalse(DualRuntimeTranslationPolicy.shouldRun(
            translateToEnglish: true, language: "en-US",
            transcriptionEngine: EngineCapabilities.parakeet))
    }

    func testPolicyOffForEnginesThatTranslateThemselves() {
        // whisper.cpp / WhisperKit translate directly → the normal path owns it,
        // no tee (they also declare providesAudioTap == false).
        for engine in [EngineCapabilities.whisperCpp, EngineCapabilities.whisperKit] {
            XCTAssertFalse(DualRuntimeTranslationPolicy.shouldRun(
                translateToEnglish: true, language: "ru", transcriptionEngine: engine),
                "\(engine) translates itself; dual path must not run")
        }
    }

    func testPolicyOffForAsrEnginesWithoutAudioTap() {
        // Apple Speech / SpeechAnalyzer are ASR-only but expose no audio tap, so
        // there is nothing to tee — the dual path can't run for them.
        for engine in [EngineCapabilities.appleSpeech, EngineCapabilities.speechAnalyzer] {
            XCTAssertFalse(DualRuntimeTranslationPolicy.shouldRun(
                translateToEnglish: true, language: "ru", transcriptionEngine: engine),
                "\(engine) has no audio tap; dual path must not run")
        }
    }

    // MARK: - Chunker (boundaries, caps, no sample loss)

    /// 0.6s speech, then 1s silence → one chunk at the silence boundary.
    func testTranslationOfferedMatchesEitherPath() {
        // Whisper family: translates itself. Parakeet: dual path via audio tap.
        // Apple Speech / SpeechAnalyzer: ASR-only, no tap — the offer stays off
        // (the menu row dims). This is the single gate every offer surface
        // (menu bar + Dictation pane) must use — the tray-menu bug was these
        // surfaces disagreeing.
        XCTAssertTrue(DualRuntimeTranslationPolicy.translationOffered(
            transcriptionEngine: EngineCapabilities.whisperKit))
        XCTAssertTrue(DualRuntimeTranslationPolicy.translationOffered(
            transcriptionEngine: EngineCapabilities.parakeet))
        XCTAssertFalse(DualRuntimeTranslationPolicy.translationOffered(
            transcriptionEngine: EngineCapabilities.appleSpeech))
    }

    func testChunkerSplitsOnSilenceBoundary() {
        var chunker = TranslationChunker(
            sampleRate: 16_000, minDuration: 0.4, maxDuration: 8,
            silenceDuration: 0.6, silenceThreshold: 0.05)
        var out: [[Float]] = []
        // 0.6s of "speech" (loud), fed in 0.1s blocks.
        for _ in 0..<6 { out += chunker.ingest(block(0.1, level: 0.3)) }
        XCTAssertTrue(out.isEmpty, "no boundary while speaking")
        // 0.7s of silence crosses the 0.6s threshold → boundary.
        for _ in 0..<7 { out += chunker.ingest(block(0.1, level: 0.0)) }
        XCTAssertEqual(out.count, 1, "exactly one chunk at the silence boundary")
        // The chunk holds all the buffered audio (0.6s speech + the silence tail).
        XCTAssertEqual(out[0].count, Int(1.3 * 16_000), accuracy: 16_000 / 10)
    }

    func testChunkerRespectsMinDuration() {
        var chunker = TranslationChunker(
            sampleRate: 16_000, minDuration: 1.0, maxDuration: 8,
            silenceDuration: 0.3, silenceThreshold: 0.05)
        var out: [[Float]] = []
        // 0.3s speech (below the 1.0s min) then silence — must NOT split.
        for _ in 0..<3 { out += chunker.ingest(block(0.1, level: 0.3)) }
        for _ in 0..<5 { out += chunker.ingest(block(0.1, level: 0.0)) }
        XCTAssertTrue(out.isEmpty, "a sub-min utterance is not split on silence")
    }

    func testChunkerFlushesAtMaxDuration() {
        var chunker = TranslationChunker(
            sampleRate: 16_000, minDuration: 0.4, maxDuration: 2.0,
            silenceDuration: 5.0, silenceThreshold: 0.05)
        var out: [[Float]] = []
        // Continuous speech, no silence — must flush at the 2s cap.
        for _ in 0..<30 { out += chunker.ingest(block(0.1, level: 0.3)) }
        XCTAssertGreaterThanOrEqual(out.count, 1, "max-duration cap forces a flush mid-speech")
        XCTAssertEqual(out[0].count, Int(2.0 * 16_000), "the max-duration chunk is exactly the cap")
    }

    /// Every ingested sample leaves in exactly one emitted chunk or the flush.
    func testChunkerLosesNoSamples() {
        var chunker = TranslationChunker(
            sampleRate: 16_000, minDuration: 0.4, maxDuration: 1.5,
            silenceDuration: 0.4, silenceThreshold: 0.05)
        var emitted = 0
        var fed = 0
        // Mixed speech/silence, several boundaries and max flushes.
        let script: [(Double, Float)] = [
            (0.5, 0.3), (0.5, 0.0), (2.0, 0.3), (0.6, 0.0), (0.3, 0.3),
        ]
        for (dur, level) in script {
            let b = block(dur, level: level)
            fed += b.count
            for chunk in chunker.ingest(b) { emitted += chunk.count }
        }
        if let tail = chunker.flush() { emitted += tail.count }
        XCTAssertEqual(emitted, fed, "no sample is lost or duplicated across chunk boundaries")
    }

    // MARK: - Segment queue (ordering, drop-oldest, drain)

    /// Out-of-order COMPLETION timing must not reorder output — but since exactly
    /// one job is in flight at a time, the queue enforces this structurally.
    func testQueueEmitsSegmentsInDispatchOrder() {
        var q = TranslationSegmentQueue(maxPending: 6)
        q.enqueue([1]); q.enqueue([2]); q.enqueue([3])
        // Dispatch + complete strictly one at a time (the coordinator's contract).
        let a = q.next(); q.complete(id: a!.id, text: "first")
        let b = q.next(); q.complete(id: b!.id, text: "second")
        let c = q.next(); q.complete(id: c!.id, text: "third")
        XCTAssertEqual(q.segments, ["first", "second", "third"])
        XCTAssertEqual(q.joinedText, "first second third")
    }

    func testQueueSingleInFlight() {
        var q = TranslationSegmentQueue(maxPending: 6)
        q.enqueue([1]); q.enqueue([2])
        let a = q.next()
        XCTAssertNotNil(a)
        XCTAssertNil(q.next(), "no second dispatch while one is in flight")
        q.complete(id: a!.id, text: "a")
        XCTAssertNotNil(q.next(), "next dispatch available once the slot frees")
    }

    func testQueueDropsOldestUnderBackpressure() {
        var q = TranslationSegmentQueue(maxPending: 2)
        for i in 1...5 { q.enqueue([Float(i)]) }
        XCTAssertEqual(q.pendingCount, 2, "backlog is capped at maxPending")
        XCTAssertEqual(q.droppedCount, 3, "the three oldest chunks were dropped")
        // The retained chunks are the NEWEST two (4, 5).
        let first = q.next()
        XCTAssertEqual(first?.chunk, [4])
    }

    func testQueueIgnoresEmptyAndStaleCompletions() {
        var q = TranslationSegmentQueue(maxPending: 6)
        q.enqueue([1])
        let a = q.next()!
        XCTAssertNil(q.complete(id: a.id, text: "   "), "empty translation is not a segment")
        // A completion for an id not in flight (already freed) is ignored.
        XCTAssertNil(q.complete(id: a.id, text: "late"))
        XCTAssertTrue(q.segments.isEmpty)
        XCTAssertTrue(q.isDrained)
    }

    // MARK: - Helpers

    /// A block of `seconds` at 16 kHz filled with a constant magnitude (a crude
    /// speech/silence proxy the chunker's RMS reads).
    private func block(_ seconds: Double, level: Float) -> [Float] {
        Array(repeating: level, count: Int(seconds * 16_000))
    }
}
