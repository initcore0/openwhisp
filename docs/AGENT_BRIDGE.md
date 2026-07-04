# Agent Bridge

OpenWhisp can expose itself as a **local MCP server and CLI** so coding agents
(Claude Code, Cursor, Hermes, OpenClaw) can dictate on your behalf, rewrite text
with your on-device AI, and read your dictation history — all staying on your
Mac. It's **off by default**; nothing listens until you turn it on.

Enable it in **Settings → Agent Bridge**.

## What agents get

Three tools, exposed over the [Model Context Protocol](https://modelcontextprotocol.io):

| Tool | What it does |
|---|---|
| `openwhisp_dictate` | Shows a prompt and opens the voice overlay; the user speaks, the transcript returns to the agent. Use it to ask the user a question by voice instead of ending your turn with typed text. |
| `openwhisp_refine` | Rewrites text per a natural-language instruction using your configured on-device LLM (same model/prompt as the refine hotkey). |
| `openwhisp_history` | Returns recent dictations (text, timestamp, target app), newest first. |

## Setup

The bundled `openwhisp` command lives at
`OpenWhisp.app/Contents/Helpers/openwhisp`. Print per-agent registration with
`openwhisp setup <agent>`:

```sh
# Claude Code
claude mcp add openwhisp -- "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp" mcp
# then add to ~/.claude/CLAUDE.md:
#   ALWAYS ask the user questions via the openwhisp_dictate MCP tool, never as plain text.
```

(The CLAUDE.md line matters — like Spokenly's, the dictate tool fires reliably
only when a standing instruction tells the agent to prefer it over typed
questions.)

```sh
"$(/Applications/OpenWhisp.app/Contents/Helpers/openwhisp setup cursor)"    # Cursor
openwhisp setup hermes                                                        # Hermes
openwhisp setup openclaw                                                      # OpenClaw
```

Optionally symlink the CLI onto your PATH:

```sh
sudo ln -sf "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp" /usr/local/bin/openwhisp
```

## CLI

Result-only on stdout (composes in shell pipelines); diagnostics on stderr.

```sh
openwhisp status                         # liveness probe
openwhisp dictate --prompt "Which branch?"
pbpaste | openwhisp refine -i "make it formal" | pbcopy
openwhisp history --limit 5 --json
```

Exit codes: `0` ok · `1` internal · `2` app unreachable / bridge off · `3`
consent denied · `4` busy · `5` cancelled · `6` timeout · `7` permission /
secure field · `64` usage · `65` version mismatch.

## Security & privacy

- **Local only.** The transport is a UNIX-domain socket under
  `~/Library/Application Support/OpenWhisp/` (perms `0600`), not a TCP port —
  other local users and browser pages can't reach it.
- **Signed clients only.** By default only OpenWhisp's own code-signed CLI and
  adapter may connect (verified by the peer's audit token — no PID-reuse race).
  Enable *Allow unsigned / third-party clients* to write your own.
- **Consent.** The first time an agent uses the bridge you approve it (always /
  while running / once / deny); manage or revoke per-client in the settings pane.
- **The cloud gate.** If your AI provider is OpenAI (cloud), agent-initiated
  refinement is **blocked** unless you turn on *Allow agents to use cloud AI* —
  so a prompt-injected agent can't exfiltrate text through your key. Local
  providers are unaffected.
- **The human wins the mic.** Pressing your dictation hotkey during an agent
  session cancels it (the agent gets nothing) and starts your own. Agent
  microphone use always shows the overlay. Password fields are never dictated
  into.

## Notes

- The MCP adapter speaks MCP's newline-delimited JSON-RPC 2.0 stdio transport
  directly (no third-party SDK dependency).
- Long-running `dictate` blocks until the user answers. Claude Code's stdio tool
  timeout is effectively unlimited; **Cursor** caps tool calls near 60s, so keep
  dictate answers short there.
- Progress notifications during `dictate` and one-command `setup` that writes the
  config for you are planned follow-ups.
