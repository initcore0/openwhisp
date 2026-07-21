// Shared measurement helpers for the engine benchmark harnesses
// (scripts/bench/engine-bench.sh, MAK-79). Each engine's harness compiles this
// file alongside its own entry point; there is no SwiftPM target so the sources
// are globbed by the runner.
//
// The harnesses all emit ONE machine-readable TSV line per fixture on stdout,
// prefixed `BENCH\t`, so the shell aggregator can build the markdown table
// without re-parsing free-form text:
//
//   BENCH<TAB>engine<TAB>model<TAB>fixture<TAB>audioSec<TAB>procSec<TAB>xRealtime<TAB>werPct<TAB>refWords<TAB>editDist<TAB>transcript
//
// WER is a deterministic word-level Levenshtein edit distance between the
// normalized reference and hypothesis, divided by the reference word count
// (the standard WER definition). Normalization lowercases, maps every
// non-alphanumeric to a space, and collapses whitespace — so punctuation and
// casing never count as errors, but word substitutions/insertions/deletions do.

import Foundation

/// Read a WAV's duration from its header (no AVFoundation, so every harness can
/// use it without pulling audio frameworks). Parses the canonical RIFF/WAVE
/// `fmt ` (byte rate) + `data` (chunk size) chunks. Falls back to 0 on any parse
/// failure — the caller then reports a 0x realtime, which is visibly wrong rather
/// than silently plausible.
enum WavDuration {
    static func seconds(path: String) -> Double {
        guard let data = FileManager.default.contents(atPath: path), data.count > 44 else { return 0 }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | UInt32(data[off + 1]) << 8
                | UInt32(data[off + 2]) << 16 | UInt32(data[off + 3]) << 24
        }
        func tag(_ off: Int) -> String {
            String(bytes: data[off..<off + 4], encoding: .ascii) ?? ""
        }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return 0 }
        var off = 12
        var byteRate: UInt32 = 0
        var dataBytes: UInt32 = 0
        while off + 8 <= data.count {
            let id = tag(off)
            let size = u32(off + 4)
            if id == "fmt " { byteRate = u32(off + 16) }
            if id == "data" { dataBytes = size; break }
            off += 8 + Int(size) + (Int(size) & 1) // chunks are word-aligned
        }
        guard byteRate > 0, dataBytes > 0 else { return 0 }
        return Double(dataBytes) / Double(byteRate)
    }
}

enum Bench {

    /// Lowercase, replace every non-alphanumeric scalar with a space, collapse
    /// runs of whitespace. Shared by reference and hypothesis so the comparison
    /// is punctuation/case-insensitive.
    static func normalizeWords(_ s: String) -> [String] {
        let lowered = s.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            out.append(CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " ")
        }
        return out.split(separator: " ").map(String.init)
    }

    /// Classic word-level Levenshtein edit distance (substitution/insertion/
    /// deletion each cost 1). Deterministic — no ties broken by ordering.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1,        // deletion
                             cur[j - 1] + 1,     // insertion
                             prev[j - 1] + cost) // substitution
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    struct WER {
        let refWords: Int
        let editDist: Int
        /// Percent; 0 when the reference is empty and the hypothesis is too.
        let percent: Double
    }

    /// WER = editDistance(ref, hyp) / max(refWordCount, 1) * 100.
    /// Reference empty (the silence fixture): 0% if hypothesis is also empty,
    /// else 100 * (hypothesis word count) capped at 100 to keep the number sane.
    static func wer(reference: String, hypothesis: String) -> WER {
        let ref = normalizeWords(reference)
        let hyp = normalizeWords(hypothesis)
        let dist = editDistance(ref, hyp)
        if ref.isEmpty {
            let pct = hyp.isEmpty ? 0.0 : min(100.0, Double(hyp.count) * 100.0)
            return WER(refWords: 0, editDist: hyp.count, percent: pct)
        }
        return WER(refWords: ref.count, editDist: dist,
                   percent: Double(dist) / Double(ref.count) * 100.0)
    }

    /// Read a WAV's duration (seconds) via AVFoundation-free header parsing is
    /// overkill; callers pass the value from the shell (afinfo). Kept as a helper
    /// for harnesses that already opened the file with AVAudioFile.
    static func loadReference(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Emit the canonical TSV bench line. `transcript` is flattened (tabs/newlines
    /// → spaces) so it stays on one line.
    static func emit(engine: String, model: String, fixture: String,
                     audioSec: Double, procSec: Double,
                     reference: String, transcript: String) {
        let w = wer(reference: reference, hypothesis: transcript)
        let x = procSec > 0 ? audioSec / procSec : 0
        let flat = transcript
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let cols = [
            "BENCH", engine, model, fixture,
            String(format: "%.3f", audioSec),
            String(format: "%.3f", procSec),
            String(format: "%.2f", x),
            String(format: "%.1f", w.percent),
            String(w.refWords),
            String(w.editDist),
            flat,
        ]
        print(cols.joined(separator: "\t"))
        // Human-friendly echo to stderr so the live run is readable.
        FileHandle.standardError.write(Data(String(
            format: "  %-24@  %5.2fx realtime  WER %5.1f%%  \"%@\"\n",
            fixture, x, w.percent, flat).utf8))
    }
}
