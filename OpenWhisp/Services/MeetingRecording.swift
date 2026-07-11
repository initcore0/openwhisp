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
/// the notification hand-off (JSON-encoded in `userInfo`) and unit tests.
struct MeetingRecording: Codable, Equatable {
    var id: UUID
    /// 16 kHz mono 16-bit PCM WAV — the canonical format the transcription
    /// engines already consume (same as dictation chunks).
    var wavURL: URL
    var startedAt: Date
    var duration: TimeInterval
}

public extension Notification.Name {
    /// Posted by the capture side when a meeting recording is finalized on disk.
    /// `userInfo["recording"]` holds a JSON-encoded `MeetingRecording` `Data`
    /// blob (Codable round-trip keeps the seam decoupled from the concrete type
    /// across the app/core boundary). The integration pass replaces/routes this
    /// to the pipeline; until then it is the delivery mechanism.
    static let openWhispMeetingRecordingFinished =
        Notification.Name("openWhispMeetingRecordingFinished")
}
