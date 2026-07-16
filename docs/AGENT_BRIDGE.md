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

### P2P sync verbs (wire v1.2, capability `sync`)

For the paired iPhone companion (MAK-51), three additional verbs move your
**vocabulary, per-app profiles/modes, config packs, and dictation history**
between your Mac and phone over your own LAN — nothing leaves your devices. They
are **additive and capability-gated**: a build that implements them advertises
the `sync` capability in `bridge.hello`, so a client that never sees it is
untouched (the on-the-wire protocol major stays `1`; this is milestone `1.2`).

| Verb | Shape |
|---|---|
| `sync.manifest` | → `{ schemaVersion, vocabHash, profilesHash, modesHash, packsHash, historyHead { count, newestID, newestDate }, updatedAt: {section → ISO-8601} }` — cheap section digests so a peer can plan what to pull/push without shipping the whole bundle. |
| `sync.pull` | `{ sinceHistoryCursor?, want?: [vocabulary\|profiles\|modes\|history\|packs] }` → `{ bundle: ConfigBundle(v3), historyEntries: [TranscriptionEntry] }`. Absent `want` returns every section; absent cursor returns full history. |
| `sync.push` | `{ bundle: ConfigBundle(v3), historyEntries: [TranscriptionEntry] }` (phone→Mac) → `{ accepted, mergedCounts { vocabulary, profiles, modes, history, packs } }`. |

**Consent.** Sync is its own per-capability scope (`sync`), granted separately
from dictate/history/refine — pairing a phone to sync your setup never lets it
drive your mic or your LLM. A consent file written before this scope existed
simply has no `sync` decision recorded, so the first sync prompts.

**Merge policy (v1, deliberately boring).** vocabulary = union by
`Substitution.id`, newer `updatedAt` wins per entry, terms = set union; history =
append-only union by entry `id`; profiles/modes/settings = last-writer-wins per
object by `updatedAt`; packs = content-hash identity. This needs the `updatedAt`
stamps added to `Vocabulary.Substitution`, `AppProfile`, and `Mode` in
**ConfigBundle schema v3** — a v2 file decodes its missing stamps as the epoch,
so any stamped v3 edit always wins over unstamped legacy data.

## Setup

The bundled `openwhisp` command lives at
`OpenWhisp.app/Contents/Helpers/openwhisp`. `openwhisp setup <agent>` performs
the registration for you (it **writes config** — idempotent, safe to re-run):

```sh
# Claude Code — runs `claude mcp add` and appends the guidance line to ~/.claude/CLAUDE.md
openwhisp setup claude-code
# Cursor — merges openwhisp into ./.cursor/mcp.json (keeps your other servers)
openwhisp setup cursor
# Hermes / OpenClaw — prints the stanza to add (no safe auto-writer yet)
openwhisp setup hermes
openwhisp setup openclaw
```

Pass `--print` (or `--dry-run`) to only show the steps without changing anything:

```sh
openwhisp setup claude-code --print
```

(The CLAUDE.md line matters — like Spokenly's, the dictate tool fires reliably
only when a standing instruction tells the agent to prefer it over typed
questions. `setup claude-code` adds it for you.)

Optionally symlink the CLI onto your PATH:

```sh
sudo ln -sf "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp" /usr/local/bin/openwhisp
```

## CLI

Result-only on stdout (composes in shell pipelines); diagnostics on stderr.

```sh
openwhisp status                         # liveness probe
openwhisp dictate --prompt "Which branch?"
openwhisp dictate --stop                 # finish a running dictation now (from another shell)
openwhisp dictate --cancel               # discard a running dictation (returns no transcript)
pbpaste | openwhisp refine -i "make it formal" | pbcopy
openwhisp history --limit 5 --json
```

**Finishing a dictation.** `dictate` blocks until the utterance ends. It ends
when (whichever comes first): you **stop talking** (silence auto-stop, on by
default — see below); a client calls `dictate.stop` (or you run `openwhisp
dictate --stop` from another shell), which returns whatever was captured; or the
timeout elapses. Pressing your dictation **hotkey** *cancels* an agent dictation
(the human reclaiming the mic) — it does not finish it.

Exit codes: `0` ok · `1` internal · `2` app unreachable / bridge off · `3`
consent denied · `4` busy · `5` cancelled · `6` timeout · `7` permission /
secure field · `64` usage · `65` version mismatch.

## Security & privacy

- **Local only.** The transport for agent clients is a UNIX-domain socket under
  `~/Library/Application Support/OpenWhisp/` (perms `0600`), not a TCP port —
  other local users and browser pages can't reach it. (The paired-iPhone sync
  link reuses the same wire over TLS 1.3 with a QR-provisioned pre-shared key on
  the LAN — see MAK-51; that transport is separate from this socket.)
- **Signed clients only.** By default only OpenWhisp's own code-signed CLI and
  adapter may connect (verified by the peer's audit token — no PID-reuse race).
  Enable *Allow unsigned / third-party clients* to write your own.
- **Consent, per capability.** Consent is granted **separately for each
  capability** — dictate, history, and refine. Approving an agent to ask you a
  question does **not** let it read your dictation history or run your AI; the
  first call in each capability prompts on its own (always / while running / once
  / deny). The settings pane shows each agent's per-capability status; Revoke
  clears them all. One caveat: `dictate.stop` / `dictate.cancel` are session
  controls, not capabilities — any admitted (signed, same-user) client can end
  the current agent dictation, because `openwhisp dictate --stop` from your own
  second shell must always work. They never start anything or read any text.
- **The cloud gate.** If your AI provider is OpenAI (cloud), agent-initiated
  refinement is **blocked** unless you turn on *Allow agents to use cloud AI* —
  so a prompt-injected agent can't exfiltrate text through your key. Local
  providers are unaffected.
- **The human wins the mic.** Pressing your dictation hotkey during an agent
  session cancels it (the agent gets nothing) and starts your own. Agent
  microphone use always shows the overlay. Password fields are never dictated
  into.
- **Rate limited.** Even a client you've *always* allowed can't hold the mic
  continuously: each client gets a short cooldown after each session ends, a cap
  on sessions per hour, and a budget of total mic time per hour (a session cap
  alone can't bound listening — a handful of max-length sessions add up to the
  whole hour). A throttled `dictate` fails fast (exit code `4`, same as
  busy) with a `retryAfterSeconds` hint telling the agent how long to wait — it's
  a distinct `rateLimited` reason on the wire, so a well-behaved agent backs off
  instead of hammering. Belt-and-suspenders on top of consent and the overlay.

## Notes

- **Silence auto-stop.** An agent dictation ends automatically once you stop
  talking, so a spoken answer returns promptly instead of waiting out the
  timeout. On by default; toggle it in **Settings → Agent Bridge → Behavior →
  Stop listening on silence**. It applies **only** to agent-requested dictation —
  your own dictation hotkey is unaffected.
- **Progress during `dictate`.** While a `dictate` call is blocked waiting for
  the user, the MCP adapter streams `notifications/progress` (about every 10s) if
  the client passed a `progressToken`. This keeps agents with short tool-call
  timeouts alive — **Cursor** caps tool calls near 60s. Claude Code's stdio tool
  timeout is effectively unlimited.
- The MCP adapter speaks MCP's newline-delimited JSON-RPC 2.0 stdio transport
  directly (no third-party SDK dependency).
