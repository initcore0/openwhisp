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
    /// How many finalized caption lines stay on screen (older lines scroll off).
    public var maxLines: Int
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
        self.translationEnabled = translationEnabled
        self.targetLanguage = targetLanguage
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

/// The rolling caption state the overlay shows: a capped window of finalized
/// lines plus the in-flight partial hypothesis. Pure reducer — the server feeds
/// it published text and broadcasts the snapshots it returns.
public struct StreamOverlayCaptions: Equatable, Sendable {
    /// One immutable frame of what the overlay should display.
    public struct Snapshot: Codable, Equatable, Sendable {
        /// Finalized lines, oldest first, at most `maxLines`.
        public var lines: [String]
        /// The live partial hypothesis ("" when none).
        public var partial: String
        /// Monotonic revision so a client can drop stale/out-of-order frames.
        public var revision: Int
    }

    public let maxLines: Int
    private var lines: [String] = []
    private var partial: String = ""
    private var revision: Int = 0

    public init(maxLines: Int) {
        self.maxLines = max(1, maxLines)
    }

    /// Replace the live partial hypothesis.
    public mutating func setPartial(_ text: String) -> Snapshot {
        partial = text
        return bump()
    }

    /// Commit a finalized line (clearing the partial) and scroll old lines off.
    /// Empty/whitespace finals just clear the partial.
    public mutating func commitFinal(_ text: String) -> Snapshot {
        partial = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append(trimmed)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
        return bump()
    }

    /// Clear everything (session ended).
    public mutating func clear() -> Snapshot {
        lines = []
        partial = ""
        return bump()
    }

    public var snapshot: Snapshot { Snapshot(lines: lines, partial: partial, revision: revision) }

    private mutating func bump() -> Snapshot {
        revision += 1
        return snapshot
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
          #captions .partial { opacity: 0.65; font-style: italic; }
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
            }
            if (snap.partial) {
              const p = document.createElement('div');
              p.className = 'partial';
              p.textContent = snap.partial;
              el.appendChild(p);
            }
          });
        </script>
        </body>
        </html>
        """
    }
}
