import XCTest
@testable import OpenWhispCore

final class MeetingMixerTests: XCTestCase {

    // Generate `count` samples of a sine at `freq` (cycles over the whole buffer),
    // scaled to `amp`.
    private func sine(count: Int, cycles: Double, amp: Float) -> [Float] {
        (0..<count).map { i in
            amp * Float(sin(2 * Double.pi * cycles * Double(i) / Double(count)))
        }
    }

    // MARK: mixing law

    func testTwoSinesMixWithoutClipping() {
        var mixer = MeetingMixer()
        let a = sine(count: 4096, cycles: 5, amp: 1.0)   // full-scale
        let b = sine(count: 4096, cycles: 7, amp: 1.0)   // full-scale, different freq
        _ = mixer.appendSystem(a)
        let out = mixer.appendMic(b)
        XCTAssertEqual(out.count, 4096)
        // 0.5/0.5 average of two full-scale signals can never exceed full scale.
        for s in out {
            XCTAssertLessThanOrEqual(s, 1.0)
            XCTAssertGreaterThanOrEqual(s, -1.0)
        }
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max() ?? 0, 1.0)
    }

    func testClipGuardClampsOutOfRangeInput() {
        // Caller feeds already-out-of-range samples: the clamp must catch them.
        XCTAssertEqual(MeetingMixer.mixSample(3.0, 3.0), 1.0)
        XCTAssertEqual(MeetingMixer.mixSample(-3.0, -3.0), -1.0)
    }

    func testSilencePlusSignalEqualsHalfSignal() {
        // silence + signal => 0.5 * signal (average law), never lost, never clipped.
        var mixer = MeetingMixer()
        let signal = sine(count: 1000, cycles: 3, amp: 0.8)
        let silence = [Float](repeating: 0, count: 1000)
        _ = mixer.appendSystem(silence)
        let out = mixer.appendMic(signal)
        XCTAssertEqual(out.count, 1000)
        for i in 0..<1000 {
            XCTAssertEqual(out[i], 0.5 * signal[i], accuracy: 1e-6)
        }
    }

    // MARK: frontier reconciliation

    func testMismatchedChunkCadenceReconciles() {
        var mixer = MeetingMixer()
        // System arrives in one big chunk; mic dribbles in small ones.
        let sys = (0..<300).map { Float($0) / 300.0 }  // in-range ramp 0..<1
        var collected: [Float] = []
        _ = mixer.appendSystem(sys)                     // nothing to mix yet (no mic)
        XCTAssertEqual(mixer.pendingImbalance, 300)

        collected += mixer.appendMic([Float](repeating: 0, count: 100))
        collected += mixer.appendMic([Float](repeating: 0, count: 100))
        collected += mixer.appendMic([Float](repeating: 0, count: 100))

        XCTAssertEqual(collected.count, 300)
        XCTAssertEqual(mixer.pendingImbalance, 0)
        // Mic was silence => each mixed sample is 0.5 * system ramp, in order.
        for i in 0..<300 {
            XCTAssertEqual(collected[i], 0.5 * (Float(i) / 300.0), accuracy: 1e-4)
        }
    }

    func testLongStreamFrontierBookkeeping() {
        var mixer = MeetingMixer()
        var rng = SystemRandomNumberGenerator()
        var totalSys = 0, totalMic = 0, totalOut = 0
        for _ in 0..<500 {
            let s = Int.random(in: 1...200, using: &rng)
            let m = Int.random(in: 1...200, using: &rng)
            totalSys += s; totalMic += m
            totalOut += mixer.appendSystem([Float](repeating: 0.2, count: s)).count
            totalOut += mixer.appendMic([Float](repeating: 0.2, count: m)).count
        }
        // Emitted exactly min(totalSys, totalMic) frames; the rest is buffered.
        XCTAssertEqual(totalOut, min(totalSys, totalMic))
        XCTAssertEqual(mixer.framesEmitted, min(totalSys, totalMic))
        XCTAssertEqual(mixer.pendingImbalance, abs(totalSys - totalMic))

        // Draining the remainder accounts for every input sample exactly once.
        let drained = mixer.drainRemainder()
        XCTAssertEqual(drained.count, abs(totalSys - totalMic))
        XCTAssertEqual(mixer.framesEmitted, max(totalSys, totalMic))
        XCTAssertEqual(mixer.pendingImbalance, 0)
    }

    func testDrainRemainderPassesLeftoverAtHalfGain() {
        var mixer = MeetingMixer()
        _ = mixer.appendSystem([1.0, 1.0, 1.0])   // mic never arrives
        let drained = mixer.drainRemainder()
        XCTAssertEqual(drained, [0.5, 0.5, 0.5])   // 0.5 * signal + silence, clamped
    }

    // MARK: seam contract

    func testMeetingRecordingCodableRoundTrip() {
        let rec = MeetingRecording(
            id: UUID(),
            wavURL: URL(fileURLWithPath: "/tmp/m.wav"),
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            duration: 42.5
        )
        let data = try! JSONEncoder().encode(rec)
        let back = try! JSONDecoder().decode(MeetingRecording.self, from: data)
        XCTAssertEqual(rec, back)
    }
}
