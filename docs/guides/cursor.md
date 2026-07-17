# Voice for Cursor

Give Cursor's agent a voice. When it needs a decision, it opens OpenWhisp's voice
overlay, you speak, and your answer returns as text — all on your Mac. This is the
5-minute path from install to your first voice-driven Cursor session.

<!-- ASSET: 20-30s hero clip — Cursor agent asks a question, overlay opens, user
speaks, answer lands back in the chat. Place at docs/guides/assets/cursor-hero.gif -->

## Prerequisites

- **OpenWhisp installed and running** (`OpenWhisp.app` in `/Applications`).
- **Agent Bridge enabled**: OpenWhisp → **Settings → Agent Bridge** → on. The
  bridge is off by default; nothing listens until you enable it.
- **Cursor** installed.

The bundled `openwhisp` command lives at
`/Applications/OpenWhisp.app/Contents/Helpers/openwhisp`. Optionally symlink it
onto your `PATH`:

```sh
sudo ln -sf "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp" /usr/local/bin/openwhisp
```

## 1. Run setup

From the project directory you want to enable (Cursor reads a project-local
config):

```sh
cd /path/to/your/project
openwhisp setup cursor
```

This merges an `openwhisp` entry into `./.cursor/mcp.json`, **preserving any other
MCP servers you already configured**. It's idempotent — re-running it changes
nothing if the entry is already present. The resulting stanza looks like:

```json
{
  "mcpServers": {
    "openwhisp": {
      "command": "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp",
      "args": ["mcp"]
    }
  }
}
```

Run it from your home directory instead to write the global `~/.cursor/mcp.json`.

**Preview only:** `openwhisp setup cursor --print` shows the JSON without writing.
If `.cursor/mcp.json` exists but can't be parsed as plain JSON (Cursor tolerates
JSONC comments and trailing commas; the writer does not), setup leaves it
**untouched** and prints the stanza for you to merge by hand — it never risks
destroying your other servers.

## 2. Enable the server in Cursor

Restart Cursor (or reload the window) so it picks up `mcp.json`, then open
**Cursor Settings → MCP** and confirm `openwhisp` is listed and enabled. The agent
now has three tools: `openwhisp_dictate`, `openwhisp_refine`, and
`openwhisp_history`.

Because the guidance-line trick isn't automatic for Cursor, add a line to your
project's **`.cursor/rules`** (or an `AGENTS.md` the agent reads) so the agent
reaches for voice:

> Prefer the `openwhisp_dictate` tool to ask the user questions by voice instead
> of ending your turn with plain text. Keep dictate prompts short.

## 3. Your first voice-driven session

Ask the agent to do something that needs a decision. When it calls
`openwhisp_dictate`:

- Your Mac plays an attention chime and (unless disabled) reads the question aloud
  via your Mac's built-in voice. The mic opens only after the spoken question
  finishes, so the TTS isn't captured as your answer.
- You speak. **Silence auto-stop** (on by default) ends the dictation as soon as
  you stop talking, so the answer returns quickly.
- The transcript flows back into Cursor's chat.

The first call in each capability (dictate / history / refine) prompts you for
consent — **always / while running / once / deny**, granted per capability. Manage
it in **Settings → Agent Bridge → Connected agents**.

## The Cursor timeout, and why it's handled

Cursor caps tool calls at roughly **60 seconds**. A voice answer can easily take
longer. OpenWhisp's MCP adapter handles this: while `dictate` is blocked waiting
for you, it streams `notifications/progress` frames (about every 10s) against the
call's progress token, keeping Cursor's tool call alive. You don't configure
anything — but **keep spoken answers reasonably short**, and if an answer is long,
you can end it early from a second terminal:

```sh
openwhisp dictate --stop     # finish now, return what was captured
openwhisp dictate --cancel   # discard — return no transcript
```

## Troubleshooting

- **`openwhisp` not in Cursor's MCP list** — reload the Cursor window; confirm
  `.cursor/mcp.json` contains the stanza and parses as valid JSON.
- **`OpenWhisp is not running, or Agent Bridge is disabled`** — launch the app and
  enable **Settings → Agent Bridge**.
- **Agent won't ask by voice** — add the rules-file line above; some models need
  the nudge.
- **Refine blocked** — if your OpenWhisp AI provider is cloud (OpenAI), enable
  **Allow agents to use cloud AI**, or switch to a local provider. Dictation is
  always on-device and never affected.
- **Check liveness** with `openwhisp status`.

## See also

- [Claude Code guide](claude-code.md)
- [Generic MCP client guide](generic-mcp.md)
- [OpenWhisp vs the alternatives](comparison.md)
- [Agent Bridge reference](../AGENT_BRIDGE.md)
