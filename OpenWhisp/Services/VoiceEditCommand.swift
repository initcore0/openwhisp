import Foundation

/// A deterministic *spoken edit command* — a small, fixed set of verbs that edit
/// the in-progress dictation BEFORE it is committed to the target app: "scratch
/// that", "delete last word", "delete last sentence", "new paragraph", "new
/// line", "undo".
///
/// This is intentionally NOT the LLM refine flow (`InstructionChain` /
/// `RefineFlow`), which does whole-text transforms via a model. These verbs are
/// pure, offline, and unambiguous, so they live in a pure parser (like the old
/// `VoiceCommandParser`) scoped strictly to editing. Freeform LLM-driven editing
/// ("change 'happy' to 'glad'") is a deliberate follow-up and is NOT handled here.
///
/// Two halves live in this file:
///   - `VoiceEditCommand` + `parse(_:)`: recognize whether a finalized utterance
///     is an edit command (and which), tolerant of case/whitespace/punctuation.
///   - `VoiceEditBuffer`: the minimal model the commands operate on — an ordered
///     list of committed utterances with a one-level scratch/undo history — plus
///     `apply(_:)` that mutates it deterministically.
public enum VoiceEditCommand: Equatable, Sendable {
    /// Drop the last committed utterance entirely ("scratch that").
    case scratchThat
    /// Delete the last word of the flattened buffer text.
    case deleteLastWord
    /// Delete the last sentence of the flattened buffer text.
    case deleteLastSentence
    /// Append a paragraph break ("\n\n").
    case newParagraph
    /// Append a line break ("\n").
    case newLine
    /// Restore whatever the most recent destructive command removed.
    case undo

    /// Recognize an edit command in a finalized utterance, or return `nil` when
    /// it's ordinary dictation.
    ///
    /// Deliberately strict: the utterance must be ONLY the command (after
    /// trimming surrounding whitespace and punctuation), so ordinary dictation
    /// that merely CONTAINS these words is never hijacked — "scratch the surface"
    /// or "delete the last word from the file" stay as content. This mirrors
    /// `MetaInstructionStripper`'s bias: a false positive (eating real speech) is
    /// far worse than a missed command the user can repeat.
    public static func parse(_ utterance: String) -> VoiceEditCommand? {
        // Lowercase, collapse internal whitespace, and strip surrounding
        // punctuation/whitespace so "Scratch that." / "  undo  " / "New line!"
        // all normalize to the bare phrase.
        let normalized = utterance
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: punctuationAndWhitespace)

        guard !normalized.isEmpty else { return nil }
        return phrases[normalized]
    }

    /// Exact (post-normalization) phrase → command. A dictionary rather than
    /// fuzzy matching keeps recognition unambiguous and the false-positive rate
    /// at zero; synonyms are just extra keys.
    private static let phrases: [String: VoiceEditCommand] = [
        "scratch that": .scratchThat,
        "delete last word": .deleteLastWord,
        "delete the last word": .deleteLastWord,
        "delete last sentence": .deleteLastSentence,
        "delete the last sentence": .deleteLastSentence,
        "new paragraph": .newParagraph,
        "new line": .newLine,
        "newline": .newLine,
        "undo": .undo,
        "undo that": .undo,
    ]

    /// Everything trimmed from the ends before matching: whitespace plus the
    /// punctuation whisper tends to append to a short spoken command.
    private static let punctuationAndWhitespace =
        CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:\"'`-"))
}

/// The minimal, correct model the edit commands operate on: an ordered list of
/// committed utterances plus a one-level history so `scratchThat` / `undo` can
/// restore what they removed.
///
/// Utterances are kept as separate elements (not one flattened string) so
/// "scratch that" can drop exactly the last spoken chunk and "undo" can put it
/// back verbatim. `text` flattens them (joined by spaces, with newline breaks
/// standing alone) for the word/sentence operations and for the final paste.
public struct VoiceEditBuffer: Equatable, Sendable {
    /// The committed utterances / break markers, in order. A `newParagraph` /
    /// `newLine` is stored as its own literal element ("\n\n" / "\n") so it
    /// survives a later "scratch that" cleanly.
    public private(set) var utterances: [String]

    /// Snapshot of `utterances` before the last destructive edit, for one-level
    /// undo. `nil` when there's nothing to undo (fresh buffer, or the last edit
    /// was itself an `undo`).
    private var undoSnapshot: [String]?

    public init(utterances: [String] = []) {
        self.utterances = utterances
        self.undoSnapshot = nil
    }

    /// Append a finalized dictation utterance to the buffer. This is ordinary
    /// dictation (not a command) — recording it as a distinct element is what
    /// lets a subsequent "scratch that" drop exactly this chunk. Empty/whitespace
    /// utterances are ignored.
    public mutating func append(_ utterance: String) {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        utterances.append(trimmed)
        // A new dictation chunk clears the redo-style snapshot: undo only ever
        // reverts the single most-recent destructive edit, not older dictation.
        undoSnapshot = nil
    }

    /// The flattened buffer as a single string ready to paste. Break markers
    /// ("\n" / "\n\n") attach without surrounding spaces; other utterances are
    /// space-joined.
    public var text: String {
        var result = ""
        for u in utterances {
            if u == "\n" || u == "\n\n" {
                // Trim any trailing space we may have added, then attach the break.
                while result.hasSuffix(" ") { result.removeLast() }
                result += u
            } else if result.isEmpty || result.hasSuffix("\n") {
                result += u
            } else {
                result += " " + u
            }
        }
        return result
    }

    /// Apply an edit command, mutating the buffer. Deterministic and total: every
    /// command is a safe no-op on an empty buffer (and `undo` is a no-op when
    /// there's nothing to restore).
    public mutating func apply(_ command: VoiceEditCommand) {
        switch command {
        case .scratchThat:
            dropLastUtterance()
        case .deleteLastWord:
            editFlattened { Self.removingLastWord(from: $0) }
        case .deleteLastSentence:
            editFlattened { Self.removingLastSentence(from: $0) }
        case .newParagraph:
            appendBreak("\n\n")
        case .newLine:
            appendBreak("\n")
        case .undo:
            undo()
        }
    }

    // MARK: - Command implementations

    private mutating func dropLastUtterance() {
        guard !utterances.isEmpty else { return }
        undoSnapshot = utterances
        utterances.removeLast()
    }

    private mutating func appendBreak(_ marker: String) {
        // A break isn't destructive, but recording a snapshot lets "undo" remove
        // an accidental "new paragraph" too.
        undoSnapshot = utterances
        utterances.append(marker)
    }

    private mutating func undo() {
        guard let snapshot = undoSnapshot else { return }
        utterances = snapshot
        // One level only: a second consecutive "undo" is a no-op, never a redo.
        undoSnapshot = nil
    }

    /// Rewrite the buffer from a transform on its flattened text. Used by the
    /// word/sentence deletions, which operate on the joined text rather than the
    /// utterance list. The result is stored as a single utterance so it stays
    /// stable under further edits; empties collapse to an empty buffer.
    private mutating func editFlattened(_ transform: (String) -> String) {
        let flattened = text
        guard !flattened.isEmpty else { return }
        let edited = transform(flattened).trimmingCharacters(in: .whitespacesAndNewlines)
        undoSnapshot = utterances
        utterances = edited.isEmpty ? [] : [edited]
    }

    // MARK: - Pure text helpers

    /// Remove the trailing word (and any whitespace hugging it) from `text`.
    static func removingLastWord(from text: String) -> String {
        var s = Substring(text)
        // Drop trailing whitespace/newlines first so we delete the last *word*,
        // not a dangling space.
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        while let last = s.last, !last.isWhitespace { s = s.dropLast() }
        // Trim the now-trailing whitespace left behind by the removed word.
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }

    /// Remove the trailing sentence from `text`. A sentence ends at the last
    /// `.`/`!`/`?` (or newline); everything after the PREVIOUS terminator is the
    /// last sentence and is dropped. When there's only one sentence, the buffer
    /// empties.
    static func removingLastSentence(from text: String) -> String {
        var s = Substring(text)
        // Ignore trailing whitespace and the final terminator so we search for
        // the boundary that STARTS the last sentence.
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        while let last = s.last, Self.sentenceTerminators.contains(last) { s = s.dropLast() }

        // Walk back to the previous sentence terminator (or newline). Everything
        // up to and including it is kept; the last sentence after it is dropped.
        var idx = s.endIndex
        while idx > s.startIndex {
            let prev = s.index(before: idx)
            if Self.sentenceTerminators.contains(s[prev]) || s[prev] == "\n" {
                return String(s[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            idx = prev
        }
        // No earlier boundary — the whole thing was one sentence.
        return ""
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
}
