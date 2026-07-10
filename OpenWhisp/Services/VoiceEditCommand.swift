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
    /// punctuation whisper tends to append to a short spoken command. Includes
    /// the non-ASCII marks Whisper commonly emits — the Unicode ellipsis `…`,
    /// curly quotes `’”“‘`, and CJK sentence punctuation `。！？，；：` — so
    /// "Scratch that…" or a curly-quoted command still normalizes to the bare
    /// phrase instead of missing the dictionary and being pasted as literal text.
    private static let punctuationAndWhitespace =
        CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:\"'`-…’”“‘。！？，；："))
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

    /// Rewrite the buffer from a transform that trims a suffix off its flattened
    /// text — the word/sentence deletions. The transform operates on the joined
    /// text (it must span utterance boundaries to find the last word/sentence),
    /// but the result is mapped BACK onto the original element list: fully removed
    /// elements are dropped, the boundary element is truncated in place, and every
    /// earlier utterance / break marker is kept verbatim.
    ///
    /// This preserves structure — a later "scratch that" still drops only the last
    /// chunk, not the whole dictation — which a naive "store the result as one
    /// flat utterance" would destroy. Empties collapse to an empty buffer.
    private mutating func editFlattened(_ transform: (String) -> String) {
        let flattened = text
        guard !flattened.isEmpty else { return }
        let edited = transform(flattened)
        undoSnapshot = utterances
        utterances = Self.reapplyTrim(original: utterances, editedFlattened: edited)
    }

    /// Rebuild the element list so its flattened `text` equals `editedFlattened`
    /// (which is `original` flattened with a trailing word/sentence removed), while
    /// keeping as many original element boundaries as possible.
    ///
    /// The deletes only ever remove a suffix, so `editedFlattened` (ignoring
    /// trailing whitespace) is a prefix of the original flattened text. We replay
    /// the same flattening element-by-element and stop at the retained length,
    /// truncating the element that straddles the boundary. Trailing empties and
    /// dangling break markers are dropped.
    static func reapplyTrim(original: [String], editedFlattened: String) -> [String] {
        // Retained length: the edited text minus trailing whitespace (a deleted
        // word/sentence leaves nothing meaningful hanging off the end).
        var retained = Substring(editedFlattened)
        while let last = retained.last, last.isWhitespace { retained = retained.dropLast() }
        let keepCount = retained.count
        if keepCount == 0 { return [] }

        var result: [String] = []
        var flatCount = 0            // characters emitted by `text` so far
        var needsSpace = false       // whether the next text element gets a leading join-space
        var endsWithNewline = false

        for element in original {
            if flatCount >= keepCount { break }

            if element == "\n" || element == "\n\n" {
                // Break markers contribute their own characters, no join-space.
                let breakLen = element.count
                if flatCount + breakLen <= keepCount {
                    result.append(element)
                    flatCount += breakLen
                    needsSpace = false
                    endsWithNewline = true
                }
                // A break that would exceed the boundary is simply dropped.
                continue
            }

            // A join-space precedes this element unless we're at the very start or
            // right after a newline — mirroring `text`.
            let joinSpace = (flatCount > 0 && !endsWithNewline && needsSpace) ? 1 : 0
            let available = keepCount - flatCount - joinSpace
            if available <= 0 { break }

            if element.count <= available {
                result.append(element)
                flatCount += joinSpace + element.count
            } else {
                // This element straddles the boundary — keep only its retained head.
                let head = String(element.prefix(available))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if !head.isEmpty { result.append(head) }
                flatCount += joinSpace + available
            }
            needsSpace = true
            endsWithNewline = false
        }

        // Drop a trailing break marker left with nothing after it.
        while let last = result.last, last == "\n" || last == "\n\n" {
            result.removeLast()
        }
        return result
    }

    // MARK: - Pure text helpers

    /// Remove the trailing word from `text`.
    ///
    /// If the text ends in a line/paragraph break (a trailing newline, possibly
    /// with a space between it and the last word), the break itself is what
    /// "delete last word" removes — it does NOT reach back through the break and
    /// eat the word before it. This keeps "new paragraph" then "delete last word"
    /// least-surprising: the accidental break goes, the preceding word stays.
    /// Only when there is no trailing break do we drop the last actual word.
    static func removingLastWord(from text: String) -> String {
        var s = Substring(text)
        // Drop trailing spaces/tabs (but NOT newlines) so a dangling space
        // doesn't count as the "word" while a real break is still detectable.
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }

        // A trailing newline means the last thing typed was a break: remove just
        // the break (all consecutive trailing newlines of one marker), leaving
        // the word before it intact.
        if let last = s.last, last.isNewline {
            while let l = s.last, l.isNewline { s = s.dropLast() }
            while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
            return String(s)
        }

        // Otherwise delete the trailing word, then trim the whitespace it leaves.
        while let last = s.last, !last.isWhitespace { s = s.dropLast() }
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }

    /// Remove the trailing sentence from `text`. A sentence ends at the last
    /// `.`/`!`/`?` (or newline); everything after the PREVIOUS *real* boundary is
    /// the last sentence and is dropped. When there's only one sentence, the
    /// buffer empties.
    ///
    /// The boundary check is context-aware: a `.` that is part of a decimal
    /// ("3.50") or that immediately follows a known abbreviation ("Mr.", "Dr.")
    /// or a lone capital initial ("J.") is NOT treated as a sentence end, so
    /// "The price is 3.50 dollars." and "I met Mr. Smith today." delete cleanly
    /// as single sentences. `!`/`?`/`\n` are always boundaries.
    static func removingLastSentence(from text: String) -> String {
        var s = Substring(text)
        // Ignore trailing whitespace and the final terminator so we search for
        // the boundary that STARTS the last sentence.
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        while let last = s.last, Self.sentenceTerminators.contains(last) { s = s.dropLast() }

        // Walk back to the previous *real* sentence boundary. Everything up to
        // and including it is kept; the last sentence after it is dropped.
        var idx = s.endIndex
        while idx > s.startIndex {
            let prev = s.index(before: idx)
            let ch = s[prev]
            if ch == "\n" || ch == "!" || ch == "?"
                || (ch == "." && Self.isSentenceEndingPeriod(in: s, at: prev)) {
                return String(s[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            idx = prev
        }
        // No earlier boundary — the whole thing was one sentence.
        return ""
    }

    /// Whether the `.` at `dotIndex` genuinely ends a sentence, rather than being
    /// a decimal point or an abbreviation dot. Conservative by design: when in
    /// doubt it returns `true` (treats it as a boundary), because the whole
    /// feature is "drop the last sentence" and over-keeping is safer than the
    /// decimal/abbreviation corruption the reviewer flagged.
    private static func isSentenceEndingPeriod(in s: Substring, at dotIndex: Substring.Index) -> Bool {
        // Decimal: a digit on both sides of the dot ("3.50") is never a boundary.
        let after = s.index(after: dotIndex)
        let nextChar: Character? = after < s.endIndex ? s[after] : nil
        let prevChar: Character? = dotIndex > s.startIndex ? s[s.index(before: dotIndex)] : nil
        if let p = prevChar, let n = nextChar, p.isNumber, n.isNumber {
            return false
        }

        // Abbreviation: the token immediately before the dot (its letters) is a
        // known abbreviation ("Mr", "Dr", …) or a single capital initial ("J").
        var start = dotIndex
        while start > s.startIndex {
            let before = s.index(before: start)
            if s[before].isLetter { start = before } else { break }
        }
        let token = s[start..<dotIndex]
        if token.isEmpty { return true }
        if Self.abbreviations.contains(token.lowercased()) { return false }
        // A lone capital letter ("I met J. Smith") reads as an initial, not an end.
        if token.count == 1, let only = token.first, only.isUppercase { return false }
        return true
    }

    /// Common title/abbreviation stems (without the trailing dot, lowercased)
    /// that should not be read as a sentence end. Deliberately short and
    /// conservative — just the everyday ones the reviewer named plus a few peers.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
        "vs", "etc", "no",
    ]

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
}

/// The pure decision that wires the parser + buffer into a live dictation session,
/// kept Foundation-only so the app's session glue and `swift test` share EXACTLY
/// the same routing logic (the AppState/SwiftUI layer only calls these — it makes
/// no routing decision of its own).
///
/// The recognizers OpenWhisp streams from (Apple Speech, WhisperKit) never deliver
/// one finalized-utterance-at-a-time: each emits a single, cumulative transcript
/// for the whole hold. `VoiceEditCommand.parse` only fires when the WHOLE utterance
/// is the command, so to make a spoken "scratch that" actually edit, that blob must
/// first be split into utterance-sized units. `segmentUtterances` does that on the
/// recognizer's own strong boundaries (sentence terminators / line breaks): a
/// "Scratch that." spoken as its own sentence becomes its own unit and is
/// recognized, while a command buried mid-sentence ("…the report scratch that let
/// me redo") stays in one unit and is left as literal text — the deliberate, safe
/// failure that matches the parser's zero-false-positive bias.
public enum VoiceEditRouter {
    /// Route ONE finalized utterance into the buffer. Returns `true` when it was an
    /// edit command (applied to the buffer, its literal words never entering the
    /// text), `false` when it was ordinary dictation (appended verbatim).
    ///
    /// This is the single seam the session wiring drives and the tests exercise, so
    /// "was this an edit command?" is decided in exactly one place.
    @discardableResult
    public static func route(_ utterance: String, into buffer: inout VoiceEditBuffer) -> Bool {
        if let command = VoiceEditCommand.parse(utterance) {
            buffer.apply(command)
            return true
        }
        buffer.append(utterance)
        return false
    }

    /// Route a whole (possibly multi-utterance) final transcript into the buffer by
    /// splitting it into utterance units first, then routing each in order. This is
    /// what turns a cumulative recognizer transcript ("Hello world. Scratch that.")
    /// into the sequence the buffer expects (append "Hello world.", then apply
    /// `scratchThat`). Ordinary prose with no standalone command lands as a single
    /// unit and is appended unchanged.
    ///
    /// The buffer is populated from empty here (the session owns one buffer, reset at
    /// the start of the hold), so routing the whole final is the one place utterances
    /// enter — the caller then reads `buffer.text` for the preview + the paste.
    public static func route(final transcript: String, into buffer: inout VoiceEditBuffer) {
        for unit in segmentUtterances(transcript) {
            route(unit, into: &buffer)
        }
    }

    /// Split a transcript into utterance units on the recognizer's strong
    /// boundaries — end-of-sentence punctuation (`.`/`!`/`?`) and line breaks — so a
    /// standalone spoken command that the recognizer punctuated as its own sentence
    /// surfaces as its own unit. The terminator stays attached to the unit it ends
    /// (so ordinary dictation round-trips: "Hi there." → one unit "Hi there.").
    ///
    /// Deliberately coarse: it does NOT try to find commands mid-sentence (that's
    /// out of scope by design). A transcript with no terminators is a single unit,
    /// exactly matching today's behavior for one continuous phrase.
    public static func segmentUtterances(_ transcript: String) -> [String] {
        var units: [String] = []
        var current = ""
        for ch in transcript {
            if ch == "\n" {
                // A line break ends the current unit but is not carried forward: the
                // buffer's own break markers come from "new line" / "new paragraph"
                // commands, not from raw transcript newlines.
                units.append(current)
                current = ""
                continue
            }
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                units.append(current)
                current = ""
            }
        }
        units.append(current)
        // Trim each unit and drop the empties left by consecutive terminators /
        // trailing whitespace. A transcript that segments to nothing (empty /
        // whitespace only) yields no units, so the caller appends nothing.
        return units
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
