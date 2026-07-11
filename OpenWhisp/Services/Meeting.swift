import Foundation

/// One recorded meeting and its downstream artifacts (MAK-50, "Meeting mode").
///
/// A meeting starts life as a captured WAV (see `MeetingRecording`, produced by the
/// capture half) and progresses through transcription and local summarization. This
/// is the persisted record of that lifecycle: identity, timing, the transcript, the
/// Markdown summary, and the current `status`.
///
/// Pure and Foundation-only so it lives in `OpenWhispCore` and its Codable
/// round-trip / forward-compat decode is unit-tested via `swift test`. The effectful
/// orchestration (decode → engine → LLM) lives app-side in
/// `MeetingPipelineCoordinator`.
///
/// **Filename discipline:** a meeting stores only the WAV's *leaf* filename
/// (`wavFileName`), never a full path — mirroring `AudioRetentionPolicy`'s
/// leaf-guard. Deletes/reads resolve it against the meetings audio directory so a
/// crafted name can never traverse out of it. Use `MeetingWAVName` to validate.
public struct Meeting: Codable, Equatable, Identifiable {
    public let id: UUID
    /// When the recording began.
    public var startedAt: Date
    /// Recording length in seconds.
    public var duration: TimeInterval
    /// Leaf filename of the 16 kHz mono WAV in the meetings audio directory. Never a
    /// path — see `MeetingWAVName`.
    public var wavFileName: String?
    /// MAK-52: leaf filenames of the two per-speaker leg WAVs (mic = "Me", system =
    /// "Them") in the same audio directory, when captured. Never paths — same
    /// leaf-guard as `wavFileName`. `nil` when the meeting is mixed-only.
    public var micWavFileName: String?
    public var systemWavFileName: String?
    /// Full transcript once transcription completes. This is always the MIXED
    /// decode (unchanged pre-MAK-52 behavior).
    public var transcript: String?
    /// MAK-52: speaker-attributed transcript (`Me:` / `Them:` lines) built by
    /// interleaving the two leg decodes, when both legs were captured and both
    /// transcribed. `nil` when attribution wasn't available or failed — callers
    /// fall back to `transcript`. `decodeIfPresent` keeps old JSON decodable.
    public var attributedTranscript: String?
    /// Markdown summary (## Summary / ## Decisions / ## Action items) once
    /// summarization completes.
    public var summary: String?
    public var status: MeetingStatus

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        wavFileName: String? = nil,
        micWavFileName: String? = nil,
        systemWavFileName: String? = nil,
        transcript: String? = nil,
        attributedTranscript: String? = nil,
        summary: String? = nil,
        status: MeetingStatus = .recorded
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.wavFileName = wavFileName
        self.micWavFileName = micWavFileName
        self.systemWavFileName = systemWavFileName
        self.transcript = transcript
        self.attributedTranscript = attributedTranscript
        self.summary = summary
        self.status = status
    }

    // Explicit keys + a lenient decoder so a record written by a NEWER build (extra
    // fields, a status case this build doesn't know) still decodes here rather than
    // quarantining the whole store. Missing optionals default to nil; an
    // unrecognized status decodes to `.failed(reason:)` so nothing silently loses
    // its place in the list.
    private enum CodingKeys: String, CodingKey {
        case id, startedAt, duration, wavFileName, micWavFileName, systemWavFileName, transcript, attributedTranscript, summary, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        wavFileName = try c.decodeIfPresent(String.self, forKey: .wavFileName)
        micWavFileName = try c.decodeIfPresent(String.self, forKey: .micWavFileName)
        systemWavFileName = try c.decodeIfPresent(String.self, forKey: .systemWavFileName)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        attributedTranscript = try c.decodeIfPresent(String.self, forKey: .attributedTranscript)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .recorded
    }
}

/// The lifecycle stage of a `Meeting`. Codable as a tagged object so the
/// `failed(reason:)` payload survives a round-trip; a raw value this build doesn't
/// recognize decodes to `.failed` (forward-compat, see `Meeting.init(from:)`).
///
/// Flow: `recorded → transcribing → transcribed → summarizing → done`, with
/// `failed(reason:)` reachable from any working stage.
public enum MeetingStatus: Codable, Equatable {
    case recorded
    case transcribing
    case transcribed
    case summarizing
    case done
    case failed(reason: String)

    /// Short human label for a list row.
    public var label: String {
        switch self {
        case .recorded: return "Recorded"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Transcribed"
        case .summarizing: return "Summarizing"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// No further automatic work is scheduled from a terminal stage. `done` and
    /// `failed` are terminal; `transcribed` is a *resting* stage (transcription
    /// finished, summary is user/consent-gated) and is not terminal.
    public var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }

    /// The status a persisted meeting should be shown with after a fresh launch.
    ///
    /// `transcribing` / `summarizing` are *working* stages — they can only be true
    /// while the coordinator is actively driving the engine/LLM. Finding one in the
    /// store at launch means the app crashed or quit mid-work, so showing it verbatim
    /// would be a permanent spinner over work nobody is doing. Roll each working
    /// stage back to its resting predecessor so the work can simply be rerun:
    /// `transcribing → recorded`, `summarizing → transcribed`. Resting and terminal
    /// stages pass through unchanged.
    public var normalizedForLaunch: MeetingStatus {
        switch self {
        case .transcribing: return .recorded
        case .summarizing: return .transcribed
        default: return self
        }
    }

    // Tagged-union coding: {"kind":"failed","reason":"…"} etc. Unknown kinds decode
    // to `.failed` so a newer status can't crash an older reader.
    private enum CodingKeys: String, CodingKey { case kind, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "recorded": self = .recorded
        case "transcribing": self = .transcribing
        case "transcribed": self = .transcribed
        case "summarizing": self = .summarizing
        case "done": self = .done
        case "failed":
            let reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "Unknown error"
            self = .failed(reason: reason)
        default:
            self = .failed(reason: "Unrecognized status \"\(kind)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recorded: try c.encode("recorded", forKey: .kind)
        case .transcribing: try c.encode("transcribing", forKey: .kind)
        case .transcribed: try c.encode("transcribed", forKey: .kind)
        case .summarizing: try c.encode("summarizing", forKey: .kind)
        case .done: try c.encode("done", forKey: .kind)
        case .failed(let reason):
            try c.encode("failed", forKey: .kind)
            try c.encode(reason, forKey: .reason)
        }
    }
}

/// Leaf-filename guard for meeting WAVs — the meeting analogue of
/// `AudioRetentionPolicy.parseEntryID`. A stored `wavFileName` must be a bare leaf:
/// no path separators, no NUL, a `.wav` extension. Reject anything else so a delete
/// or read can never traverse out of the meetings audio directory.
public enum MeetingWAVName {
    public static let ext = "wav"

    /// The canonical leaf filename for a meeting's (mixed) WAV.
    public static func fileName(for id: UUID) -> String {
        "meeting-\(id.uuidString).\(ext)"
    }

    /// The canonical leaf filename for a meeting's mic ("Me") leg WAV (MAK-52).
    public static func micFileName(for id: UUID) -> String {
        "meeting-\(id.uuidString)-mic.\(ext)"
    }

    /// The canonical leaf filename for a meeting's system ("Them") leg WAV (MAK-52).
    public static func systemFileName(for id: UUID) -> String {
        "meeting-\(id.uuidString)-sys.\(ext)"
    }

    /// True when `name` is a safe bare `.wav` leaf (no traversal, no NUL).
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return false }
        guard name == URL(fileURLWithPath: name).lastPathComponent else { return false }
        return URL(fileURLWithPath: name).pathExtension.lowercased() == ext
    }
}
