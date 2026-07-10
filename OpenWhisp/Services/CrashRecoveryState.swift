import Foundation

/// A marker the app writes when a dictation session starts capturing and clears
/// when it stops cleanly (MAK-40 crash recovery). If the marker survives to the
/// next launch, the previous session died mid-dictation (crash / force-quit / power
/// loss) and its partially-captured audio may still be on disk.
///
/// Foundation-only + Codable so it persists through the hardened `JSONStore`
/// quarantine path and the recovery decision is unit-testable without AppKit.
public struct CaptureRecoveryMarker: Codable, Equatable {
    /// Absolute path to the in-progress capture WAV (the file the recorder was
    /// writing when the session started). May no longer exist if the crash
    /// happened before any audio was flushed.
    public let wavPath: String
    /// When the session started capturing — shown to the user in the recover prompt.
    public let startedAt: Date
    /// The engine settings needed to re-run the audio through transcription, so a
    /// recovered session transcribes with the same engine the user had configured.
    public let language: String

    public init(wavPath: String, startedAt: Date, language: String) {
        self.wavPath = wavPath
        self.startedAt = startedAt
        self.language = language
    }
}

/// Pure resolution of what to offer the user on launch, given a persisted
/// capture marker and whether its audio file still exists on disk. Keeping this a
/// pure function (no FileManager, no AppKit) makes every branch `swift test`-able;
/// the app just supplies `markerAudioExists` from a `FileManager.fileExists` check.
public enum CrashRecoveryResolver {

    /// What the app should do about a leftover capture marker on launch.
    public enum Decision: Equatable {
        /// No marker, or a marker whose audio file is gone: nothing to recover —
        /// the app should just clear any stale marker and start clean.
        case nothingToRecover
        /// A marker AND its audio file are present: offer the user Recover
        /// (re-transcribe the salvaged audio) or Discard.
        case offerRecovery(CaptureRecoveryMarker)
    }

    /// Decide from the loaded marker (nil when none was written / it was cleared on
    /// a clean stop) and whether its audio file is still on disk.
    ///
    /// - A missing marker → `nothingToRecover` (the common, healthy case).
    /// - A marker whose audio no longer exists → `nothingToRecover` (the crash
    ///   happened before any audio was flushed, or the temp file was reaped — there
    ///   is nothing to salvage, so don't nag the user with a dead prompt).
    /// - A marker with surviving audio → `offerRecovery` with the marker.
    public static func decide(
        marker: CaptureRecoveryMarker?,
        markerAudioExists: Bool
    ) -> Decision {
        guard let marker, markerAudioExists else { return .nothingToRecover }
        return .offerRecovery(marker)
    }
}
