# Agent Bridge

OpenWhisp can expose itself as a **local MCP server and CLI** so coding agents
(Claude Code, Cursor, Hermes, OpenClaw) can dictate on your behalf, rewrite text
with your on-device AI, and read your dictation history — all staying on your
Mac. It's **off by default**; nothing listens until you turn it on.

Enable it in **Settings → Agent Bridge**.

> **New here?** Start with a 5-minute setup guide:
> [Claude Code](guides/claude-code.md) · [Cursor](guides/cursor.md) ·
> [any MCP client](guides/generic-mcp.md). See how OpenWhisp compares to the
> alternatives in [guides/comparison.md](guides/comparison.md). This page is the
> full protocol/security reference behind those guides.

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
so any stamped v3 edit always wins over unstamped legacy data. Every merge is
**idempotent**: pushing the same payload twice changes nothing the second time
(`mergedCounts` all zero). The whole policy is the pure `SyncMerge` funnel in
`OpenWhispCore` and is exhaustively unit-tested.

**Clock skew is silently authoritative.** All `updatedAt` stamps are wall-clock
`Date()` on the mutating device; a device with a fast clock wins every LWW
conflict and a slow one can never overwrite. v1 accepts this (same-owner devices,
NTP-synced in practice); there is no skew detection.

**Two v1 scope limits, by design.** (1) **No tombstones:** a deleted vocabulary
entry / profile / mode leaves no trace, so union-by-id resurrects it from the
peer on the next sync — delete-then-sync brings it back. A tombstone model is
deferred. (2) **Import restamps:** applying an imported config or a bundled pack
restamps its (pre-v3, epoch-dated) entries to *now* — the act of importing is a
user edit, so the imported data wins the next sync rather than losing to a
stamped peer copy of the same id.

**History paging.** `sync.pull` returns history one page at a time so no NDJSON
frame exceeds `maxFrameBytes` (1 MiB): `sinceHistoryCursor` is the date
delta-filter ("everything I haven't seen"), then the server pages the filtered
set by a total-order (`date`+`id`) `pageCursor` — the client re-pulls with the
result's `nextHistoryCursor` while `hasMoreHistory` is true. Config sections ride
the first page only. The total-order cursor guarantees equal-timestamp entries
are never skipped.

### LAN transport (MAK-51 WP6-mac)

The paired iPhone reaches those verbs over the LAN, not the UNIX socket. A
`LANBridgeServer` advertises `_openwhisp._tcp` over **Bonjour**, accepts a
**TLS pre-shared-key** connection, and feeds each connection's NDJSON frames into
the *same* `BridgeRouter` → host pipeline the UNIX socket uses — routing, consent,
and rate-limit are reused verbatim, but the LAN link is **scoped to the sync
verbs** (`sync.*` + `bridge.hello`/`bridge.status`): dictate/refine/history are
answered with `methodNotFound` over the LAN, because a sync pairing must never
quietly become remote mic/LLM control. Authentication replaces code-signing with
two layers:

1. **TLS-PSK**: each paired device has one 32-byte PSK; a client whose PSK isn't
   registered can't complete the handshake, so no unpaired device yields a byte.
2. **Hello identity proof** (BINDING contract, see `LANPeerProof`): TLS proves
   the client held *some* registered PSK, but not *which* (the metadata API
   enumerates the locally-configured PSKs, not the negotiated one) — so the
   client's `bridge.hello` must carry `peerID` plus
   `peerProof = base64(HMAC-SHA256(key: psk, msg: "openwhisp-peer-binding:" + peerID))`.
   The server verifies the proof against the PSK it stored for that peer and
   closes the connection on any mismatch. This is what binds consent to a
   specific paired device and stops one paired phone from riding another's
   grants.

- **Pairing** is out-of-band: **Settings → Sync → Pair iPhone…** shows a QR the
  phone scans. The QR JSON is
  `{ version, peerID, displayName, psk (base64 of 32 random bytes), serviceInstanceName }`.
  A freshly-minted pairing is staged **in memory only** — the PSK enters the Mac
  **Keychain** (keyed by the peer UUID) and the peer joins the device list only
  once the phone connects and proves it (an abandoned QR leaves nothing behind,
  and closing the sheet discards the staged PSK). **Unpair** destroys the
  Keychain PSK, drops the connection, and revokes the device's consent record,
  so that device can no longer authenticate.
- **TLS.** We request the version range **TLS 1.2…1.3** with the PSK AEAD
  ciphersuite `TLS_PSK_WITH_AES_128_GCM_SHA256`. The intent is TLS 1.3, but
  Network.framework's `NWListener` does not accept an external TLS-1.3 PSK on the
  SDK the CI runners ship, so it negotiates down to TLS 1.2 with the PSK suite,
  which preserves the property that matters: a 32-byte pre-shared key, AEAD
  encryption, **no certificate/CA**, and nothing readable on the wire before the
  handshake. The iOS `SyncKit` client MUST use the same version range +
  ciphersuite and add its `(psk, peerID-as-identity)` pair, or the handshake
  won't complete.
- **When it runs.** The listener runs **only** while at least one device is
  paired, or while the pairing pane is open — a user who never pairs pays zero
  cost and nothing is exposed on the LAN.

**Cross-repo integration harness.** `scripts/sync-loopback-server.sh` boots the
real `LANBridgeServer` standalone on `127.0.0.1` with a fixed PSK + port + a
file-backed fixture store (all from `OPENWHISP_SYNC_PSK` / `OPENWHISP_SYNC_PORT` /
`OPENWHISP_SYNC_PEER_ID` / `OPENWHISP_SYNC_FIXTURE_DIR`) and prints `READY <port>`
once listening, so the openwhisp-ios sync test can drive it over TLS-TCP. The
in-repo `OpenWhispSyncLANTests` E2E does the same in-process: real server, real
TLS-PSK NDJSON client, hello → consent → manifest → push → pull.

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
openwhisp dictate --prompt "Which file?" --terms "AppState.swift,RefineFlow"  # extra bias terms
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

**Workspace context (agent-context vocabulary).** So that spoken dev terms — a
branch name, a file name, the project name — transcribe correctly, a dictation
that originates from an agent can carry **workspace context**: the working
directory, the git branch, and file/symbol names. OpenWhisp splits these into
speakable bias terms (camelCase / snake_case / kebab / dotted), merges them with
your custom vocabulary **for that one session only** (never written to your
vocabulary store), and feeds them into whichever engine bias path the current
engine honors (whisper.cpp / WhisperKit prompt tokens, Apple Speech
`contextualStrings`; Parakeet's batch-only and SpeechAnalyzer's unwired paths
get nothing, per the capability model) *and* — for a local LLM — into the
cleanup prompt as reference-only spelling context. It's OpenWhisp's local
equivalent of Claude Code's `/voice` project-name + branch hints.

This is data **about the client's own workspace**, used **locally only** to prime
recognition and (for a local model) cleanup — it never leaves the machine and is
never persisted, so it needs no new consent scope. API-key-shaped tokens in a
path or branch are rejected before they can bias (and so can't be echoed into a
transcript).

- **MCP path — zero client changes.** The `openwhisp mcp` server runs as a stdio
  child in the MCP client's working directory, so it **self-derives** `cwd` + git
  branch on each `openwhisp_dictate` call. Set
  `OPENWHISP_MCP_WORKSPACE_CONTEXT=0` (or `false`/`off`/`no`) in the server's
  environment to disable that auto-derivation. A client may also pass an explicit
  `context` object (`{cwd, gitBranch, terms}`) on the tool call — for example to
  add recently-edited file names as `terms`; an explicit value wins over, and
  merges with, the self-derived ones (and is honored even when auto-derivation is
  opted out).
- **CLI path.** `openwhisp dictate` self-derives `cwd` + branch from its own
  shell the same way; `--cwd`, `--git-branch`, and `--terms "a,b,c"` override.
- **Wire.** `dictate` params carry an optional `context: {cwd?, gitBranch?,
  terms?}` (additive — older clients omit it).

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
- **Workspace context is local-only.** The cwd / git-branch / file-name terms an
  agent dictation carries (see *Workspace context* above) are used solely to
  prime on-device recognition and a **local** cleanup model — they're never sent
  to a cloud provider, never written to your vocabulary store, and dropped at
  session end. They describe the client's own workspace, so they add no new
  consent scope; secret-shaped tokens are rejected before they can bias.
  Disable server-side auto-derivation with `OPENWHISP_MCP_WORKSPACE_CONTEXT=0`.
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
