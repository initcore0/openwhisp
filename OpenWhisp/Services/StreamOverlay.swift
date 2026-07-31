import Foundation

// MARK: - Stream overlay (EXPERIMENT — live subtitles for Twitch/OBS)

/// Display configuration for the experimental streaming-subtitle overlay.
///
/// The overlay is a local web page a streamer adds as an OBS/Twitch "browser
/// source"; these parameters control the canvas it renders into and how the
/// captions look. Pure data — the page generator (`StreamOverlayPage`) and the
/// server consume it; nothing here touches an engine, a model, or AppKit.
public struct StreamOverlayConfig: Codable, Equatable, Sendable {
    /// Canvas size the browser source is expected to use (e.g. 1920x1080).
    public var canvasWidth: Int
    public var canvasHeight: Int
    /// CSS font-family for the caption text.
    public var fontFamily: String
    /// Caption font size in px.
    public var fontSize: Int
    /// Background color as a `#RRGGBB`/`#RRGGBBAA` hex string. Streamers often
    /// want full transparency (`#00000000`) so only the text shows over the game.
    public var backgroundColor: String
    /// Caption text color as a `#RRGGBB`/`#RRGGBBAA` hex string.
    public var textColor: String
    /// How many subtitle lines stay on screen (older lines scroll off).
    public var maxLines: Int
    /// Word-wrap budget per subtitle line, in characters (broadcast captions
    /// use ~32–42). The overlay windows to the LAST `maxLines` wrapped lines.
    public var charsPerLine: Int
    /// Captions disappear after this many seconds without new speech — the
    /// movie-subtitle behavior (an empty scene shows no stale text).
    public var lingerSeconds: Int
    /// When true the server runs published FINAL lines through its injected
    /// translator before broadcasting. Which translator (if any) is the caller's
    /// choice — the overlay itself never names an engine or model.
    public var translationEnabled: Bool
    /// BCP-47-ish target language tag for the injected translator (e.g. "es").
    public var targetLanguage: String
    /// Master switch for the SUBTITLE half of the overlay. Off means the page
    /// shows no captions and the server publishes no caption frames — the
    /// streamer who only wants voice-command widgets (the counter below) gets a
    /// page with nothing but those. Defaults true so every existing config keeps
    /// today's behavior.
    public var captionsEnabled: Bool
    /// Master switch for the voice-command phrase counter.
    public var counterEnabled: Bool
    /// The trigger phrase the streamer says on stream (e.g. "I died again", or
    /// its Russian equivalent). Matched case/punctuation-insensitively on WORD
    /// boundaries — see `OverlayVoiceCommandMatcher`.
    public var counterPhrase: String
    /// Label shown next to the count on the overlay (e.g. "Deaths").
    public var counterLabel: String
    /// Which corner of the canvas the counter block sits in.
    public var counterCorner: StreamOverlayCorner

    public init(
        canvasWidth: Int = 1920,
        canvasHeight: Int = 1080,
        fontFamily: String = "-apple-system, 'Helvetica Neue', sans-serif",
        fontSize: Int = 48,
        backgroundColor: String = "#00000000",
        textColor: String = "#FFFFFF",
        maxLines: Int = 3,
        charsPerLine: Int = 42,
        lingerSeconds: Int = 4,
        translationEnabled: Bool = false,
        targetLanguage: String = "",
        captionsEnabled: Bool = true,
        counterEnabled: Bool = false,
        counterPhrase: String = "",
        counterLabel: String = "Counter",
        counterCorner: StreamOverlayCorner = .bottomRight
    ) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.maxLines = maxLines
        self.charsPerLine = charsPerLine
        self.lingerSeconds = lingerSeconds
        self.translationEnabled = translationEnabled
        self.targetLanguage = targetLanguage
        self.captionsEnabled = captionsEnabled
        self.counterEnabled = counterEnabled
        self.counterPhrase = counterPhrase
        self.counterLabel = counterLabel
        self.counterCorner = counterCorner
    }

    /// Backward-compatible decode: fields added after the first release fall
    /// back to their defaults, so a saved v1 config JSON still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StreamOverlayConfig()
        canvasWidth = try c.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? defaults.canvasWidth
        canvasHeight = try c.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? defaults.canvasHeight
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? defaults.fontFamily
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? defaults.fontSize
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor) ?? defaults.backgroundColor
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor) ?? defaults.textColor
        maxLines = try c.decodeIfPresent(Int.self, forKey: .maxLines) ?? defaults.maxLines
        charsPerLine = try c.decodeIfPresent(Int.self, forKey: .charsPerLine) ?? defaults.charsPerLine
        lingerSeconds = try c.decodeIfPresent(Int.self, forKey: .lingerSeconds) ?? defaults.lingerSeconds
        translationEnabled = try c.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? defaults.translationEnabled
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? defaults.targetLanguage
        // Added with the voice-command counter. `captionsEnabled` defaulting to
        // TRUE is what preserves today's behavior for every already-saved config
        // (an overlay that used to show subtitles keeps showing them).
        captionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .captionsEnabled) ?? defaults.captionsEnabled
        counterEnabled = try c.decodeIfPresent(Bool.self, forKey: .counterEnabled) ?? defaults.counterEnabled
        counterPhrase = try c.decodeIfPresent(String.self, forKey: .counterPhrase) ?? defaults.counterPhrase
        counterLabel = try c.decodeIfPresent(String.self, forKey: .counterLabel) ?? defaults.counterLabel
        counterCorner = try c.decodeIfPresent(StreamOverlayCorner.self, forKey: .counterCorner) ?? defaults.counterCorner
    }

    /// True iff `value` is a `#RGB`, `#RRGGBB`, or `#RRGGBBAA` hex color.
    public static func isValidHexColor(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let digits = value.dropFirst()
        guard [3, 6, 8].contains(digits.count) else { return false }
        return digits.allSatisfy { $0.isHexDigit }
    }

    /// A copy with every field clamped/defaulted into a renderable range, so a
    /// hand-edited or wire-supplied config can never produce a broken page
    /// (zero-size canvas, unparseable color, hostile font string).
    public func sanitized() -> StreamOverlayConfig {
        var c = self
        c.canvasWidth = min(max(c.canvasWidth, 320), 7_680)
        c.canvasHeight = min(max(c.canvasHeight, 180), 4_320)
        c.fontSize = min(max(c.fontSize, 8), 400)
        c.maxLines = min(max(c.maxLines, 1), 10)
        c.charsPerLine = min(max(c.charsPerLine, 16), 120)
        c.lingerSeconds = min(max(c.lingerSeconds, 1), 30)
        if !Self.isValidHexColor(c.backgroundColor) { c.backgroundColor = "#00000000" }
        if !Self.isValidHexColor(c.textColor) { c.textColor = "#FFFFFF" }
        // The font family is interpolated into CSS — strip anything that could
        // escape the declaration. Letters/digits/space/comma/quote/hyphen cover
        // every real font stack.
        c.fontFamily = String(c.fontFamily.filter { ch in
            ch.isLetter || ch.isNumber || ch == " " || ch == "," || ch == "'" || ch == "-"
        })
        if c.fontFamily.trimmingCharacters(in: .whitespaces).isEmpty {
            c.fontFamily = "sans-serif"
        }
        c.targetLanguage = String(c.targetLanguage.prefix(16).filter { $0.isLetter || $0 == "-" })
        // Voice-command counter. The phrase is only ever compared (never
        // rendered), so it needs no escaping — just a length bound. The LABEL is
        // shown on the page: it travels as JSON in the SSE payload and is
        // assigned via textContent, so markup can't execute, but control
        // characters would corrupt the SSE framing (a raw newline ends the
        // `data:` line). Strip those and bound the length.
        c.counterPhrase = String(c.counterPhrase.prefix(200))
        c.counterLabel = String(c.counterLabel.prefix(60).filter { !$0.isNewline && !$0.unicodeScalars.contains { s in s.properties.generalCategory == .control } })
        if c.counterLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            c.counterLabel = "Counter"
        }
        return c
    }
}

/// Which corner of the overlay canvas a widget (currently just the counter)
/// pins itself to. Raw-value Codable so the persisted config stays readable and
/// tolerant — an unknown value decodes as the default via `decodeIfPresent`
/// failure handling in the config's initializer contract.
public enum StreamOverlayCorner: String, Codable, Equatable, Sendable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// Human-readable name for settings UI.
    public var displayName: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

// MARK: - Voice commands (phrase → overlay widget action)

/// A single voice command the streamer configured. Deliberately a small open
/// shape rather than a bare phrase string: the counter is the FIRST widget
/// command, and a timer/soundboard/scene-switch command would slot in as another
/// `Kind` without disturbing the matcher or the wire.
public struct OverlayVoiceCommand: Codable, Equatable, Sendable, Identifiable {
    /// What saying the phrase does.
    public enum Kind: String, Codable, Equatable, Sendable {
        /// Increment a labeled counter widget on the overlay.
        case counter
    }

    public var id: String
    /// The phrase to listen for, as the streamer typed it. Normalized at match
    /// time — the streamer never has to think about case or punctuation.
    public var phrase: String
    public var kind: Kind

    public init(id: String = UUID().uuidString, phrase: String, kind: Kind = .counter) {
        self.id = id
        self.phrase = phrase
        self.kind = kind
    }
}

/// Counts occurrences of a trigger phrase in transcribed speech.
///
/// **Word-sequence containment, not substring.** "I died again" must fire on
/// "well, I DIED AGAIN!" but never on "I studied again" — a raw
/// `text.contains(phrase)` would match the latter's "died again" inside
/// "studied again". Both sides are normalized to a word array (lowercased,
/// punctuation/symbols dropped, whitespace collapsed) and the phrase's words are
/// matched as a contiguous subsequence.
///
/// **Script-agnostic.** Normalization uses Unicode character properties
/// (`isLetter`/`isNumber`), not an ASCII range, so a Cyrillic phrase
/// ("я снова умер") behaves exactly like a Latin one.
///
/// Pure — no state, no clock, no I/O. The server owns when to call it.
public enum OverlayVoiceCommandMatcher {

    /// Split `text` into comparable words: lowercased, with everything that is
    /// not a letter or a number treated as a separator. Apostrophes inside a
    /// word split it ("don't" → ["don", "t"]) which is fine and symmetrical:
    /// both the phrase and the text go through this, so they still line up.
    public static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// How many NON-OVERLAPPING times `phrase` occurs in `text`, matched on word
    /// boundaries after normalization.
    ///
    /// Non-overlapping matters for repeated-word phrases: "ha ha" occurs ONCE in
    /// "ha ha ha", not twice — the streamer said the trigger once and a half.
    /// Returns 0 for an empty/whitespace-only/punctuation-only phrase, so a
    /// half-configured counter can never fire on every single utterance.
    public static func occurrences(of phrase: String, in text: String) -> Int {
        let needle = normalize(phrase)
        guard !needle.isEmpty else { return 0 }
        let haystack = normalize(text)
        guard haystack.count >= needle.count else { return 0 }

        var count = 0
        var i = 0
        while i + needle.count <= haystack.count {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                count += 1
                i += needle.count      // non-overlapping: skip the whole match
            } else {
                i += 1
            }
        }
        return count
    }

    /// Convenience for a configured command: how many times it fired in `text`.
    public static func occurrences(of command: OverlayVoiceCommand, in text: String) -> Int {
        occurrences(of: command.phrase, in: text)
    }
}

/// The live state of the counter widget — the value the overlay page renders.
///
/// The COUNT is state, not configuration: it is owned by the running feature and
/// persisted separately from `StreamOverlayConfig` so a config edit (relabeling,
/// moving the corner) never resets a streamer's death count, and a restart never
/// loses it.
public struct StreamOverlayCounterState: Codable, Equatable, Sendable {
    public var label: String
    public var count: Int
    public var corner: StreamOverlayCorner
    /// True when the counter should be visible at all (config's `counterEnabled`).
    public var visible: Bool

    public init(
        label: String = "Counter",
        count: Int = 0,
        corner: StreamOverlayCorner = .bottomRight,
        visible: Bool = false
    ) {
        self.label = label
        self.count = count
        self.corner = corner
        self.visible = visible
    }
}

/// Movie-style subtitle state: the CURRENT utterance, word-wrapped to a
/// per-line character budget and windowed to the LAST `maxLines` lines — old
/// lines scroll off the top as the speaker continues, exactly like broadcast
/// captions. Pure reducer — the server feeds it published text and broadcasts
/// the snapshots it returns; the silence auto-hide timer lives in the server
/// (time is a side effect).
///
/// **Retirement is what makes it read like a movie.** Streaming engines emit a
/// monotonically GROWING transcript for the whole session ("hello" → "hello
/// there" → "hello there friends"), so a naive reducer would re-show everything
/// already spoken the moment the speaker resumes after a pause. `retire()` (the
/// silence timeout) remembers how much of that growing transcript has already
/// had its time on screen; subsequent text is shown from that point on, so a new
/// utterance starts on a blank screen instead of replaying the last one.
public struct StreamOverlayCaptions: Equatable, Sendable {
    /// One immutable frame of what the overlay should display.
    public struct Snapshot: Codable, Equatable, Sendable {
        /// Wrapped subtitle lines, oldest first, at most `maxLines`. Empty means
        /// the overlay shows nothing (no speech right now).
        public var lines: [String]
        /// Monotonic revision so a client can drop stale/out-of-order frames.
        public var revision: Int
    }

    public let maxLines: Int
    public let charsPerLine: Int
    private var lines: [String] = []
    private var revision: Int = 0
    /// The prefix of the session transcript that has already been displayed and
    /// then retired by a silence timeout. Only text BEYOND this prefix is shown.
    /// Empty until the first `retire()`.
    private var retiredPrefix: String = ""

    public init(maxLines: Int, charsPerLine: Int = 42) {
        self.maxLines = max(1, maxLines)
        self.charsPerLine = max(8, charsPerLine)
    }

    /// How much of the transcript has already been retired by a silence timeout.
    /// Read it to carry retirement across a reducer rebuilt at new geometry (a
    /// live `maxLines`/`charsPerLine` edit) — without it a rewrap would resurrect
    /// speech that already faded out.
    public var retiredTranscript: String { retiredPrefix }

    /// Rebuild at a new line geometry, preserving retirement. Used when the
    /// streamer edits wrapping while captions are live.
    public func resized(maxLines: Int, charsPerLine: Int) -> StreamOverlayCaptions {
        var copy = StreamOverlayCaptions(maxLines: maxLines, charsPerLine: charsPerLine)
        copy.retiredPrefix = retiredPrefix
        copy.revision = revision
        return copy
    }

    /// Show `text` (the session transcript so far — partial or final alike):
    /// drop whatever a previous silence already retired, wrap the remainder, and
    /// keep the trailing window. Empty/whitespace text clears.
    public mutating func setText(_ text: String) -> Snapshot {
        let fresh = Self.removingRetiredPrefix(from: text, retired: retiredPrefix)
        // The engine restarted its transcript (a new session, or a correction
        // that shortened it) — the retirement mark no longer refers to anything
        // in `text`, so drop it rather than hiding live speech forever.
        if fresh == nil { retiredPrefix = "" }
        let visible = fresh ?? text
        let wrapped = Self.wrap(visible, width: charsPerLine)
        lines = Array(wrapped.suffix(maxLines))
        return bump()
    }

    /// Hide the captions after silence AND remember that everything shown so far
    /// has had its moment — the next utterance starts from a blank screen.
    ///
    /// `transcript` is the full session text last published; it becomes the
    /// retirement mark. Pass the same string the last `setText` received.
    public mutating func retire(upTo transcript: String) -> Snapshot {
        retiredPrefix = transcript
        lines = []
        return bump()
    }

    /// Hide the captions and forget all retirement state (session reset). The
    /// next `setText` shows its text in full.
    public mutating func clear() -> Snapshot {
        lines = []
        retiredPrefix = ""
        return bump()
    }

    /// The still-unretired remainder of `text`, or nil when `text` is not an
    /// extension of `retired` (engine restart / shortened transcript).
    ///
    /// Compared on whitespace-collapsed words rather than raw characters: an
    /// engine re-punctuates and re-spaces its transcript as it goes ("hello
    /// there" → "Hello, there"), so a literal `hasPrefix` would fail constantly
    /// and replay retired speech. Word-count matching is stable across that.
    static func removingRetiredPrefix(from text: String, retired: String) -> String? {
        guard !retired.isEmpty else { return text }
        let retiredWords = retired.split(whereSeparator: { $0.isWhitespace })
        guard !retiredWords.isEmpty else { return text }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= retiredWords.count else { return nil }
        return words.dropFirst(retiredWords.count).joined(separator: " ")
    }

    public var snapshot: Snapshot { Snapshot(lines: lines, revision: revision) }

    private mutating func bump() -> Snapshot {
        revision += 1
        return snapshot
    }

    /// Greedy word wrap to `width` characters per line. Words longer than the
    /// budget are hard-split so a URL or long compound can never blow the line.
    /// Whitespace (incl. newlines) collapses — subtitles are their own layout.
    static func wrap(_ text: String, width: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for wordSub in text.split(whereSeparator: { $0.isWhitespace }) {
            var word = String(wordSub)
            // Hard-split oversized words first.
            while word.count > width {
                if !current.isEmpty { out.append(current); current = "" }
                out.append(String(word.prefix(width)))
                word = String(word.dropFirst(width))
            }
            if word.isEmpty { continue }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                out.append(current)
                current = word
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Server-sent-events framing for caption snapshots — the wire the overlay page
/// listens to via `EventSource`. Pure string building, tested in core.
public enum StreamOverlaySSE {
    /// Encode one snapshot as an SSE `caption` event frame.
    public static func frame(_ snapshot: StreamOverlayCaptions.Snapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else {
            return "event: caption\ndata: {}\n\n"
        }
        // JSON never contains raw newlines, so a single data: line is safe.
        return "event: caption\ndata: \(json)\n\n"
    }

    /// Encode a LOOK change as an SSE `style` event frame. Lets the page restyle
    /// itself in place while a capture session is live, so the streamer can tune
    /// font/size/colors without the server (and the dictation feeding it) being
    /// torn down. Only display fields travel — captions ride the `caption` event.
    public static func styleFrame(_ config: StreamOverlayConfig) -> String {
        let c = config.sanitized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let style = StreamOverlayStyle(
            canvasWidth: c.canvasWidth, canvasHeight: c.canvasHeight,
            fontFamily: c.fontFamily, fontSize: c.fontSize,
            backgroundColor: c.backgroundColor, textColor: c.textColor,
            captionsEnabled: c.captionsEnabled, counterCorner: c.counterCorner)
        guard let data = try? encoder.encode(style),
              let json = String(data: data, encoding: .utf8) else {
            return "event: style\ndata: {}\n\n"
        }
        return "event: style\ndata: \(json)\n\n"
    }

    /// Encode the voice-command counter state as an SSE `counter` event frame.
    /// Sent on every increment, on a config edit that changes the widget's
    /// label/corner/visibility, and as part of a new client's greeting.
    public static func counterFrame(_ state: StreamOverlayCounterState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state),
              let json = String(data: data, encoding: .utf8) else {
            return "event: counter\ndata: {}\n\n"
        }
        return "event: counter\ndata: \(json)\n\n"
    }
}

/// The display-only subset of `StreamOverlayConfig` that the live `style` event
/// carries. Split out so the wire payload can't accidentally leak non-display
/// settings (translation target, linger) to the page.
public struct StreamOverlayStyle: Codable, Equatable, Sendable {
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var fontFamily: String
    public var fontSize: Int
    public var backgroundColor: String
    public var textColor: String
    /// Whether the caption block is shown at all — a LOOK-level fact for the
    /// page (the server separately stops publishing caption frames), so
    /// switching to counter-only mode doesn't need an OBS source refresh.
    public var captionsEnabled: Bool
    /// Where the counter widget pins itself. The counter's LABEL and COUNT ride
    /// the `counter` event (they're state, not style); only the placement is a
    /// look change.
    public var counterCorner: StreamOverlayCorner

    public init(
        canvasWidth: Int, canvasHeight: Int, fontFamily: String,
        fontSize: Int, backgroundColor: String, textColor: String,
        captionsEnabled: Bool = true,
        counterCorner: StreamOverlayCorner = .bottomRight
    ) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.captionsEnabled = captionsEnabled
        self.counterCorner = counterCorner
    }
}

/// Generates the self-contained overlay HTML page from a config. No external
/// assets — OBS browser sources are happiest fully offline.
public enum StreamOverlayPage {
    /// CSS edge offsets (`top/right/bottom/left`) pinning a widget to a corner.
    /// Emitted as a fixed-position block so the counter is independent of the
    /// captions' flex layout — either half can be hidden without moving the other.
    static func cornerCSS(_ corner: StreamOverlayCorner) -> String {
        switch corner {
        case .topLeft: return "top: 3vh; left: 3vh;"
        case .topRight: return "top: 3vh; right: 3vh;"
        case .bottomLeft: return "bottom: 3vh; left: 3vh;"
        case .bottomRight: return "bottom: 3vh; right: 3vh;"
        }
    }

    public static func html(config: StreamOverlayConfig) -> String {
        let c = config.sanitized()
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>OpenWhisp Stream Overlay</title>
        <style>
          html, body { margin: 0; padding: 0; overflow: hidden; }
          body {
            width: \(c.canvasWidth)px;
            height: \(c.canvasHeight)px;
            background: \(c.backgroundColor);
            font-family: \(c.fontFamily);
            display: flex;
            flex-direction: column;
            justify-content: flex-end;
            align-items: center;
          }
          #captions {
            width: 92%;
            padding-bottom: 2vh;
            text-align: center;
            color: \(c.textColor);
            font-size: \(c.fontSize)px;
            line-height: 1.25;
            text-shadow: 0 2px 8px rgba(0,0,0,0.85);
            white-space: pre-wrap;
            word-break: break-word;
          }
          #captions div {
            display: inline-block;
            background: rgba(0,0,0,0.55);
            border-radius: 6px;
            padding: 0.05em 0.4em;
            margin-top: 0.12em;
          }
          /* Voice-command counter: same visual idiom as a caption line (dark
             plate, soft shadow, config text color) but pinned to a corner and
             laid out independently of the caption flex column, so captions-off
             and counter-off are genuinely independent. */
          #counter {
            position: fixed;
            \(cornerCSS(c.counterCorner))
            color: \(c.textColor);
            font-size: \(c.fontSize)px;
            line-height: 1.25;
            text-shadow: 0 2px 8px rgba(0,0,0,0.85);
            background: rgba(0,0,0,0.55);
            border-radius: 6px;
            padding: 0.05em 0.4em;
            white-space: nowrap;
          }
          .hidden { display: none !important; }
        </style>
        </head>
        <body>
        <div id="captions"\(c.captionsEnabled ? "" : " class=\"hidden\"")></div>
        <div id="counter" class="hidden"></div>
        <script>
          const el = document.getElementById('captions');
          const counterEl = document.getElementById('counter');
          let lastRevision = -1;
          const source = new EventSource('/events');
          source.addEventListener('caption', (e) => {
            const snap = JSON.parse(e.data);
            if (snap.revision <= lastRevision) return; // drop stale frames
            lastRevision = snap.revision;
            el.textContent = '';
            for (const line of snap.lines) {
              const d = document.createElement('div');
              d.textContent = line;
              el.appendChild(d);
              el.appendChild(document.createElement('br'));
            }
          });
          // Live restyle: the app pushes appearance edits instead of restarting
          // the server, so tuning the look never interrupts a capture session.
          // Values are sanitized server-side; assigned via the style object
          // (never innerHTML) so nothing here can inject markup.
          source.addEventListener('style', (e) => {
            const s = JSON.parse(e.data);
            if (typeof s.canvasWidth === 'number') document.body.style.width = s.canvasWidth + 'px';
            if (typeof s.canvasHeight === 'number') document.body.style.height = s.canvasHeight + 'px';
            if (typeof s.backgroundColor === 'string') document.body.style.background = s.backgroundColor;
            if (typeof s.fontFamily === 'string') document.body.style.fontFamily = s.fontFamily;
            if (typeof s.fontSize === 'number') {
              el.style.fontSize = s.fontSize + 'px';
              counterEl.style.fontSize = s.fontSize + 'px';
            }
            if (typeof s.textColor === 'string') {
              el.style.color = s.textColor;
              counterEl.style.color = s.textColor;
            }
            // Captions can be switched off entirely (counter-only mode) without
            // reloading the browser source.
            if (typeof s.captionsEnabled === 'boolean') {
              el.classList.toggle('hidden', !s.captionsEnabled);
              if (!s.captionsEnabled) el.textContent = '';
            }
            if (typeof s.counterCorner === 'string') {
              // Reset all four edges first so switching corners never leaves a
              // stale offset pinning the block to two edges at once.
              counterEl.style.top = counterEl.style.right = '';
              counterEl.style.bottom = counterEl.style.left = '';
              const c = s.counterCorner;
              if (c === 'topLeft') { counterEl.style.top = '3vh'; counterEl.style.left = '3vh'; }
              else if (c === 'topRight') { counterEl.style.top = '3vh'; counterEl.style.right = '3vh'; }
              else if (c === 'bottomLeft') { counterEl.style.bottom = '3vh'; counterEl.style.left = '3vh'; }
              else { counterEl.style.bottom = '3vh'; counterEl.style.right = '3vh'; }
            }
          });
          // Voice-command counter: the server increments on a matching FINAL
          // utterance and pushes the whole state, so the page is stateless and a
          // reconnecting browser source is always correct. textContent (never
          // innerHTML) — the label is user text.
          source.addEventListener('counter', (e) => {
            const st = JSON.parse(e.data);
            counterEl.classList.toggle('hidden', !st.visible);
            if (!st.visible) return;
            counterEl.textContent = st.label + ': ' + st.count;
          });
        </script>
        </body>
        </html>
        """
    }
}
