import Foundation

/// A small, dependency-free Markdown renderer for the Scratchpad's preview pane
/// (MAK-96).
///
/// OpenWhisp ships **zero external dependencies** — no Down, no cmark, no
/// swift-markdown — so this is a deliberately conservative line-based subset
/// parser rather than a CommonMark implementation. It covers what a dictated note
/// actually contains: headings, lists, emphasis, code, links, rules.
///
/// ## The governing rule: never lose or reorder content
///
/// Anything the parser does not recognize renders as **plain text**, verbatim.
/// There is no error path and no "skip this line" path — every input line produces
/// exactly one output paragraph, in order. That makes the failure mode "some
/// markup didn't get styled", never "my note lost a sentence". The tests pin this
/// for pathological inputs (unterminated fences, stray markers, deep nesting).
///
/// ## Structure
///
/// `render` returns a flat array of `Block`s, each carrying an `AttributedString`
/// plus the styling context the view needs (indent depth, code-block flag). The
/// view maps blocks to stacked `Text` views. Splitting it this way keeps the
/// renderer Foundation-only and macOS-13-safe (no SwiftUI, no
/// `AttributedString(markdown:)` behavior differences across OS versions), and
/// makes every block independently assertable in tests.
///
/// ## Known limitations (documented, not bugs)
/// - No tables, footnotes, reference links, HTML, or setext (`===`) headings.
/// - Emphasis is only stripped/styled when its markers are *balanced on one line*;
///   emphasis spanning lines renders as literal markers.
/// - Nested lists are flattened to a single indent level per leading marker.
/// - Link targets are not validated or resolved; the label is what renders.
public enum MarkdownPreviewRenderer {

    // MARK: - Output model

    /// One rendered block in the preview, in document order.
    public struct Block: Equatable {
        /// The kind of block, which decides its typography and spacing.
        public enum Kind: Equatable {
            case heading(level: Int)
            case paragraph
            /// A list item at `depth` (0 = top level), pre-marked with its bullet.
            case listItem(depth: Int)
            /// A line inside a fenced code block.
            case codeBlock
            case blockQuote
            case horizontalRule
            /// An intentionally blank spacer line.
            case blank
        }

        public let kind: Kind
        /// The block's styled text. Empty for `.horizontalRule` / `.blank`.
        public let text: AttributedString
        /// The block's raw source text, for tests and for copy fallbacks.
        public let plain: String

        public init(kind: Kind, text: AttributedString, plain: String) {
            self.kind = kind
            self.text = text
            self.plain = plain
        }
    }

    // MARK: - Entry point

    /// Render a note body into preview blocks. Total function: every input yields
    /// blocks, and the concatenated `plain` text preserves the source's content and
    /// order.
    public static func render(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var inFence = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fence toggling. A fence line carries no prose (only an optional
            // language tag, which the preview drops), so it emits a `.blank` rather
            // than nothing at all — that keeps the one-block-per-line invariant, so
            // a document of nothing but fence markers still renders as *something*
            // instead of silently vanishing. An UNTERMINATED fence simply means the
            // rest of the document is code; it never swallows content.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                blocks.append(Block(kind: .blank, text: AttributedString(), plain: ""))
                continue
            }
            if inFence {
                blocks.append(Block(kind: .codeBlock, text: codeAttributed(line), plain: line))
                continue
            }

            if trimmed.isEmpty {
                blocks.append(Block(kind: .blank, text: AttributedString(), plain: ""))
                continue
            }

            if ScratchpadText.isHorizontalRule(trimmed) {
                blocks.append(Block(kind: .horizontalRule, text: AttributedString(), plain: trimmed))
                continue
            }

            if let (level, body) = headingParts(trimmed) {
                blocks.append(Block(kind: .heading(level: level), text: inline(body), plain: body))
                continue
            }

            if trimmed.hasPrefix(">") {
                let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .blockQuote, text: inline(body), plain: body))
                continue
            }

            if let item = listItem(line) {
                blocks.append(Block(
                    kind: .listItem(depth: item.depth),
                    text: inline(item.marker + item.body),
                    plain: item.marker + item.body
                ))
                continue
            }

            blocks.append(Block(kind: .paragraph, text: inline(trimmed), plain: trimmed))
        }

        return blocks
    }

    /// The whole document as one `AttributedString`, blocks joined by newlines.
    /// Used by "Copy as Markdown"'s rich-text sibling and by tests that assert on
    /// the flattened result.
    public static func renderJoined(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (index, block) in render(text).enumerated() {
            if index > 0 { out += AttributedString("\n") }
            out += block.text
        }
        return out
    }

    // MARK: - Block parsing

    /// `#`–`######` + space. Returns nil for `#tag` (no space) and for 7+ hashes.
    static func headingParts(_ s: String) -> (level: Int, body: String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1
            idx = s.index(after: idx)
        }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        var body = String(s[idx...]).trimmingCharacters(in: .whitespaces)
        while body.hasSuffix("#") { body.removeLast() }
        return (level, body.trimmingCharacters(in: .whitespaces))
    }

    /// A list item: its indent depth, a normalized bullet, and its body.
    /// Bullets normalize to "• "; ordered markers keep their number ("1. ").
    static func listItem(_ line: String) -> (depth: Int, marker: String, body: String)? {
        let leadingSpaces = line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let depth = min(leadingSpaces / 2, 4)

        if first == "-" || first == "*" || first == "+" {
            let rest = trimmed.dropFirst()
            guard rest.first == " " else { return nil }
            return (depth, "• ", String(rest).trimmingCharacters(in: .whitespaces))
        }

        var digits = ""
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx].isNumber, digits.count < 9 {
            digits.append(trimmed[idx])
            idx = trimmed.index(after: idx)
        }
        guard !digits.isEmpty, idx < trimmed.endIndex, trimmed[idx] == "." || trimmed[idx] == ")" else {
            return nil
        }
        let afterPunct = trimmed.index(after: idx)
        guard afterPunct < trimmed.endIndex, trimmed[afterPunct] == " " else { return nil }
        let body = String(trimmed[afterPunct...]).trimmingCharacters(in: .whitespaces)
        return (depth, digits + ". ", body)
    }

    // MARK: - Inline parsing

    /// Style inline spans: links, code, bold, italic. Unbalanced markers stay literal.
    ///
    /// Order matters — code spans are extracted first so `` `a *b* c` `` keeps its
    /// asterisks, and links before emphasis so a bracketed label is not chopped.
    static func inline(_ s: String) -> AttributedString {
        var out = AttributedString()
        for run in inlineRuns(s) {
            var piece = AttributedString(run.text)
            if run.code {
                piece.inlinePresentationIntent = .code
            } else {
                if run.bold && run.italic {
                    piece.inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
                } else if run.bold {
                    piece.inlinePresentationIntent = .stronglyEmphasized
                } else if run.italic {
                    piece.inlinePresentationIntent = .emphasized
                }
            }
            if let target = run.link, let url = URL(string: target) {
                piece.link = url
            }
            out += piece
        }
        return out
    }

    /// A styled span of inline text.
    struct Run: Equatable {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var link: String?
    }

    /// Split a line into styled runs. Conservative: a marker only takes effect when
    /// a matching closer exists on the same line, otherwise it stays literal text.
    static func inlineRuns(_ s: String) -> [Run] {
        // 1. Code spans first — their contents are opaque to every other rule.
        var runs: [Run] = []
        for segment in splitCodeSpans(s) {
            if segment.code {
                runs.append(Run(text: segment.text, code: true))
            } else {
                runs.append(contentsOf: emphasisRuns(linkRuns(segment.text)))
            }
        }
        return runs.filter { !$0.text.isEmpty }
    }

    /// Split on balanced backtick pairs. An unmatched backtick stays literal.
    static func splitCodeSpans(_ s: String) -> [(text: String, code: Bool)] {
        var out: [(String, Bool)] = []
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "`") {
            let afterOpen = rest.index(after: open)
            guard afterOpen < rest.endIndex, let close = rest[afterOpen...].firstIndex(of: "`") else {
                break  // unterminated — the remainder is literal
            }
            if open > rest.startIndex { out.append((String(rest[..<open]), false)) }
            out.append((String(rest[afterOpen..<close]), true))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append((String(rest), false)) }
        return out
    }

    /// Turn `[label](target)` into a linked run, leaving other text as plain runs.
    static func linkRuns(_ s: String) -> [Run] {
        var out: [Run] = []
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[open...].firstIndex(of: "]"),
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(",
                  let paren = rest[rest.index(after: close)...].firstIndex(of: ")")
            else {
                // Not a link — emit through the bracket and keep scanning.
                let upTo = rest.index(after: open)
                out.append(Run(text: String(rest[..<upTo])))
                rest = rest[upTo...]
                continue
            }
            if open > rest.startIndex { out.append(Run(text: String(rest[..<open]))) }
            let label = String(rest[rest.index(after: open)..<close])
            let target = String(rest[rest.index(after: rest.index(after: close))..<paren])
            out.append(Run(text: label, link: target))
            rest = rest[rest.index(after: paren)...]
        }
        if !rest.isEmpty { out.append(Run(text: String(rest))) }
        return out
    }

    /// Apply bold/italic to the non-link runs, marker pair by marker pair.
    static func emphasisRuns(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs {
            if run.link != nil { out.append(run); continue }
            out.append(contentsOf: splitEmphasis(run.text))
        }
        return out
    }

    /// Split one plain string on balanced `**`/`__` then `*`/`_`.
    static func splitEmphasis(_ s: String) -> [Run] {
        for marker in ["**", "__"] {
            if let split = splitOnPairedMarker(s, marker: marker, bold: true, italic: false) {
                return split
            }
        }
        for marker in ["*", "_"] {
            if let split = splitOnPairedMarker(s, marker: marker, bold: false, italic: true) {
                return split
            }
        }
        return [Run(text: s)]
    }

    /// Split on the FIRST balanced pair of `marker`, recursing into the remainder.
    /// Returns nil when there is no balanced pair (the caller keeps the text literal).
    static func splitOnPairedMarker(_ s: String, marker: String, bold: Bool, italic: Bool) -> [Run]? {
        guard let openRange = s.range(of: marker) else { return nil }
        let afterOpen = openRange.upperBound
        guard afterOpen < s.endIndex,
              let closeRange = s.range(of: marker, range: afterOpen..<s.endIndex)
        else { return nil }
        let inner = String(s[afterOpen..<closeRange.lowerBound])
        // An empty pair ("**") is not emphasis — leave it literal.
        guard !inner.isEmpty else { return nil }

        var out: [Run] = []
        let prefix = String(s[s.startIndex..<openRange.lowerBound])
        if !prefix.isEmpty { out.append(contentsOf: splitEmphasis(prefix)) }
        out.append(Run(text: inner, bold: bold, italic: italic))
        let suffix = String(s[closeRange.upperBound...])
        if !suffix.isEmpty { out.append(contentsOf: splitEmphasis(suffix)) }
        return out
    }

    /// A code-block line: monospaced, no inline parsing at all.
    static func codeAttributed(_ line: String) -> AttributedString {
        var piece = AttributedString(line)
        piece.inlinePresentationIntent = .code
        return piece
    }
}
