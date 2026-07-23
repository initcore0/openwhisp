import XCTest
@testable import OpenWhispCore

/// EXPERIMENT (stream ingest): the pure protocol + conversion layer — hello
/// validation/auth and the PCM → mono Float32 @ 16 kHz converter, including
/// chunk-boundary carry. The live WebSocket path is covered in
/// Tests/OpenWhispSyncLANTests/StreamAudioIngestServerTests.swift.
final class StreamIngestTests: XCTestCase {

    private func hello(
        format: StreamIngestHello.Format = .pcmS16LE,
        rate: Int = 48_000, channels: Int = 1, token: String = ""
    ) -> StreamIngestHello {
        StreamIngestHello(format: format, sampleRate: rate, channels: channels,
                          clientName: "test", token: token)
    }

    // MARK: - Handshake

    func testAcceptsTypicalHellos() {
        XCTAssertEqual(StreamIngestHandshake.evaluate(hello(), requiredToken: ""), .accepted)
        XCTAssertEqual(StreamIngestHandshake.evaluate(
            hello(format: .pcmF32LE, rate: 44_100, channels: 2), requiredToken: ""), .accepted)
    }

    func testRejectsOutOfRangeAudioParameters() {
        XCTAssertEqual(StreamIngestHandshake.evaluate(hello(rate: 4_000), requiredToken: ""),
                       .rejected(reason: "unsupported sampleRate 4000 (want 8000–192000)"))
        guard case .rejected = StreamIngestHandshake.evaluate(hello(channels: 6), requiredToken: "") else {
            return XCTFail("6-channel hello must be rejected")
        }
    }

    func testTokenGate() {
        // No required token (loopback): any client token passes.
        XCTAssertEqual(StreamIngestHandshake.evaluate(hello(token: "whatever"), requiredToken: ""), .accepted)
        // Required token: exact match only.
        XCTAssertEqual(StreamIngestHandshake.evaluate(hello(token: "s3cret"), requiredToken: "s3cret"), .accepted)
        XCTAssertEqual(StreamIngestHandshake.evaluate(hello(token: "wrong"), requiredToken: "s3cret"),
                       .rejected(reason: "invalid token"))
        XCTAssertEqual(StreamIngestHandshake.evaluate(hello(token: ""), requiredToken: "s3cret"),
                       .rejected(reason: "invalid token"))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(StreamIngestHandshake.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(StreamIngestHandshake.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(StreamIngestHandshake.constantTimeEquals("abc", "abcd"))
        XCTAssertTrue(StreamIngestHandshake.constantTimeEquals("", ""))
    }

    // MARK: - Converter

    private func s16Data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func f32Data(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testS16MonoPassthroughAt16k() {
        var conv = StreamIngestAudioConverter(hello: hello(rate: 16_000))
        let out = conv.consume(s16Data([0, 16_384, -32_768, 32_767]))
        // ratio 1.0 → near-passthrough (interpolation needs a lookahead sample,
        // so the last input stays carried until more audio arrives).
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], 0, accuracy: 0.001)
        XCTAssertEqual(out[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(out[2], -1.0, accuracy: 0.001)
    }

    func testStereoF32DownmixesToMono() {
        var conv = StreamIngestAudioConverter(hello: hello(format: .pcmF32LE, rate: 16_000, channels: 2))
        // Frames: (1.0, 0.0), (0.5, 0.5), (-1.0, 1.0), (0, 0)
        let out = conv.consume(f32Data([1.0, 0.0, 0.5, 0.5, -1.0, 1.0, 0, 0]))
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(out[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(out[2], 0.0, accuracy: 0.001)
    }

    func testResamples48kTo16k() {
        var conv = StreamIngestAudioConverter(hello: hello(rate: 48_000))
        // 4800 source samples (100 ms @ 48 kHz) → ~1600 output samples.
        let ramp = (0..<4_800).map { Int16($0 % 1_000) }
        let out = conv.consume(s16Data(ramp))
        XCTAssertTrue(abs(out.count - 1_600) <= 2, "expected ~1600 samples, got \(out.count)")
    }

    func testFragmentationInvariance() {
        // Same audio, one big chunk vs. byte-dribbled (splitting even inside a
        // sample), must produce identical output — the network owes us nothing
        // about framing.
        let samples = (0..<960).map { Int16(truncatingIfNeeded: $0 &* 37) }
        let whole = s16Data(samples)

        var oneShot = StreamIngestAudioConverter(hello: hello(rate: 48_000))
        let expected = oneShot.consume(whole)

        var dribbled = StreamIngestAudioConverter(hello: hello(rate: 48_000))
        var got: [Float] = []
        var i = whole.startIndex
        var step = 1
        while i < whole.endIndex {
            let j = min(whole.index(i, offsetBy: step, limitedBy: whole.endIndex) ?? whole.endIndex, whole.endIndex)
            got += dribbled.consume(whole[i..<j])
            i = j
            step = step == 1 ? 7 : (step == 7 ? 64 : 1)  // odd sizes straddle sample boundaries
        }
        XCTAssertEqual(got.count, expected.count)
        for (a, b) in zip(got, expected) {
            XCTAssertEqual(a, b, accuracy: 0.0001)
        }
    }

    func testHelloJSONShape() throws {
        let json = #"{"format":"pcm_s16le","sampleRate":48000,"channels":1,"clientName":"OBS on PC","token":"t"}"#
        let decoded = try JSONDecoder().decode(StreamIngestHello.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, hello(token: "t").with(clientName: "OBS on PC"))
    }
}

private extension StreamIngestHello {
    func with(clientName: String) -> StreamIngestHello {
        var c = self
        c.clientName = clientName
        return c
    }
}
