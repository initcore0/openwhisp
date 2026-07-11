import Foundation
import AVFoundation
import CoreGraphics
import AppKit
@preconcurrency import ScreenCaptureKit

// MARK: - MeetingCaptureSession (app-only orchestrator)

/// Orchestrates one Meeting-mode capture (MAK-50 Part A): Screen Recording
/// preflight → spin up the system-audio leg (SCK) + mic leg (AVAudioEngine) →
/// mix through `MeetingMixer` → append progressively to a 16 kHz mono 16-bit WAV
/// under Application Support → on stop, finalize the header and hand back a
/// `MeetingRecording`.
///
/// Threading: all mutable session state is confined to `queue` (a serial queue).
/// Both capture legs deliver samples on their own queues; we hop onto `queue`
/// before touching the mixer/writer so mixing and WAV writes are ordered.
@available(macOS 13.0, *)
final class MeetingCaptureSession {

    enum State: Equatable { case idle, recording, finished, failed(String) }

    /// State changes (main thread) for the UI (menu title, indicator).
    var onStateChanged: ((State) -> Void)?
    /// Delivery of the finished recording (main thread). Set at `start` or passed to
    /// `stop`; used by BOTH the normal-stop and leg-failure salvage paths so there is
    /// exactly one delivery of any given recording. The integrator wires this to
    /// `MeetingPipelineCoordinator.ingest(_:)` — a single, direct ingest path (no
    /// NotificationCenter hop).
    var onFinished: ((MeetingRecording) -> Void)?

    private let queue = DispatchQueue(label: "com.openwhisp.app.meeting.session")
    private var systemLeg: SystemAudioCapture?
    private var micLeg: MeetingMicCapture?
    private var mixer = MeetingMixer()
    private var writer: MeetingWAVWriter?
    /// MAK-52 speaker-attribution legs: two progressive WAVs written ALONGSIDE the
    /// mixed WAV (mic = "Me", system = "Them"). Each leg's samples are written as
    /// they arrive — no mixing, no frontier alignment — so per-speaker transcription
    /// gets clean single-source audio. A leg-write failure must NOT fail the meeting:
    /// on any error we drop that writer and degrade to mixed-only.
    private var micWriter: MeetingWAVWriter?
    private var systemWriter: MeetingWAVWriter?
    private var micLegURL: URL?
    private var systemLegURL: URL?
    /// One filesystem stamp per capture session, shared by the mixed WAV and both
    /// legs so `recoverOrphanedRecordings` can group `meeting_<stamp>_<uuid>*`.
    private var sessionStamp = Int(Date().timeIntervalSince1970)
    private var startedAt: Date?
    private var recordingID = UUID()
    private var pendingID = UUID()
    private var pendingStartedAt = Date()
    private var state: State = .idle
    /// The id + start time of the in-flight recording, exposed so the integrator can
    /// thread the SAME id into the pipeline's live row (`beginRecording(id:startedAt:)`)
    /// before `stop` delivers the finished `MeetingRecording` under that id.
    var currentRecordingID: UUID { recordingID }
    var currentStartedAt: Date? { startedAt }
    /// Most recent mixed level (0…1) for a coarse UI meter.
    private(set) var level: Float = 0
    /// Most recent per-leg levels (0…1) for the MAK-52 talking indicator
    /// (mic = "You", system = "Them"). Coarse RMS mapped through `AudioLevel`, same
    /// as `level`. Updated on the main thread for the UI.
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0

    // MARK: Permission (MAK-24 style)

    /// True if the process already holds Screen Recording permission. Uses
    /// `CGPreflightScreenCaptureAccess` — it does NOT prompt.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Trigger the system Screen Recording prompt (first request only; afterwards
    /// macOS ignores it and the user must toggle it in System Settings). Returns
    /// the immediate grant state.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// UI guidance hook: open System Settings → Privacy → Screen Recording.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    /// Preflight permission and start both legs. Calls `onStateChanged` with
    /// `.recording` on success or `.failed` on any preflight/start error. The
    /// caller (AppState/menu) is responsible for refusing to start while a
    /// dictation is active (mic exclusivity — see `MeetingMicCapture`).
    /// - Parameters:
    ///   - id/startedAt: optionally supplied by the integrator so the pipeline's live
    ///     row (created at Start via `beginRecording(id:startedAt:)`) carries the SAME
    ///     id/timestamp as the finished `MeetingRecording` — the live row becomes the
    ///     real row. When omitted, a fresh id/now is used.
    func start(id: UUID = UUID(), startedAt startTime: Date = Date()) {
        guard state == .idle else { return }
        self.pendingID = id
        self.pendingStartedAt = startTime

        // Preflight Screen Recording. If missing, fire the request (first-run
        // prompt) and fail this attempt with clear guidance — the user grants,
        // then starts again. We never silently record mic-only.
        guard Self.hasScreenRecordingPermission() else {
            Self.requestScreenRecordingAccess()
            fail("Screen Recording permission is required to capture system audio. "
                 + "Grant it in System Settings → Privacy & Security → Screen Recording, then start the meeting again.")
            return
        }

        recordingID = pendingID
        mixer = MeetingMixer()
        startedAt = pendingStartedAt

        sessionStamp = Int(Date().timeIntervalSince1970)
        do {
            let url = try newRecordingURL(id: recordingID)
            writer = try MeetingWAVWriter(url: url, sampleRate: Int(SystemAudioCapture.targetSampleRate))
        } catch {
            fail("Could not open the meeting recording file: \(error.localizedDescription)")
            return
        }

        // MAK-52: open the two speaker-attribution leg WAVs alongside the mixed WAV.
        // Best-effort — a leg-open failure degrades to mixed-only (log + continue),
        // it never fails the meeting.
        micWriter = nil; systemWriter = nil; micLegURL = nil; systemLegURL = nil
        let rate = Int(SystemAudioCapture.targetSampleRate)
        if let micURL = try? newLegURL(id: recordingID, leg: "mic"),
           let mw = try? MeetingWAVWriter(url: micURL, sampleRate: rate) {
            micWriter = mw; micLegURL = micURL
        } else {
            NSLog("[Meeting] mic leg WAV unavailable — recording mixed-only attribution for this leg")
        }
        if let sysURL = try? newLegURL(id: recordingID, leg: "sys"),
           let sw = try? MeetingWAVWriter(url: sysURL, sampleRate: rate) {
            systemWriter = sw; systemLegURL = sysURL
        } else {
            NSLog("[Meeting] system leg WAV unavailable — recording mixed-only attribution for this leg")
        }

        let system = SystemAudioCapture()
        let mic = MeetingMicCapture()
        systemLeg = system
        micLeg = mic

        system.onSamples = { [weak self] samples in
            self?.ingest(samples, from: .system)
        }
        system.onError = { [weak self] msg in self?.legFailed(msg) }
        mic.onSamples = { [weak self] samples in
            self?.ingest(samples, from: .mic)
        }
        mic.onError = { [weak self] msg in self?.legFailed(msg) }

        // Mic first (synchronous); if it fails we never bring up SCK.
        do {
            try mic.start()
        } catch {
            teardownLegs()
            discardWriter()
            fail("Microphone capture failed: \(error.localizedDescription)")
            return
        }

        // System audio (async SCK start).
        Task { [weak self] in
            guard let self else { return }
            do {
                try await system.start()
                self.setState(.recording)
            } catch {
                self.teardownLegs()
                self.discardWriter()
                self.fail("System-audio capture failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stop both legs, drain the mixer, finalize the WAV, and deliver the finished
    /// `MeetingRecording` exactly once via `onFinished` (set here or at `start`).
    func stop(onFinished: ((MeetingRecording) -> Void)? = nil) {
        guard state == .recording else { return }
        if let onFinished { self.onFinished = onFinished }

        let system = systemLeg
        micLeg?.stop()

        // Stop SCK (async), then finalize on the session queue so any in-flight
        // buffers already enqueued on `queue` are written before we drain.
        Task { [weak self] in
            await system?.stop()
            self?.finalizeAndDeliver()
        }
    }

    /// Guards against a double delivery (normal stop racing a leg failure).
    private var delivered = false

    private func deliver(_ recording: MeetingRecording) {
        guard !delivered else { return }
        delivered = true
        onFinished?(recording)
    }

    private func finalizeAndDeliver() {
        queue.async { [weak self] in
            guard let self, let writer = self.writer, let startedAt = self.startedAt else { return }
            // Emit whichever leg ran longer (mixed with silence) so the tail isn't lost.
            let remainder = self.mixer.drainRemainder()
            if !remainder.isEmpty { try? writer.append(remainder) }
            writer.sync()
            do { try writer.finalize() } catch {
                DispatchQueue.main.async { self.setState(.failed("Finalizing the recording failed: \(error.localizedDescription)")) }
                return
            }

            let (micURL, sysURL) = self.finalizeLegs()
            let recording = MeetingRecording(
                id: self.recordingID,
                wavURL: writer.url,
                startedAt: startedAt,
                duration: writer.duration,
                micWavURL: micURL,
                systemWavURL: sysURL
            )
            self.teardownLegs()
            self.writer = nil

            DispatchQueue.main.async {
                self.setState(.finished)
                self.deliver(recording)
            }
        }
    }

    /// A leg failed mid-meeting: don't lose the recording — finalize what we have.
    private func legFailed(_ message: String) {
        queue.async { [weak self] in
            guard let self, self.state == .recording, let writer = self.writer,
                  let startedAt = self.startedAt else { return }
            let remainder = self.mixer.drainRemainder()
            if !remainder.isEmpty { try? writer.append(remainder) }
            writer.sync()
            try? writer.finalize()
            let (micURL, sysURL) = self.finalizeLegs()
            let recording = MeetingRecording(id: self.recordingID, wavURL: writer.url,
                                             startedAt: startedAt, duration: writer.duration,
                                             micWavURL: micURL, systemWavURL: sysURL)
            self.teardownLegs()
            self.writer = nil
            DispatchQueue.main.async {
                // Salvage: deliver the partial recording, then report the cause.
                self.setState(.finished)
                self.deliver(recording)
                self.setState(.failed(message))
            }
        }
    }

    // MARK: Ingestion

    private enum Leg { case system, mic }

    /// Stall bound: if one leg stops delivering, flush the other's tail (mixed
    /// with silence) beyond ~10 s so memory stays bounded and audio keeps
    /// reaching the WAV. 10 s of 16 kHz Float32 is ~640 KB — the ceiling.
    private static let maxPendingLeadFrames = Int(SystemAudioCapture.targetSampleRate) * 10

    private func ingest(_ samples: [Float], from leg: Leg) {
        queue.async { [weak self] in
            guard let self, self.writer != nil else { return }
            var mixed = leg == .system ? self.mixer.appendSystem(samples)
                                       : self.mixer.appendMic(samples)
            mixed += self.mixer.flushImbalance(over: Self.maxPendingLeadFrames)
            self.updateLevel(samples, from: leg)

            // MAK-52: write this leg's raw samples straight through to its own WAV
            // (no mixing/frontier — legs are single-source). A write failure drops
            // that leg writer and degrades to mixed-only; the meeting continues.
            self.writeLeg(samples, from: leg)

            guard !mixed.isEmpty else { return }
            try? self.writer?.append(mixed)
            self.writer?.sync()   // crash-safety: at most the un-flushed tail is lost
        }
    }

    /// Append raw leg samples to the matching leg writer (queue-confined). On any
    /// write failure, tear that leg writer down and forget its URL so the meeting
    /// degrades cleanly to mixed-only.
    private func writeLeg(_ samples: [Float], from leg: Leg) {
        guard !samples.isEmpty else { return }
        let writer = leg == .mic ? micWriter : systemWriter
        guard let writer else { return }
        do {
            try writer.append(samples)
            writer.sync()
        } catch {
            NSLog("[Meeting] leg WAV write failed — degrading to mixed-only for this leg: \(error.localizedDescription)")
            if leg == .mic { micWriter = nil; micLegURL = nil }
            else { systemWriter = nil; systemLegURL = nil }
        }
    }

    private func updateLevel(_ samples: [Float], from leg: Leg) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let normalized = AudioLevel.fromRMS(rms)
        DispatchQueue.main.async {
            // `level` tracks whichever leg most recently delivered (coarse meter,
            // unchanged); the per-leg levels feed the MAK-52 talking indicator.
            self.level = normalized
            if leg == .mic { self.micLevel = normalized } else { self.systemLevel = normalized }
        }
    }

    // MARK: Bookkeeping

    /// Elapsed wall-clock duration since start (for the UI). 0 when idle.
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    private func teardownLegs() {
        micLeg?.stop()
        micLeg = nil
        systemLeg = nil   // SCK stopCapture already awaited by caller
    }

    private func discardWriter() {
        if let url = writer?.url { try? FileManager.default.removeItem(at: url) }
        writer = nil
        discardLegs()
    }

    /// MAK-52: finalize whichever leg writers survived and return their URLs (nil
    /// for a leg that was never opened or failed mid-recording). Best-effort — a
    /// finalize failure drops that leg to nil so ingest never references a bad file.
    /// Queue-confined (called from `finalizeAndDeliver`/`legFailed`).
    private func finalizeLegs() -> (mic: URL?, system: URL?) {
        var mic: URL? = nil
        var sys: URL? = nil
        if let mw = micWriter {
            mw.sync()
            if (try? mw.finalize()) != nil { mic = micLegURL } else { try? FileManager.default.removeItem(at: mw.url) }
        }
        if let sw = systemWriter {
            sw.sync()
            if (try? sw.finalize()) != nil { sys = systemLegURL } else { try? FileManager.default.removeItem(at: sw.url) }
        }
        micWriter = nil; systemWriter = nil
        return (mic, sys)
    }

    /// Discard leg WAVs without delivering them (start-failure path).
    private func discardLegs() {
        if let url = micLegURL { try? FileManager.default.removeItem(at: url) }
        if let url = systemLegURL { try? FileManager.default.removeItem(at: url) }
        micWriter = nil; systemWriter = nil; micLegURL = nil; systemLegURL = nil
    }

    private func fail(_ message: String) {
        state = .failed(message)
        DispatchQueue.main.async { self.onStateChanged?(.failed(message)) }
    }

    private func setState(_ new: State) {
        state = new
        onStateChanged?(new)
    }

    // MARK: Storage + delivery

    static func meetingsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhisp/meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func newRecordingURL(id: UUID) throws -> URL {
        return try Self.meetingsDirectory().appendingPathComponent("meeting_\(sessionStamp)_\(id.uuidString).wav")
    }

    /// MAK-52 in-flight leg WAV name: `meeting_<stamp>_<uuid>_<leg>.wav`, beside the
    /// mixed WAV. The recovery sweep recognizes the `_mic`/`_sys` suffix.
    private func newLegURL(id: UUID, leg: String) throws -> URL {
        return try Self.meetingsDirectory().appendingPathComponent("meeting_\(sessionStamp)_\(id.uuidString)_\(leg).wav")
    }

    // MARK: Crash recovery (launch-time sweep)

    /// Salvage recordings orphaned by a crash/quit mid-meeting. In-flight capture
    /// files are named `meeting_<stamp>_<uuid>.wav` (mixed) plus, since MAK-52, the
    /// two leg WAVs `meeting_<stamp>_<uuid>_mic.wav` / `_sys.wav`. All carry a
    /// placeholder WAV header until `finalize()`; a successful ingest MOVES them to
    /// canonical names, so anything still matching the in-flight pattern at launch is
    /// an orphan. This patches each orphan's header from its on-disk length
    /// (`MeetingWAVWriter.recoverInPlace`), groups the legs with their mixed WAV by
    /// `<stamp>_<uuid>`, and returns `MeetingRecording`s ready for
    /// `MeetingPipelineCoordinator.ingest(_:)` — recovering with whatever legs exist
    /// (a leg alone with no mixed WAV is still recovered as its own recording so no
    /// audio is silently lost). Empty stubs are deleted. Call BEFORE any new capture.
    static func recoverOrphanedRecordings() -> [MeetingRecording] {
        guard let dir = try? meetingsDirectory() else { return [] }
        return recoverOrphanedRecordings(in: dir)
    }

    /// Testable core of the recovery sweep over an explicit directory. Name parsing
    /// + leg grouping live in the pure `MeetingOrphanScan` (unit-tested); here we do
    /// the filesystem IO: header recovery, empty-stub deletion, and size→duration.
    static func recoverOrphanedRecordings(in dir: URL) -> [MeetingRecording] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }

        // Recover each parseable file's header in place; drop empty (header-only)
        // stubs so a group only carries files that actually hold audio.
        var live = Set<String>()
        for name in names where MeetingOrphanScan.parse(name) != nil {
            let url = dir.appendingPathComponent(name)
            if MeetingWAVWriter.recoverInPlace(url: url) { live.insert(name) }
            else { try? FileManager.default.removeItem(at: url) }
        }

        func frames(_ url: URL) -> Int {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
            return max(0, size - 44) / 2
        }

        var recovered: [MeetingRecording] = []
        for g in MeetingOrphanScan.group(Array(live)) {
            let mixed = g.mixed.map { dir.appendingPathComponent($0) }
            let mic = g.mic.map { dir.appendingPathComponent($0) }
            let sys = g.system.map { dir.appendingPathComponent($0) }
            // Prefer the mixed WAV as the canonical `wavURL`; if only legs survived,
            // fall back to whichever leg exists so the recording isn't lost.
            guard let primary = mixed ?? mic ?? sys else { continue }
            recovered.append(MeetingRecording(
                id: g.id,
                wavURL: primary,
                startedAt: Date(timeIntervalSince1970: g.stamp),
                duration: Double(frames(primary)) / SystemAudioCapture.targetSampleRate,
                micWavURL: mic,
                systemWavURL: sys
            ))
        }
        return recovered
    }
}
