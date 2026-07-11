import Foundation

/// The hand-off from the meeting **capture** half (system audio + mic, built
/// concurrently) to the **pipeline** half (transcribe → summarize → store) for
/// MAK-50 "Meeting mode".
///
/// This is the seam contract both halves code against: capture produces one of these
/// when the user stops a recording (a finished 16 kHz mono 16-bit PCM WAV plus its
/// timing), and `MeetingPipelineCoordinator.ingest(_:)` turns it into a `Meeting` and
/// runs the pipeline. Kept deliberately tiny and Foundation-only so it's identical on
/// both branches and the integration merge is trivial.
///
/// App-only (not in `OpenWhispCore`'s `Package.swift`): the pipeline that consumes it
/// is `@MainActor` app glue. The *derived* persisted type (`Meeting`) lives in core
/// and is fully unit-tested.
struct MeetingRecording: Codable, Equatable {
    var id: UUID
    /// 16 kHz mono 16-bit PCM WAV on disk.
    var wavURL: URL
    var startedAt: Date
    var duration: TimeInterval
}
