import Foundation

/// Pure, testable export formatting for file-transcription results (MAK-36):
/// `.txt`, `.srt`, `.vtt`. Foundation-only, no I/O — the app writes the returned
/// string to disk.
///
/// The local engines surface only plain text per chunk, so subtitle timing is
/// **chunk-level**: each cue spans its `FileChunkPlan`'s `[start, end]` window.
/// (If a future engine seam exposes per-segment timestamps, the same formatter can
/// consume finer-grained cues — the cue model below is timing-agnostic.)

/// The export container format.
enum SubtitleFormat: String, CaseIterable, Codable, Equatable {
    case txt
    case srt
    case vtt

    var fileExtension: String { rawValue }

    var label: String {
        switch self {
        case .txt: return "Plain text (.txt)"
        case .srt: return "SubRip (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        }
    }
}

/// One timed cue: a text span with a start/end offset in seconds.
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleFormatter {

    /// Build cues from a job's chunk plan + per-chunk text. Empty chunks are
    /// skipped (a silent slice produces no cue). Cue end is clamped so it never
    /// precedes its start.
    static func cues(chunks: [FileChunkPlan], chunkTexts: [Int: String]) -> [SubtitleCue] {
        chunks.compactMap { chunk in
            guard let raw = chunkTexts[chunk.index] else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let end = max(chunk.end, chunk.start)
            return SubtitleCue(start: chunk.start, end: end, text: text)
        }
    }

    /// Render a full transcript in the requested format.
    static func render(_ format: SubtitleFormat, cues: [SubtitleCue]) -> String {
        switch format {
        case .txt: return renderTxt(cues)
        case .srt: return renderSRT(cues)
        case .vtt: return renderVTT(cues)
        }
    }

    /// Convenience: render straight from a job's chunk plan + texts.
    static func render(_ format: SubtitleFormat, chunks: [FileChunkPlan], chunkTexts: [Int: String]) -> String {
        render(format, cues: cues(chunks: chunks, chunkTexts: chunkTexts))
    }

    // MARK: - Formats

    private static func renderTxt(_ cues: [SubtitleCue]) -> String {
        // Plain text is just the transcript, one cue per line, trailing newline.
        cues.map(\.text).joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
    }

    private static func renderSRT(_ cues: [SubtitleCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))\n"
            out += cue.text + "\n\n"
        }
        return out
    }

    private static func renderVTT(_ cues: [SubtitleCue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(vttTimestamp(cue.start)) --> \(vttTimestamp(cue.end))\n"
            out += cue.text + "\n\n"
        }
        return out
    }

    // MARK: - Timestamps

    /// `HH:MM:SS,mmm` (SRT uses a comma before milliseconds).
    static func srtTimestamp(_ seconds: Double) -> String {
        timestamp(seconds, msSeparator: ",")
    }

    /// `HH:MM:SS.mmm` (WebVTT uses a dot).
    static func vttTimestamp(_ seconds: Double) -> String {
        timestamp(seconds, msSeparator: ".")
    }

    private static func timestamp(_ seconds: Double, msSeparator: String) -> String {
        // Round to whole milliseconds FIRST, then derive the fields, so a value
        // like 59.9996 rolls over to 00:01:00,000 (not the invalid 00:00:60,000).
        let totalMs = Int((max(0, seconds) * 1000.0).rounded())
        let hours = totalMs / 3_600_000
        let minutes = (totalMs % 3_600_000) / 60_000
        let secs = (totalMs % 60_000) / 1000
        let millis = totalMs % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, msSeparator, millis)
    }
}

// MARK: - Export naming

/// Pure naming for exported transcript files: given a source media path and a
/// format, produce the sibling output filename (e.g. `talk.mp4` → `talk.srt`).
/// De-collision is the caller's job at write time; this just derives the base.
enum TranscriptExportNaming {
    /// The default export filename for a source path + format: the source's base
    /// name with the format extension. `interview.m4a` + `.txt` → `interview.txt`.
    static func exportFileName(sourcePath: String, format: SubtitleFormat) -> String {
        let base = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? "transcript" : base
        return "\(safeBase).\(format.fileExtension)"
    }

    /// The default export path: the export filename placed in `directory` (defaults
    /// to the source file's own directory).
    static func exportPath(sourcePath: String, format: SubtitleFormat, directory: String? = nil) -> String {
        let dir = directory ?? (sourcePath as NSString).deletingLastPathComponent
        let name = exportFileName(sourcePath: sourcePath, format: format)
        return (dir as NSString).appendingPathComponent(name)
    }
}
