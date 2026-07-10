import XCTest
@testable import OpenWhispCore

/// Unit tests for the MAK-45 quiet-dictation preprocessing preset: the high-gain
/// normalizer's gain math (target/limiter/noise-floor), the whisper-friendly VAD
/// threshold resolution, and the lowered silence-auto-stop config. Drives the pure
/// core logic with synthetic PCM peaks/RMS — no audio APIs.
final class QuietDictationModeTests: XCTestCase {

    // MARK: - Gain: quiet sine is lifted toward the target

    func testQuietBufferIsGainedTowardTarget() {
        // A soft peak that the boost ceiling (maxGain) can still lift all the way to
        // the target: peak ≥ targetPeak / maxGain (0.85/40 ≈ 0.0213). Use 0.04.
        let cfg = QuietDictationMode.GainConfig.default
        let peak: Float = 0.04
        let g = QuietDictationMode.gain(forPeak: peak)
        XCTAssertGreaterThan(g, 1.0)
        let resulting = peak * g
        // Reaches the target (within the boost ceiling and below clip).
        XCTAssertEqual(resulting, cfg.targetPeak, accuracy: 0.02)
    }

    func testVeryFaintPeakIsBoostedButCappedByMaxGain() {
        // Below targetPeak / maxGain, the boost ceiling binds first: the buffer is
        // lifted hard (×maxGain) but can't reach the full target. Still a big lift.
        let cfg = QuietDictationMode.GainConfig.default
        let peak: Float = 0.01
        let g = QuietDictationMode.gain(forPeak: peak)
        XCTAssertEqual(g, cfg.maxGain, accuracy: 1e-4)
        XCTAssertLessThan(peak * g, cfg.targetPeak)   // couldn't fully reach target
        XCTAssertGreaterThan(peak * g, 0.3)           // but a strong boost regardless
    }

    func testGainNeverExceedsMaxBoost() {
        // An extremely faint (but above-floor) peak wants more than maxGain; it's capped.
        let cfg = QuietDictationMode.GainConfig.default
        let peak: Float = 0.005          // above noiseFloor (0.004), very faint
        let g = QuietDictationMode.gain(forPeak: peak)
        XCTAssertLessThanOrEqual(g, cfg.maxGain)
        // And the resulting peak still never crosses the clip ceiling.
        XCTAssertLessThanOrEqual(peak * g, cfg.clipCeiling + 1e-6)
    }

    // MARK: - Gain: loud input is not over-amplified / never clips

    func testLoudInputIsNotAmplified() {
        // At/above the target peak (0.85): gain floors at 1.0 (never ducks, never
        // needlessly boosts a signal already as loud as we aim for).
        XCTAssertEqual(QuietDictationMode.gain(forPeak: 0.85), 1.0, accuracy: 1e-6)
        XCTAssertEqual(QuietDictationMode.gain(forPeak: 0.95), 1.0, accuracy: 1e-6)
        // A peak already above the clip ceiling is never boosted either.
        XCTAssertEqual(QuietDictationMode.gain(forPeak: 0.99), 1.0, accuracy: 1e-6)
    }

    func testGainNeverClipsAcrossPeakRange() {
        // The no-clip guarantee: the gain never pushes a peak *up* past the clip
        // ceiling. For a peak already above the ceiling (only reachable if the input
        // was loud to begin with), gain floors at 1.0 — it isn't made worse — and the
        // recorder's hard clamp handles the pre-existing over-level sample.
        let cfg = QuietDictationMode.GainConfig.default
        var p: Float = 0.001
        while p < 1.0 {
            let resulting = p * QuietDictationMode.gain(forPeak: p)
            let bound = max(p, cfg.clipCeiling)
            XCTAssertLessThanOrEqual(resulting, bound + 1e-6,
                                     "peak \(p) was boosted past the clip ceiling")
            p += 0.017
        }
    }

    // MARK: - Gain: silence causes no gain explosion

    func testSilenceIsLeftAlone() {
        // At/below the noise floor: exactly 1.0 (no boost — no hiss amplification).
        XCTAssertEqual(QuietDictationMode.gain(forPeak: 0.0), 1.0)
        XCTAssertEqual(QuietDictationMode.gain(forPeak: 0.001), 1.0)
        XCTAssertEqual(QuietDictationMode.gain(forPeak: QuietDictationMode.GainConfig.default.noiseFloor), 1.0)
    }

    func testNonFinitePeakIsSafe() {
        XCTAssertEqual(QuietDictationMode.gain(forPeak: .nan), 1.0)
        XCTAssertEqual(QuietDictationMode.gain(forPeak: .infinity), 1.0)
        XCTAssertEqual(QuietDictationMode.gain(forPeak: -1.0), 1.0)
    }

    // MARK: - Gain from a synthetic sine buffer (end-to-end apply)

    func testAppliedToQuietSineBufferReachesTargetWithoutClipping() {
        // Build a quiet sine (peak ~0.02), apply the computed gain to every sample,
        // hard-clamp as the recorder does, and check the boosted peak.
        let n = 1600
        let amp: Float = 0.02
        var samples = (0..<n).map { i in amp * sinf(2 * .pi * 220 * Float(i) / 16000) }
        let peak = samples.map { abs($0) }.max() ?? 0
        let g = QuietDictationMode.gain(forPeak: peak)
        for i in 0..<n {
            let v = samples[i] * g
            samples[i] = v > 1 ? 1 : (v < -1 ? -1 : v)
        }
        let outPeak = samples.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(outPeak, 0.5, "quiet sine should be lifted to a strong level")
        XCTAssertLessThanOrEqual(outPeak, 1.0, "must never clip")
    }

    // MARK: - RMS convenience

    func testGainFromRMSUsesCrestFactor() {
        // RMS 0.01 with crest 3 → peak 0.03 → boosted.
        let g = QuietDictationMode.gain(forRMS: 0.01, crestFactor: 3.0)
        XCTAssertGreaterThan(g, 1.0)
        XCTAssertEqual(g, QuietDictationMode.gain(forPeak: 0.03), accuracy: 1e-5)
    }

    // MARK: - Threshold preset resolution

    func testThresholdsOffMatchNormalDefaults() {
        let t = QuietDictationMode.thresholds(quietEnabled: false)
        XCTAssertEqual(t, QuietDictationMode.normalThresholds)
        // Parity with the AudioCapture protocol's convenience defaults.
        XCTAssertEqual(t.speechThreshold, 0.018, accuracy: 1e-6)
        XCTAssertEqual(t.silenceDuration, 0.75, accuracy: 1e-6)
    }

    func testQuietThresholdsLowerSpeechGate() {
        let normal = QuietDictationMode.thresholds(quietEnabled: false)
        let quiet = QuietDictationMode.thresholds(quietEnabled: true)
        XCTAssertLessThan(quiet.speechThreshold, normal.speechThreshold,
                          "quiet mode must lower the speech-detection gate")
        XCTAssertGreaterThanOrEqual(quiet.silenceDuration, normal.silenceDuration,
                                    "quiet mode must not shorten the pause hangover")
        // A whisper's RMS (~0.008) registers as speech under quiet, not under normal.
        let whisperRMS: Float = 0.008
        XCTAssertGreaterThanOrEqual(whisperRMS, quiet.speechThreshold)
        XCTAssertLessThan(whisperRMS, normal.speechThreshold)
    }

    // MARK: - Silence-auto-stop config resolution

    func testSilenceAutoStopConfigOffIsDefault() {
        XCTAssertEqual(QuietDictationMode.silenceAutoStopConfig(quietEnabled: false), .default)
    }

    func testQuietSilenceAutoStopLowersGates() {
        let def = SilenceAutoStop.Config.default
        let quiet = QuietDictationMode.silenceAutoStopConfig(quietEnabled: true)
        XCTAssertLessThan(quiet.speechLevel, def.speechLevel)
        XCTAssertLessThan(quiet.silenceLevel, def.silenceLevel)
        // Hysteresis preserved: speech gate stays above silence gate.
        XCTAssertGreaterThan(quiet.speechLevel, quiet.silenceLevel)
    }

    func testQuietSilenceAutoStopArmsOnWhisperLevel() {
        // A low normalized level that would NOT arm the default detector arms the
        // quiet one (proving the lowered gates actually matter end-to-end).
        // Feed a run of continuous whisper-level samples at the detector's ~0.1s
        // cadence (credit is capped per sample, and only accrues while the previous
        // sample was also speech), enough to clear minSpeechToArm (0.30s).
        let whisperLevel: Float = 0.09
        func feed(_ config: SilenceAutoStop.Config) -> SilenceAutoStop {
            var d = SilenceAutoStop(config: config)
            var t = 0.0
            for _ in 0..<8 { _ = d.ingest(level: whisperLevel, now: t); t += 0.1 }
            return d
        }

        XCTAssertFalse(feed(.default).isArmed,
                       "whisper level shouldn't arm the default detector")
        XCTAssertTrue(feed(QuietDictationMode.silenceAutoStopConfig(quietEnabled: true)).isArmed,
                      "whisper level should arm the quiet detector")
    }

    // MARK: - Integration: quiet thresholds drive the real pause-based VAD

    /// Feed a checked-in fixture through the REAL pause-based VAD (`FileAudioCapture`,
    /// the same arithmetic the recorder runs) with the quiet vs normal presets and
    /// assert the lowered speech gate captures at least as much speech — i.e. the
    /// preset is actually wired through the capture seam, not just a value bag.
    func testQuietThresholdsCaptureAtLeastAsMuchThroughRealVAD() throws {
        func chunkCount(quiet: Bool) throws -> Int {
            let cap = try FileAudioCapture(
                fixtureURL: FileAudioCaptureTests.fixture("speech_then_silence.wav")
            )
            let t = QuietDictationMode.thresholds(quietEnabled: quiet)
            var chunks = 0
            cap.startStreamingOnSilence(
                silenceDuration: t.silenceDuration,
                minimumSpeechDuration: t.minimumSpeechDuration,
                maximumSpeechDuration: t.maximumSpeechDuration,
                speechThreshold: t.speechThreshold
            ) { url in if url != nil { chunks += 1 } }
            return chunks
        }
        let normal = try chunkCount(quiet: false)
        let quiet = try chunkCount(quiet: true)
        XCTAssertGreaterThanOrEqual(quiet, normal,
            "quiet's lower speech gate must not capture fewer speech chunks than normal")
    }
}
