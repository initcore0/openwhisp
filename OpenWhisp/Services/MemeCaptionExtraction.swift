import Foundation

/// Reading the captions straight out of what the user said.
///
/// ## Why this exists — the v6 failure it removes
///
/// The v6 report: "expanding brain: typing, dictating, dictating memes, dictating
/// memes by voice" picked Expanding Brain correctly (4 slots) and then rendered TWO
/// captions. The model had answered in the legacy `top_text`/`bottom_text` shape, the
/// backward-compatible parser accepted it, and nothing checked the count against the
/// template's structure.
///
/// The prompt could be tightened again — v6 already tightened it twice — but that is
/// treating a symptom. Look at what the user actually said: the four captions are
/// RIGHT THERE, comma-separated, in order, after a colon. Asking a 1.5B local model to
/// re-derive from that dictation the four strings it was handed is inventing a
/// language task where none exists, and every such round-trip is a chance to get two
/// back instead of four.
///
/// So v7 reads them directly. When the description is LIST-SHAPED, the items become
/// the captions verbatim and the LLM never writes captions at all — it is left with
/// the one job it is actually needed for, picking a template. A model cannot return
/// the wrong number of captions for a request that was never made.
///
/// ## What counts as list-shaped
///
/// Deliberately narrow. This runs BEFORE the LLM on every generate, so a false
/// positive would hijack ordinary prose ("make me a drake meme about rust, python and
/// go" is prose *about* three things, not a three-caption list) and produce a meme of
/// fragments. The rules that follow are what keep it honest:
///
/// * There must be a **separator that means enumeration** — a colon introducing the
///   list, an explicit numbering, or newlines. A bare comma run inside a sentence is
///   NOT enough on its own, because that is how people write ordinary prose.
/// * The item count must be **plausible** (`minimumItems`…`maximumItems`). One item is
///   not a list, and past eight it is a monologue that no template has slots for.
/// * Every item must be **caption-sized**. A "list" whose entries run to sentence
///   length is prose with commas in it, not a set of captions.
///
/// Prose that fails any of these falls through to the v6 LLM caption path completely
/// unchanged. That is the design: this is a fast path over the existing one, never a
/// replacement for it.
public enum MemeCaptionExtraction {

    /// The fewest items that can be a list. Two — a one-item "list" is a phrase, and
    /// treating it as one would hijack every ordinary description ending in a colon.
    public static let minimumItems = 2

    /// The most items we will read out. Matches `MemeCaptionSlots.maximum`: past the
    /// slot ceiling there is no template that could hold them, so the extraction would
    /// be discarded anyway.
    public static let maximumItems = MemeCaptionSlots.maximum

    /// The longest an item may be, in WORDS, before it stops looking like a caption.
    ///
    /// Six is generous for meme text (real captions run one to four words) and still
    /// tight enough to reject prose. The check is on words rather than characters so a
    /// language with long compounds isn't penalised for being itself — the concern is
    /// clause structure, not orthography.
    public static let maximumWordsPerItem = 6

    /// A description read as a list of captions.
    public struct Extraction: Equatable, Sendable {
        /// The caption items, in the order the user said them, cleaned but NOT
        /// uppercased — display casing stays `MemeCaptionLayout.displayText`'s job so
        /// the editor shows the user their own words.
        public let captions: [String]

        /// The text BEFORE the colon, when there was one: "expanding brain" from
        /// "expanding brain: typing, dictating, …".
        ///
        /// This is the template query, and separating it from the items is half the
        /// value of parsing the colon at all — without it the theme's words would be
        /// scored as though they were caption content, and with it the template search
        /// gets exactly the phrase the user used to name the meme.
        public let theme: String

        public init(captions: [String], theme: String = "") {
            self.captions = captions
            self.theme = theme
        }

        /// How many caption slots a template needs to hold this extraction.
        public var slotCount: Int { captions.count }
    }

    /// Read `description` as a list of captions, or return nil to use the LLM path.
    ///
    /// Nil is the common answer and the safe one: everything that isn't clearly a list
    /// falls through to v6's behaviour untouched.
    public static func extract(from description: String) -> Extraction? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (theme, body) = splitTheme(trimmed)
        // A colon is what licenses the comma form — see `commaItems`. Passed explicitly
        // rather than re-derived, because `body` has already had the theme removed and
        // can no longer answer the question about itself.
        guard let items = items(in: body, introducedByColon: !theme.isEmpty) else { return nil }

        return Extraction(captions: items, theme: theme)
    }

    /// Split "theme: a, b, c" into its theme and its list body.
    ///
    /// Only the FIRST colon splits, and only when something precedes it — a
    /// description that opens with a colon has no theme, and a colon inside an item
    /// ("me: no") must not re-split the list that already started.
    ///
    /// A colon is not required. "typing, dictating, dictating memes" with no theme is
    /// still a list; it just gives the template search nothing extra to work with.
    private static func splitTheme(_ text: String) -> (theme: String, body: String) {
        // Only ASCII ':' and its full-width counterpart. Not every punctuation mark
        // that resembles one — a stray ';' in prose would split sentences into
        // "themes" and turn ordinary text into a list.
        guard let range = text.rangeOfCharacter(from: CharacterSet(charactersIn: ":：")) else {
            return ("", text)
        }
        let theme = String(text[text.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A colon with nothing after it is punctuation, not a list introducer.
        guard !theme.isEmpty, !body.isEmpty else { return ("", text) }
        return (theme, body)
    }

    /// Break a list body into its items, or nil when it doesn't read as a list.
    ///
    /// Tries the enumeration forms in order of how strongly each SIGNALS a list, so a
    /// numbered list is never re-cut on its commas:
    ///
    /// 1. **Newlines** — one item per line, the shape of a dictated or pasted list.
    /// 2. **Explicit numbering** — "1. a 2. b", including "1)" and "(1)".
    /// 3. **Commas**, with "and"/"then" as the final joiner people actually speak —
    ///    only when a colon introduced the list (see `commaItems`).
    private static func items(in body: String, introducedByColon: Bool) -> [String]? {
        let candidates = [
            newlineItems(body),
            numberedItems(body),
            introducedByColon ? commaItems(body) : nil,
        ]
        for candidate in candidates {
            guard let items = candidate, isPlausibleList(items) else { continue }
            return items
        }
        return nil
    }

    /// One item per line. Leading bullets and numbers are stripped so a pasted list
    /// doesn't caption itself "1." — the marker is the syntax, never the content.
    private static func newlineItems(_ body: String) -> [String]? {
        let lines = body
            .split(whereSeparator: \.isNewline)
            .map { stripMarker(String($0)) }
            .filter { !$0.isEmpty }
        guard lines.count >= minimumItems else { return nil }
        return lines
    }

    /// Items introduced by "1.", "2)", "(3)" — the shape a model or a careful user
    /// writes when the order matters.
    ///
    /// Requires the numbering to START the list (the first marker must be at the
    /// beginning), so a sentence merely CONTAINING "2." isn't cut in half.
    private static func numberedItems(_ body: String) -> [String]? {
        let pattern = #"(?:^|\s)\(?(\d{1,2})[.):]\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let full = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = regex.matches(in: body, range: full)
        guard matches.count >= minimumItems else { return nil }
        // The list must OPEN with its first marker; anything before it is prose that
        // happens to precede a numbered run.
        guard matches[0].range.location <= 1 else { return nil }

        var items: [String] = []
        for (offset, match) in matches.enumerated() {
            let start = match.range.upperBound
            let end = offset + 1 < matches.count
                ? matches[offset + 1].range.lowerBound
                : full.upperBound
            guard start <= end,
                  let range = Range(NSRange(location: start, length: end - start), in: body)
            else { continue }
            let item = String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty { items.append(item) }
        }
        guard items.count >= minimumItems else { return nil }
        return items
    }

    /// Comma-separated items, accepting the spoken final joiners.
    ///
    /// **Only reached when a colon introduced the list.** This is the deliberate
    /// asymmetry that keeps prose safe: "make me a drake meme about rust, python and
    /// go" has commas but no introducer, and cutting it into three captions would be
    /// exactly the false positive this type must not produce. A colon is the user
    /// saying "here comes the list", and that is the signal we require.
    private static func commaItems(_ body: String) -> [String]? {
        let separated = body.replacingOccurrences(
            of: #"[,;]\s*(?:and|then|und|и|затем|потом)\s+"#,
            with: ",",
            options: [.regularExpression, .caseInsensitive])

        var items = separated
            .split(separator: ",")
            .map { stripMarker(String($0)) }
            .filter { !$0.isEmpty }

        // "a, b and c" — the last comma-free joiner, split only when it yields a
        // caption-sized tail. Prose ends in "and <clause>" far more often than a list
        // does, so the size check is what makes this safe.
        if items.count >= minimumItems - 1, let last = items.last {
            let tail = last.replacingOccurrences(
                of: #"^(.*?)\s+(?:and|then|und|и|затем|потом)\s+(.+)$"#,
                with: "$1\u{0}$2",
                options: [.regularExpression, .caseInsensitive])
            let halves = tail.split(separator: "\u{0}").map(String.init)
            if halves.count == 2, halves.allSatisfy({ isCaptionSized($0) }) {
                items.removeLast()
                items.append(contentsOf: halves)
            }
        }

        guard items.count >= minimumItems else { return nil }
        return items
    }

    /// Strip a leading list marker: "1.", "2)", "-", "•", "*".
    private static func stripMarker(_ item: String) -> String {
        item.replacingOccurrences(
            of: #"^\s*(?:\(?\d{1,2}[.):]|[-–—•*])\s*"#,
            with: "",
            options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether one item is short enough to be a caption rather than a clause.
    private static func isCaptionSized(_ item: String) -> Bool {
        let words = item.split(whereSeparator: { $0 == " " || $0.isNewline })
        return !words.isEmpty && words.count <= maximumWordsPerItem
    }

    /// Whether a set of items is a plausible caption list: a sane count, and every
    /// item caption-sized.
    ///
    /// The all-items rule is strict on purpose. A "list" with one sentence-length entry
    /// is prose that happens to contain commas, and accepting it would caption the meme
    /// with a fragment of a sentence — a worse outcome than falling through to the LLM.
    private static func isPlausibleList(_ items: [String]) -> Bool {
        guard items.count >= minimumItems, items.count <= maximumItems else { return false }
        return items.allSatisfy(isCaptionSized)
    }
}
