import Foundation

// MARK: - TranscriptInterleaver (attributed transcript assembly)

/// Pure, Foundation-only merge of per-leg transcript chunks into one attributed
/// transcript with `Me:` / `Them:` speaker labels (MAK-52).
///
/// Meeting mode transcribes the mic leg ("Me") and the system-audio leg ("Them")
/// separately, each producing time-stamped chunks. This type interleaves those
/// chunks by start time into a single readable transcript so the summarizer — and
/// the reader — can attribute who said what.
///
/// It owns only the ordering + labeling *decisions* (no IO, no transcription), so
/// it is unit-tested via `swift test`:
///   - **ordering**: chunks are emitted in ascending start-time order,
///   - **ties**: equal start times keep a stable order (input order preserved —
///     `sorted(by:)` is not stable, so we sort on a `(start, sequence)` key),
///   - **merging**: consecutive chunks from the SAME speaker are joined into one
///     labeled line rather than repeating the label,
///   - **empties**: chunks whose text is blank/whitespace are skipped entirely.
///
/// "Them" is everyone on the remote side of the call (system audio is a single
/// mixed stream) — per-person diarization is a separate follow-on.
public enum TranscriptInterleaver {

    /// One transcribed chunk from a single leg.
    public struct Chunk: Equatable {
        /// Speaker label as it should appear (e.g. "Me", "Them").
        public let speaker: String
        /// Start offset of the chunk from the beginning of the meeting, in seconds.
        public let start: TimeInterval
        /// The transcribed text for this chunk.
        public let text: String

        public init(speaker: String, start: TimeInterval, text: String) {
            self.speaker = speaker
            self.start = start
            self.text = text
        }
    }

    /// The visible marker a caller records for a chunk whose transcription errored,
    /// so a failed segment shows up as an honest hole rather than silently vanishing
    /// from the transcript. Kept here (core) so both the coordinator and the tests
    /// share one spelling.
    public static let failedSegmentPlaceholder = "[transcription failed for this segment]"

    /// True when at least one chunk carries real transcribed text — i.e. non-blank
    /// and not the `failedSegmentPlaceholder`. Callers use this to decide whether a
    /// leg-based transcript is usable or a fallback (e.g. the mixed WAV) is needed.
    public static func hasMeaningfulText(_ chunks: [Chunk]) -> Bool {
        chunks.contains { chunk in
            let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != failedSegmentPlaceholder
        }
    }

    /// Trim + drop blank chunks, then order by start time (stable on ties — Swift's
    /// `sorted(by:)` isn't guaranteed stable, so ties break on input order). Shared
    /// by `merge` and `mergePlain` so both emit the same chunk sequence.
    private static func cleanedAndOrdered(_ chunks: [Chunk]) -> [Chunk] {
        chunks
            .enumerated()
            .compactMap { (seq, chunk) -> (seq: Int, chunk: Chunk)? in
                let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (seq, Chunk(speaker: chunk.speaker, start: chunk.start, text: trimmed))
            }
            .sorted { a, b in
                a.chunk.start != b.chunk.start ? a.chunk.start < b.chunk.start : a.seq < b.seq
            }
            .map { $0.chunk }
    }

    /// Merge `chunks` into a single PLAIN transcript — same ordering / trimming /
    /// empty-dropping as `merge`, but without speaker labels, joined with spaces.
    /// This is what a mixed-WAV decode of the same audio would approximate, so the
    /// coordinator can derive the plain `Meeting.transcript` from the two legs
    /// instead of transcribing the mixed WAV a third time (MAK-52 perf).
    public static func mergePlain(_ chunks: [Chunk]) -> String {
        cleanedAndOrdered(chunks).map { $0.text }.joined(separator: " ")
    }

    /// Merge `chunks` into a single attributed transcript. Chunks are ordered by
    /// start time (stable on ties), blank chunks dropped, and consecutive
    /// same-speaker chunks joined under one `Speaker:` label. Returns an empty
    /// string when nothing survives.
    public static func merge(_ chunks: [Chunk]) -> String {
        let ordered = cleanedAndOrdered(chunks)

        guard !ordered.isEmpty else { return "" }

        var lines: [String] = []
        var currentSpeaker: String? = nil
        var buffer: [String] = []

        func flush() {
            guard let speaker = currentSpeaker, !buffer.isEmpty else { return }
            lines.append("\(speaker): \(buffer.joined(separator: " "))")
            buffer.removeAll()
        }

        for chunk in ordered {
            if chunk.speaker != currentSpeaker {
                flush()
                currentSpeaker = chunk.speaker
            }
            buffer.append(chunk.text)
        }
        flush()

        return lines.joined(separator: "\n")
    }
}
