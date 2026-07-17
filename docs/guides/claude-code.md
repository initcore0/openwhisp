# Voice for Claude Code

Give Claude Code a voice. When Claude needs a decision, it opens OpenWhisp's
voice overlay, reads the question aloud, you speak your answer, and the
transcript flows back into the session — all on your Mac. This is the 5-minute
path from install to your first voice-driven agent session.

> **Why this over the built-in `/voice`?** See [comparison.md](comparison.md).
> Short version: OpenWhisp is on-device, works over SSH, and doesn't depend on
> Claude's native voice being available for your auth mode.

<!-- ASSET: 20-30s hero clip — Claude asks "which branch?", overlay opens, user
speaks "main", answer lands back in the transcript. Place at docs/guides/assets/claude-code-hero.gif -->

## Prerequisites

- **OpenWhisp installed and running** (`OpenWhisp.app` in `/Applications`).
- **Agent Bridge enabled**: open OpenWhisp → **Settings → Agent Bridge** and turn
  it on. Nothing listens until you do — the bridge is off by default.
- **Claude Code** installed with the `claude` CLI on your `PATH`.

The bundled `openwhisp` command lives at
`/Applications/OpenWhisp.app/Contents/Helpers/openwhisp`. Optionally symlink it
so `openwhisp` works from anywhere:

```sh
sudo ln -sf "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp" /usr/local/bin/openwhisp
```

## 1. Run setup (one command)

```sh
openwhisp setup claude-code
```

This is idempotent and safe to re-run. It does two things:

1. **Registers the MCP server** with Claude Code by running
   `claude mcp add openwhisp -- <path-to-openwhisp> mcp`.
2. **Appends a guidance line** to `~/.claude/CLAUDE.md` so Claude prefers asking
   you by voice instead of ending its turn with a typed question:

   > ALWAYS ask the user questions via the openwhisp_dictate MCP tool, never as
   > plain text. I use OpenWhisp for voice.

That guidance line matters: the `openwhisp_dictate` tool fires reliably only when
a standing instruction tells the agent to prefer it over typed questions.

**Want to see the steps first?** Add `--print` (or `--dry-run`) — it shows exactly
what would happen and changes nothing:

```sh
openwhisp setup claude-code --print
```

If the `claude` CLI isn't on your `PATH`, setup prints the exact
`claude mcp add …` command to run yourself. If `~/.claude/CLAUDE.md` exists but
can't be read (permissions, non-UTF-8), setup refuses to touch it and prints the
line for you to paste — it will never overwrite your file.

## 2. Start a fresh Claude Code session

MCP servers are picked up at session start. Open a new session, then confirm the
server registered:

```sh
claude mcp list
```

You should see `openwhisp`. Claude now has three tools:

| Tool | What it does |
|---|---|
| `openwhisp_dictate` | Shows your prompt, opens the voice overlay, returns your spoken answer as text. |
| `openwhisp_refine` | Rewrites text with your on-device LLM (same model as your refine hotkey). |
| `openwhisp_history` | Returns your recent dictations (text, timestamp, target app). |

## 3. Your first voice-driven session

Ask Claude to do something that requires a decision. When it hits the fork, it
calls `openwhisp_dictate`:

- Your Mac plays an attention chime.
- The OpenWhisp overlay shows the question, and (unless you turned it off) your
  Mac reads it aloud. The mic doesn't open until the spoken question finishes, so
  the TTS is never captured as your answer.
- You speak. **Silence auto-stop** (on by default) ends the dictation once you
  stop talking, so your answer returns promptly.
- The transcript flows back to Claude and it continues.

<!-- ASSET: annotated screenshot of the overlay showing the "X asks:" label +
question hero. Place at docs/guides/assets/claude-code-overlay.png -->

### Ending a dictation manually

`dictate` blocks until the utterance ends. Besides silence auto-stop, you can end
it from a second terminal:

```sh
openwhisp dictate --stop     # finish now, return what was captured
openwhisp dictate --cancel   # discard — return no transcript (like Esc)
```

Pressing your own dictation **hotkey** during an agent session *cancels* it (you
reclaim the mic) — it does not finish it.

### First-call consent

The first time Claude uses each capability (dictate, history, refine), OpenWhisp
prompts you: **always / while running / once / deny**. Consent is **per
capability** — approving voice questions does not grant history or refine access.
Manage or revoke it in **Settings → Agent Bridge → Connected agents**.

---

## Special cases

### API-key and Amazon Bedrock users

Claude Code's built-in voice features can be gated behind subscription auth.
OpenWhisp does **not** care how you authenticate Claude Code — it's a separate
local MCP server. Whether you run Claude Code on a Console/subscription login, a
raw `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_USE_BEDROCK=1` against Amazon Bedrock,
`openwhisp setup claude-code` and the `openwhisp_dictate` tool work identically.
Your auth mode changes nothing here.

Note the separate **cloud-AI gate**: this only affects `openwhisp_refine`. If
*your OpenWhisp AI provider* is a cloud provider (OpenAI), agent-initiated
refinement is blocked until you enable **Settings → Agent Bridge → Allow agents
to use cloud AI**, or switch OpenWhisp to a local provider. `openwhisp_dictate`
(voice questions) is never affected — dictation and transcription are always
on-device.

### SSH and remote sessions

Run Claude Code over SSH into a remote box and its native audio has nowhere to
go — there's no mic or speaker on the far end. OpenWhisp's model side-steps this:
the MCP server and your mic live on your **local Mac**, and the agent reaches them
over a local UNIX-domain socket. As long as the `openwhisp mcp` adapter is
registered and running on the machine where OpenWhisp (and your mic) live, voice
happens locally where you're sitting while the agent works remotely.

> The bridge transport is a local socket by design (see Privacy below) — it is
> not a network port you expose. So register the adapter next to OpenWhisp, not on
> a headless remote host that has no mic or speaker.

### HIPAA / privacy-locked organizations

Some orgs disable Claude's native `/voice` because it can route audio through a
cloud speech service. OpenWhisp is built for exactly this constraint:

- **Transcription is 100% on-device** (WhisperKit / whisper.cpp on the Apple
  Neural Engine). No audio and no transcript leaves your Mac.
- The `openwhisp_dictate` and `openwhisp_history` tools never touch the network.
- `openwhisp_refine` is the *only* tool that can reach a cloud provider, and only
  if you've both selected a cloud AI provider **and** flipped the cloud-AI gate on.
  Leave OpenWhisp on a local LLM (or leave the gate off) and nothing leaves the
  device, ever.

So an org that locks out native `/voice` can still get voice-driven Claude Code
through OpenWhisp without any audio egress. (Confirm with your own compliance
team; this describes what the software does, not a compliance certification.)

---

## Troubleshooting

- **`OpenWhisp is not running, or Agent Bridge is disabled`** (exit 2) — launch
  the app and enable **Settings → Agent Bridge**.
- **Claude doesn't ask by voice** — check the guidance line is in
  `~/.claude/CLAUDE.md` (re-run `openwhisp setup claude-code`) and that you started
  a fresh session.
- **Server missing from `claude mcp list`** — the app moved or updated and the
  registration went stale. Re-running `openwhisp setup claude-code` repairs the
  path (remove + re-add).
- **`agent cloud AI is off`** on refine — see the cloud-AI gate note above.
- **Check liveness** any time with `openwhisp status`.

## See also

- [Cursor guide](cursor.md)
- [Generic MCP client guide](generic-mcp.md)
- [OpenWhisp vs the alternatives](comparison.md)
- [Agent Bridge reference](../AGENT_BRIDGE.md) — full protocol, consent, security.
