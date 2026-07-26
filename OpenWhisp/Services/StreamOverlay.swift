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
        targetLanguage: String = ""
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
        return c
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
            backgroundColor: c.backgroundColor, textColor: c.textColor)
        guard let data = try? encoder.encode(style),
              let json = String(data: data, encoding: .utf8) else {
            return "event: style\ndata: {}\n\n"
        }
        return "event: style\ndata: \(json)\n\n"
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

    public init(
        canvasWidth: Int, canvasHeight: Int, fontFamily: String,
        fontSize: Int, backgroundColor: String, textColor: String
    ) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.backgroundColor = backgroundColor
        self.textColor = textColor
    }
}

/// Generates the self-contained overlay HTML page from a config. No external
/// assets — OBS browser sources are happiest fully offline.
public enum StreamOverlayPage {
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
        </style>
        </head>
        <body>
        <div id="captions"></div>
        <script>
          const el = document.getElementById('captions');
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
            if (typeof s.fontSize === 'number') el.style.fontSize = s.fontSize + 'px';
            if (typeof s.textColor === 'string') el.style.color = s.textColor;
          });
        </script>
        </body>
        </html>
        """
    }
}
