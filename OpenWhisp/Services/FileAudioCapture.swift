import Foundation

/// A fixture-replaying `AudioCapture` for end-to-end pipeline tests (Tier 1 of
/// docs/E2E_AUDIO_TESTING.md). It replays a pre-recorded WAV through the *real*
/// capture contract — same chunk WAVs, same RMS, same silence/VAD math as the
/// concrete `AudioRecorder` — so everything above the OS audio layer (the live-
/// chunk pipeline, silence auto-stop, transcription engines, formatting, voice
/// actions, history, output) runs its production code against deterministic
/// input, with no microphone, no TCC prompt, and no AVFoundation.
///
/// It is Foundation-only (no AVFoundation) so it lives in `OpenWhispCore` and is
/// reachable from `swift test`: it parses the fixture WAV and writes chunk WAVs
/// with its own tiny RIFF reader/writer, in the exact on-disk format
/// `AudioRecorder` uses — 16 kHz / mono / 16-bit signed LE PCM — so a real
/// `FileTranscriptionEngine` (whisper.cpp / WhisperKit) can transcribe the chunks
/// it emits.
///
/// ### Determinism
/// Delivery is **synchronous on the calling thread** by default: `startStreaming*`
/// slices the whole fixture and invokes `onChunk` for each chunk before returning,
/// and `onStateChanged`/`onLevelChanged` fire inline. This makes pipeline tests
/// deterministic (no timer races). The fixture is processed in ~0.1 s "buffers"
/// mirroring the recorder's tap cadence, so the RMS/VAD arithmetic sees the same
/// granularity it would live.
final class FileAudioCapture: AudioCapture {

    // MARK: AudioCapture protocol surface

    var autoGainEnabled: Bool = true          // accepted for parity; replay is verbatim.
    var quietModeEnabled: Bool = false        // accepted for parity; replay is verbatim.
    var onStateChanged: ((RecorderState) -> Void)?
    var onLevelChanged: ((Float) -> Void)?

    // MARK: Configuration

    /// Seconds of audio per synthetic capture "buffer". `AudioRecorder`'s tap
    /// delivers ~0.1 s buffers; matching that keeps VAD timing/level granularity
    /// realistic. Must divide evenly enough that timing thresholds behave.
    let bufferSeconds: Double

    /// Where chunk WAVs are written. Defaults to a unique temp subdirectory; the
    /// caller owns cleanup (or passes `deleteChunks: true` semantics via the engine).
    let outputDirectory: URL

    /// The parsed fixture: 16 kHz mono Int16 samples.
    private let samples: [Int16]
    private let sampleRate: Int

    /// Introspection for tests: what was requested, mirroring `FakeAudioCapture`.
    private(set) var selectedDevices: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// URLs of every chunk WAV this capture wrote, in emission order.
    private(set) var emittedChunkURLs: [URL] = []

    private var chunkIndex = 0
    private var isRecording = false
    /// The single-file recording written by `start()`, returned on `stop()`.
    private var singleFileURL: URL?

    // MARK: Init

    /// Parse `fixtureURL` (must be 16 kHz / mono / 16-bit PCM WAV). Throws if the
    /// file can't be read or isn't that format — fixtures are the tests' fault to
    /// get right, so surfacing it loudly beats silent zero-length replay.
    init(
        fixtureURL: URL,
        bufferSeconds: Double = 0.1,
        outputDirectory: URL? = nil
    ) throws {
        let wav = try WAVFile.read(fixtureURL)
        guard wav.sampleRate == 16_000, wav.channels == 1, wav.bitsPerSample == 16 else {
            throw WAVFile.Error.unsupportedFormat(
                "FileAudioCapture requires 16 kHz mono 16-bit PCM; got "
                + "\(wav.sampleRate) Hz, \(wav.channels)ch, \(wav.bitsPerSample)-bit"
            )
        }
        self.samples = wav.samples
        self.sampleRate = wav.sampleRate
        self.bufferSeconds = bufferSeconds
        self.outputDirectory = outputDirectory ?? FileAudioCapture.makeTempDir()
        try FileManager.default.createDirectory(
            at: self.outputDirectory, withIntermediateDirectories: true
        )
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhisp-fileaudio-\(UUID().uuidString)")
    }

    // MARK: Device selection

    func selectDevice(_ deviceID: String) { selectedDevices.append(deviceID) }

    // MARK: Single-file capture (legacy start/stop)

    func start() {
        startCount += 1
        isRecording = true
        onStateChanged?(.recording)
        // Emit levels across the whole fixture so callers observing levels behave
        // as they would live, then hold the full fixture as the pending result.
        emitLevels(over: samples)
        singleFileURL = writeChunk(samples: samples)
    }

    // MARK: Fixed-interval chunk streaming

    func startStreaming(chunkDuration: Double, onChunk: @escaping (URL?) -> Void) {
        startCount += 1
        isRecording = true
        onStateChanged?(.recording)

        let framesPerChunk = max(1, Int(chunkDuration * Double(sampleRate)))
        var start = 0
        while start < samples.count {
            let end = min(start + framesPerChunk, samples.count)
            let slice = Array(samples[start..<end])
            emitLevels(over: slice)
            let url = writeChunk(samples: slice)
            emittedChunkURLs.append(url)
            onChunk(url)
            start = end
        }
    }

    // MARK: Pause-based (silence) chunk streaming

    /// Reproduces `AudioRecorder.handlePauseBasedBuffer`: a chunk opens on the
    /// first speech buffer, accumulates buffer wall-time, and finalizes on a
    /// silence run after enough speech (or on reaching the length cap). Leading
    /// silence before the first speech is dropped; a chunk is emitted only if it
    /// has speech and meets `minimumSpeechDuration`.
    func startStreamingOnSilence(
        silenceDuration: TimeInterval,
        minimumSpeechDuration: TimeInterval,
        maximumSpeechDuration: TimeInterval,
        speechThreshold: Float,
        onChunk: @escaping (URL?) -> Void
    ) {
        startCount += 1
        isRecording = true
        onStateChanged?(.recording)

        let framesPerBuffer = max(1, Int(bufferSeconds * Double(sampleRate)))

        // Active-chunk accumulation, mirroring the recorder's instance state.
        var chunkSamples: [Int16] = []
        var chunkHasSpeech = false
        var chunkDuration = 0.0
        // Monotonic virtual clock: advance by each buffer's wall-time. Using a
        // virtual clock (not systemUptime) keeps the test deterministic.
        var now = 0.0
        var lastSpeechAt: Double? = nil

        func finalize() {
            let shouldEmit = chunkHasSpeech && chunkDuration >= minimumSpeechDuration
            if shouldEmit {
                let url = writeChunk(samples: chunkSamples)
                emittedChunkURLs.append(url)
                onChunk(url)
            }
            chunkSamples.removeAll(keepingCapacity: true)
            chunkHasSpeech = false
            chunkDuration = 0
            lastSpeechAt = nil
        }

        var start = 0
        while start < samples.count {
            let end = min(start + framesPerBuffer, samples.count)
            let buffer = Array(samples[start..<end])
            start = end

            let bufferDuration = Double(buffer.count) / Double(sampleRate)
            now += bufferDuration

            let rms = FileAudioCapture.rms(of: buffer)
            let hasSpeech = rms >= speechThreshold
            onLevelChanged?(AudioLevel.fromRMS(rms))

            // Chunk opens on first speech buffer; earlier silence is dropped.
            if hasSpeech && chunkSamples.isEmpty && !chunkHasSpeech {
                chunkDuration = 0
                chunkHasSpeech = true
            }
            // Nothing captured yet (still in leading silence): skip.
            if !chunkHasSpeech { continue }

            chunkSamples.append(contentsOf: buffer)
            chunkDuration += bufferDuration

            if hasSpeech {
                chunkHasSpeech = true
                lastSpeechAt = now
            }

            let silenceElapsed = now - (lastSpeechAt ?? now)
            let finalizeForSilence = chunkHasSpeech
                && chunkDuration >= minimumSpeechDuration
                && silenceElapsed >= silenceDuration
            let finalizeForLength = chunkDuration >= maximumSpeechDuration
            if finalizeForSilence || finalizeForLength {
                finalize()
            }
        }
        // Flush a trailing in-progress chunk (parity with stop() keeping the last
        // file when it has speech and meets the minimum).
        if chunkHasSpeech && chunkDuration >= minimumSpeechDuration {
            finalize()
        }
    }

    // MARK: Stop

    func stop(completion: ((URL?) -> Void)?) {
        stopCount += 1
        isRecording = false
        onStateChanged?(.stopped)
        completion?(singleFileURL)
        singleFileURL = nil
    }

    // MARK: - Level emission

    /// Emit `onLevelChanged` per synthetic buffer across `slice`, exactly as the
    /// live tap would, so level-observing logic runs for real.
    private func emitLevels(over slice: [Int16]) {
        guard onLevelChanged != nil else { return }
        let framesPerBuffer = max(1, Int(bufferSeconds * Double(sampleRate)))
        var start = 0
        while start < slice.count {
            let end = min(start + framesPerBuffer, slice.count)
            let rms = FileAudioCapture.rms(of: Array(slice[start..<end]))
            onLevelChanged?(AudioLevel.fromRMS(rms))
            start = end
        }
    }

    // MARK: - RMS (matches AudioRecorder.rmsLevel on normalized samples)

    /// `sqrt(mean(sample²))` over samples normalized to [-1, 1]. `AudioRecorder`
    /// computes this on float32 tap samples; Int16/32768 is the same value.
    static func rms(of buffer: [Int16]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        var sum: Float = 0
        for s in buffer {
            let f = Float(s) / 32768.0
            sum += f * f
        }
        return (sum / Float(buffer.count)).squareRoot()
    }

    // MARK: - Chunk WAV writing

    private func writeChunk(samples: [Int16]) -> URL {
        let name = "chunk_\(chunkIndex)_\(UUID().uuidString).wav"
        chunkIndex += 1
        let url = outputDirectory.appendingPathComponent(name)
        try? WAVFile.write(samples: samples, to: url)
        return url
    }
}

/// Minimal Foundation-only WAV (RIFF/PCM) reader+writer for fixture replay. Only
/// supports the one format the app uses — 16-bit signed LE PCM, any sample
/// rate/channel count on read; write is 16 kHz mono. Not a general WAV library.
enum WAVFile {
    enum Error: Swift.Error, Equatable {
        case notRIFF
        case noDataChunk
        case unsupportedFormat(String)
        case truncated
    }

    struct Parsed {
        let samples: [Int16]        // interleaved is impossible here (mono); raw Int16.
        let sampleRate: Int
        let channels: Int
        let bitsPerSample: Int
    }

    static func read(_ url: URL) throws -> Parsed {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Parsed {
        // RIFF header: "RIFF" <size> "WAVE", then chunks.
        guard data.count >= 12,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,  // "RIFF"
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 // "WAVE"
        else { throw Error.notRIFF }

        var offset = 12
        var sampleRate = 0, channels = 0, bitsPerSample = 0
        var dataRange: Range<Int>? = nil

        func u32(_ at: Int) -> Int {
            Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int {
            Int(data[at]) | Int(data[at + 1]) << 8
        }

        while offset + 8 <= data.count {
            let id = data.subdata(in: offset..<offset + 4)
            let size = u32(offset + 4)
            let body = offset + 8
            guard body + size <= data.count else {
                // Some encoders pad; clamp the last chunk rather than throw.
                if id == Data("data".utf8) {
                    dataRange = body..<data.count
                }
                break
            }
            if id == Data("fmt ".utf8), size >= 16 {
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bitsPerSample = u16(body + 14)
            } else if id == Data("data".utf8) {
                dataRange = body..<(body + size)
            }
            // Chunks are word-aligned: pad odd sizes by one byte.
            offset = body + size + (size & 1)
        }

        guard let range = dataRange else { throw Error.noDataChunk }
        guard bitsPerSample == 16 else {
            throw Error.unsupportedFormat("only 16-bit PCM supported, got \(bitsPerSample)-bit")
        }

        let pcm = data.subdata(in: range)
        var samples = [Int16](repeating: 0, count: pcm.count / 2)
        samples.withUnsafeMutableBytes { dst in
            pcm.withUnsafeBytes { src in
                // Little-endian on all Apple platforms; a straight copy is correct.
                dst.copyBytes(from: src.prefix(dst.count))
            }
        }
        return Parsed(
            samples: samples, sampleRate: sampleRate,
            channels: channels, bitsPerSample: bitsPerSample
        )
    }

    /// Write mono 16 kHz 16-bit LE PCM — the exact on-disk format `AudioRecorder`
    /// produces (`makeSettings`), so real engines transcribe these chunks.
    static func write(samples: [Int16], to url: URL) throws {
        let sampleRate = 16_000, channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * 2

        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendU32(_ v: Int) {
            var le = UInt32(v).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: Int) {
            var le = UInt16(v).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendU32(36 + dataBytes)     // file size minus first 8 bytes
        appendString("WAVE")
        appendString("fmt ")
        appendU32(16)                 // PCM fmt chunk size
        appendU16(1)                  // audio format = PCM
        appendU16(channels)
        appendU32(sampleRate)
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        appendString("data")
        appendU32(dataBytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        try data.write(to: url)
    }
}
