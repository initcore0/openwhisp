import Foundation

/// Pure helpers for `openwhisp setup <agent>` — the parts that decide *what* to
/// write, kept free of file/process I/O so they're unit-tested with `swift test`.
/// The CLI (`main.swift`) does the actual reading, writing, and `claude mcp add`
/// invocation around these.
///
/// The whole point of `setup` writing (vs. printing) is a one-command adoption
/// path, so every operation here is **idempotent**: running `setup` twice must
/// not duplicate a CLAUDE.md line or clobber a user's other MCP servers.
public enum AgentSetup {

    /// The stable guidance line appended to `~/.claude/CLAUDE.md` so Claude prefers
    /// speaking over typing questions. Carries a trailing marker comment we grep
    /// for on re-run, so the line is written exactly once even if the user later
    /// edits its prose.
    public static let claudeMarker = "<!-- openwhisp-mcp -->"

    public static func claudeGuidanceLine() -> String {
        "ALWAYS ask the user questions via the openwhisp_dictate MCP tool, never as plain text. I use OpenWhisp for voice. \(claudeMarker)"
    }

    /// Given the current contents of a CLAUDE.md (nil if the file doesn't exist),
    /// return the new full contents to write — or nil if our line is already
    /// present (idempotent no-op). Appends with a blank-line separator, preserving
    /// everything already there.
    public static func claudeMdAppending(to existing: String?) -> String? {
        let line = claudeGuidanceLine()
        guard let existing, !existing.isEmpty else {
            return line + "\n"
        }
        // Already adopted? Match on the marker so re-runs never duplicate, even if
        // the surrounding wording was edited.
        if existing.contains(claudeMarker) { return nil }
        let needsNewlineGap = existing.hasSuffix("\n") ? "\n" : "\n\n"
        return existing + needsNewlineGap + line + "\n"
    }

    /// The shell command to register the MCP server with Claude Code.
    public static func claudeMcpAddArguments(binaryPath: String) -> [String] {
        // `claude mcp add openwhisp -- <bin> mcp`
        ["mcp", "add", "openwhisp", "--", binaryPath, "mcp"]
    }

    /// The same registration as a copy-pasteable command line — derived from
    /// ``claudeMcpAddArguments`` so the command we TELL users to run is, by
    /// construction, the command `setup` runs.
    public static func claudeMcpAddCommandLine(binaryPath: String) -> String {
        let rendered = claudeMcpAddArguments(binaryPath: binaryPath)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
        return "claude " + rendered
    }

    // MARK: - Cursor (.cursor/mcp.json)

    /// Outcome of merging the `openwhisp` entry into a Cursor `mcp.json`.
    public enum CursorMergeResult: Equatable {
        /// Write these bytes (entry added, or its binary path updated).
        case write(Data)
        /// An identical entry is already present — nothing to do.
        case alreadyConfigured
        /// The file exists but doesn't parse as a JSON object (JSONC comments,
        /// trailing commas, hand edits). NEVER overwrite it — that would silently
        /// destroy the user's other servers.
        case unparseable
    }

    /// Merge an `openwhisp` MCP server entry into a Cursor `mcp.json`, preserving
    /// any servers the user already configured. Takes the existing file's bytes
    /// (nil if absent).
    public static func cursorMcpJSON(existing: Data?, binaryPath: String) -> CursorMergeResult {
        let desiredServer: [String: Any] = ["command": binaryPath, "args": ["mcp"]]

        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            // A present-but-unparseable file is a refusal, not a fresh start:
            // Cursor tolerates JSONC where JSONSerialization doesn't, and
            // "starting fresh" would atomically delete every other server.
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                return .unparseable
            }
            root = parsed
        }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]

        // Idempotent: identical entry already there → nothing to do.
        if let current = servers["openwhisp"] as? [String: Any],
           (current["command"] as? String) == binaryPath,
           (current["args"] as? [String]) == ["mcp"] {
            return .alreadyConfigured
        }

        servers["openwhisp"] = desiredServer
        root["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            // .withoutEscapingSlashes: the command is a file path in a config the
            // user reads and edits (same choice as ConfigBundle's writer).
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return .unparseable }
        return .write(data)
    }
}
