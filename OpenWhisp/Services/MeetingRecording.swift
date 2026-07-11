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
    /// engines already consume (same as dictation chunks).
    var wavURL: URL
    var startedAt: Date
    var duration: TimeInterval
}
