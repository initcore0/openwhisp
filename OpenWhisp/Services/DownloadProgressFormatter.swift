import Foundation

/// Pure, Foundation-only helper for turning raw download byte counts into a
/// progress fraction and a human-readable label. Kept free of AppKit/SwiftUI so
/// it can be unit-tested via the `OpenWhispCore` SwiftPM target.
enum DownloadProgressFormatter {

    /// Result of formatting a download progress snapshot.
    struct Progress: Equatable {
        /// Completion fraction in `0.0...1.0`, or `nil` when the total size is
        /// unknown (indeterminate progress).
        let fraction: Double?
        /// Human-readable status line, e.g. `"Downloading… 42% (62 / 147 MB)"`
        /// or `"Downloading… 62 MB"` when the total is unknown.
        let label: String

        /// Whether progress is indeterminate (no known total size).
        var isIndeterminate: Bool { fraction == nil }
    }

    /// Compute the completion fraction from byte counts.
    ///
    /// - Returns: A value in `0.0...1.0`, or `nil` when `totalBytesExpected`
    ///   is unknown (`<= 0`). The result is clamped so it never exceeds 1.0
    ///   even if a server over-reports written bytes.
    static func fraction(written: Int64, totalExpected: Int64) -> Double? {
        guard totalExpected > 0 else { return nil }
        let raw = Double(written) / Double(totalExpected)
        return min(max(raw, 0.0), 1.0)
    }

    /// Format a byte count into a compact "MB"/"GB" style string.
    static func byteLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    /// Build a full progress snapshot (fraction + label) from byte counts.
    ///
    /// - Parameters:
    ///   - written: Bytes downloaded so far.
    ///   - totalExpected: Total expected bytes, or `<= 0` if unknown.
    static func make(written: Int64, totalExpected: Int64) -> Progress {
        let frac = fraction(written: written, totalExpected: totalExpected)
        let writtenLabel = byteLabel(written)

        guard let frac else {
            // Unknown total — show only what we've downloaded so far.
            return Progress(fraction: nil, label: "Downloading… \(writtenLabel)")
        }

        let percent = Int((frac * 100).rounded())
        let totalLabel = byteLabel(totalExpected)
        return Progress(
            fraction: frac,
            label: "Downloading… \(percent)% (\(writtenLabel) / \(totalLabel))"
        )
    }
}
