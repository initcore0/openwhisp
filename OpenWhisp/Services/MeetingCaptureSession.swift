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
    /// Most recent per-leg level (0…1) for a coarse UI meter.
    private(set) var level: Float = 0

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

        do {
            let url = try Self.newRecordingURL(id: recordingID)
            writer = try MeetingWAVWriter(url: url, sampleRate: Int(SystemAudioCapture.targetSampleRate))
        } catch {
            fail("Could not open the meeting recording file: \(error.localizedDescription)")
            return
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

            let recording = MeetingRecording(
                id: self.recordingID,
                wavURL: writer.url,
                startedAt: startedAt,
                duration: writer.duration
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
            let recording = MeetingRecording(id: self.recordingID, wavURL: writer.url,
                                             startedAt: startedAt, duration: writer.duration)
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

    private func ingest(_ samples: [Float], from leg: Leg) {
        queue.async { [weak self] in
            guard let self, self.writer != nil else { return }
            let mixed = leg == .system ? self.mixer.appendSystem(samples)
                                       : self.mixer.appendMic(samples)
            self.updateLevel(samples)
            guard !mixed.isEmpty else { return }
            try? self.writer?.append(mixed)
            self.writer?.sync()   // crash-safety: at most the un-flushed tail is lost
        }
    }

    private func updateLevel(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let normalized = AudioLevel.fromRMS(rms)
        DispatchQueue.main.async { self.level = normalized }
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

    private static func newRecordingURL(id: UUID) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        return try meetingsDirectory().appendingPathComponent("meeting_\(stamp)_\(id.uuidString).wav")
    }
}
