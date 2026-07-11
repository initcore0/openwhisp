import Foundation

// MARK: - Meeting Recording (capture ↔ pipeline seam)

/// A finished meeting recording handed from capture (MAK-50 Part A) to the
/// pipeline (Part B: WAV → transcript → summary → UI).
///
/// This is the ONE shared contract between the two halves of Meeting mode. Both
/// the capture side and the pipeline side code against these exact four stored
/// properties so the integration merge is a no-op. Do NOT add/remove/rename
/// stored properties here without updating both sides.
///
/// Foundation-only so it lives in OpenWhispCore and is `Codable`/`Equatable` for
/// the hand-off and unit tests. The integration pass delivers it directly from
/// `MeetingCaptureSession` into `MeetingPipelineCoordinator.ingest(_:)` (a single
/// in-process call — no NotificationCenter hop).
struct MeetingRecording: Codable, Equatable {
    var id: UUID
    /// 16 kHz mono 16-bit PCM WAV — the canonical format the transcription
    /// engines already consume (same as dictation chunks). This is the MIXED
    /// (mic + system) recording; it stays the fallback + orphan-recovery artifact.
    var wavURL: URL
    var startedAt: Date
    var duration: TimeInterval
    /// MAK-52 speaker attribution: the two progressive leg WAVs written ALONGSIDE
    /// the mixed WAV (mic = "Me", system = "Them"). Optional so a leg-write failure
    /// degrades to mixed-only, and so orphan recovery can ingest with whatever
    /// exists. `decodeIfPresent` keeps old JSON (no leg fields) decodable.
    var micWavURL: URL?
    var systemWavURL: URL?

    init(
        id: UUID,
        wavURL: URL,
        startedAt: Date,
        duration: TimeInterval,
        micWavURL: URL? = nil,
        systemWavURL: URL? = nil
    ) {
        self.id = id
        self.wavURL = wavURL
        self.startedAt = startedAt
        self.duration = duration
        self.micWavURL = micWavURL
        self.systemWavURL = systemWavURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, wavURL, startedAt, duration, micWavURL, systemWavURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        wavURL = try c.decode(URL.self, forKey: .wavURL)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        micWavURL = try c.decodeIfPresent(URL.self, forKey: .micWavURL)
        systemWavURL = try c.decodeIfPresent(URL.self, forKey: .systemWavURL)
    }
}
