# Voice for any MCP client

OpenWhisp exposes its voice tools over the [Model Context
Protocol](https://modelcontextprotocol.io) as a plain stdio server. Any
MCP-capable agent — Hermes, OpenClaw, a custom harness, or anything that speaks
MCP's stdio transport — can drive your mic, refine text with your on-device LLM,
and read your dictation history. This is the client-agnostic setup path.

## Prerequisites

- **OpenWhisp installed and running**, with **Settings → Agent Bridge** enabled
  (off by default — nothing listens until you turn it on).
- An MCP client that supports the **stdio** transport.

The bundled command lives at
`/Applications/OpenWhisp.app/Contents/Helpers/openwhisp`. Symlink it onto your
`PATH` if convenient:

```sh
sudo ln -sf "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp" /usr/local/bin/openwhisp
```

## 1. Register the stdio server

The server command is:

```sh
openwhisp mcp
```

It speaks MCP's newline-delimited JSON-RPC 2.0 over stdin/stdout (no third-party
SDK, no network port). Register it however your client configures MCP servers. The
universal shape is:

- **command**: `/Applications/OpenWhisp.app/Contents/Helpers/openwhisp` (or
  `openwhisp` if symlinked)
- **args**: `["mcp"]`

`openwhisp setup <client>` has built-in helpers for a few clients — it prints the
exact stanza to add (nothing is written for these; you paste it):

```sh
openwhisp setup hermes     # prints a ~/.hermes/config.yaml mcp_servers stanza
openwhisp setup openclaw   # prints OpenClaw MCP-registration guidance
openwhisp setup agents-md  # prints the generic "run: openwhisp mcp" + rules line
```

For example, `openwhisp setup hermes` emits:

```yaml
mcp_servers:
  - name: openwhisp
    command: "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp"
    args: ["mcp"]
```

Add `--print` to any setup command to be explicit that it's print-only.

## 2. Add a voice-first rule

The dictate tool fires reliably only when a standing instruction tells the agent
to prefer it. Add to your agent's rules/system file:

> Prefer the `openwhisp_dictate` tool to ask the user questions by voice instead
> of ending your turn with plain text.

## 3. The tools

Once connected, `tools/list` returns three tools:

| Tool | Inputs | Returns |
|---|---|---|
| `openwhisp_dictate` | `prompt?`, `timeoutSeconds?` (default 60, max 300), `language?` (BCP-47) | The user's spoken answer as text. |
| `openwhisp_refine` | `text` (required), `instruction` (required) | Text rewritten by the user's on-device LLM. |
| `openwhisp_history` | `limit?` (default 20, max 200) | Recent dictations: text, timestamp, target app. |

### Keeping long dictations alive (progress)

`openwhisp_dictate` blocks until the user finishes speaking (or the timeout). If
your client's `tools/call` includes `params._meta.progressToken`, the adapter
streams `notifications/progress` frames (about every 10s, tunable via the
`OPENWHISP_MCP_PROGRESS_INTERVAL` env var) against that token so agents with short
tool-call timeouts stay alive. Clients with no such timeout (or that don't pass a
token) get no progress noise.

### Ending a dictation

A dictation ends when the user stops talking (silence auto-stop, on by default),
the timeout elapses, or a session control is issued. From any admitted client's
shell:

```sh
openwhisp dictate --stop     # finish now, return what was captured
openwhisp dictate --cancel   # discard — no transcript returned
```

## Consent, security, and the cloud gate

- **Local-only transport.** Agent clients connect over a UNIX-domain socket
  (perms `0600`) under `~/Library/Application Support/OpenWhisp/` — not a TCP
  port. Other local users and browser pages can't reach it.
- **Signed clients only, by default.** Only OpenWhisp's own code-signed CLI/adapter
  may connect (verified by the peer's audit token). To connect your **own**
  unsigned client, enable **Settings → Agent Bridge → Allow unsigned / third-party
  clients**.
- **Per-capability consent.** The first call in each capability (dictate, history,
  refine) prompts: always / while running / once / deny. Approving one capability
  never grants another.
- **The cloud gate.** If your OpenWhisp AI provider is cloud (OpenAI),
  agent-initiated `openwhisp_refine` is blocked unless you enable **Allow agents to
  use cloud AI** — so a prompt-injected agent can't exfiltrate text through your
  key. Dictation and transcription are always on-device regardless.
- **Rate limited.** Even an always-allowed client gets a per-client cooldown, a
  sessions-per-hour cap, and a mic-time budget; a throttled `dictate` fails fast
  with a `retryAfterSeconds` hint so a well-behaved agent backs off.

## Error handling

Tool errors come back as MCP tool results with `isError: true` and a
human-readable message (e.g. "OpenWhisp isn't running, or its Agent Bridge is
off"). The parallel CLI verbs use uniform exit codes: `0` ok · `1` internal · `2`
unreachable / bridge off · `3` consent denied · `4` busy / rate-limited · `5`
cancelled · `6` timeout · `7` permission / secure field · `64` usage · `65`
version mismatch. Probe liveness with `openwhisp status`.

## See also

- [Claude Code guide](claude-code.md)
- [Cursor guide](cursor.md)
- [OpenWhisp vs the alternatives](comparison.md)
- [Agent Bridge reference](../AGENT_BRIDGE.md) — full protocol, consent, security.
