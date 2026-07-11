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

    /// Merge `chunks` into a single attributed transcript. Chunks are ordered by
    /// start time (stable on ties), blank chunks dropped, and consecutive
    /// same-speaker chunks joined under one `Speaker:` label. Returns an empty
    /// string when nothing survives.
    public static func merge(_ chunks: [Chunk]) -> String {
        // Trim + drop empties first so they never break a same-speaker run.
        let cleaned = chunks
            .enumerated()
            .compactMap { (seq, chunk) -> (seq: Int, chunk: Chunk)? in
                let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (seq, Chunk(speaker: chunk.speaker, start: chunk.start, text: trimmed))
            }
        // Stable sort by start time: `sorted(by:)` isn't guaranteed stable, so break
        // ties on the original sequence index to keep input order on equal starts.
        let ordered = cleaned
            .sorted { a, b in
                a.chunk.start != b.chunk.start ? a.chunk.start < b.chunk.start : a.seq < b.seq
            }
            .map { $0.chunk }

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
