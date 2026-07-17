# OpenWhisp vs. the alternatives

An honest comparison of "voice for your agent" options. **The OpenWhisp column
describes only what the code in this repository actually does** — every claim maps
to the Agent Bridge, CLI, or MCP adapter implementation. The competitor columns
are our best-effort summary of publicly documented behavior; they change over
time, so verify against each vendor's current docs before relying on them.

## What's being compared

- **OpenWhisp** — this project. On-device dictation with an Agent Bridge that
  exposes `openwhisp_dictate` / `openwhisp_refine` / `openwhisp_history` over MCP +
  CLI.
- **Claude Code `/voice`** — Claude Code's built-in voice mode.
- **VoiceMode** — the community MCP voice server (`voice-mode`) that gives agents
  speak/listen tools, typically wired to cloud STT/TTS.
- **Spokenly** — a macOS dictation app with agent/assistant integration.

## At a glance

| | **OpenWhisp** | Claude Code `/voice` | VoiceMode (MCP) | Spokenly |
|---|---|---|---|---|
| **Transcription latency** | Local, no network round-trip; silence auto-stop returns the answer promptly | Depends on its speech backend | Cloud STT round-trip typical | Local dictation |
| **Privacy / where audio goes** | 100% on-device (WhisperKit / whisper.cpp on the ANE); nothing leaves the Mac unless you opt into a cloud LLM for *refine* only | Can route audio to a cloud speech service (why some orgs disable it) | Commonly cloud STT/TTS | On-device dictation; check vendor docs for any cloud features |
| **Auth-mode independence** | Independent of how you auth the agent — works on subscription, `ANTHROPIC_API_KEY`, or Bedrock | Can be gated by Claude Code auth mode | Independent (separate MCP server) | Independent of agent auth |
| **TTS ask→answer loop** | Yes — reads the question aloud, then opens the mic *after* speech finishes so TTS isn't captured as the answer | Yes (voice conversation) | Yes (speak + listen tools) | Not an agent ask→answer loop in the same sense |
| **EOU / silence auto-stop** | Yes — end-of-utterance auto-stop, on by default, agent sessions only | Varies | Depends on config | N/A for the agent loop |
| **Editor / client coverage** | Any MCP client: Claude Code, Cursor, Hermes, OpenClaw, custom (stdio) + a shell CLI | Claude Code only | Any MCP client | Its own app + supported integrations |
| **Transport** | Local UNIX-domain socket (`0600`), signed-client-only by default | Built into the client | Depends on the server | App-local |
| **Per-capability consent** | Yes — dictate / history / refine each prompt separately (always / while running / once / deny) | N/A (single built-in) | Depends on the server | N/A |
| **Cost model** | Free, local, no per-minute cloud STT | Included with Claude Code | Cloud STT/TTS usage may bill | Per its own pricing |

## Where OpenWhisp wins

- **Nothing leaves your Mac.** Transcription runs on the Apple Neural Engine.
  `openwhisp_dictate` and `openwhisp_history` never touch the network;
  `openwhisp_refine` is the only tool that *can* reach a cloud provider, and only
  when you've selected a cloud LLM **and** flipped on **Allow agents to use cloud
  AI**. This is what lets HIPAA / privacy-locked orgs that disable native `/voice`
  still get voice-driven agents.
- **Auth-mode agnostic.** Because it's a separate local MCP server, it works
  identically whether you drive Claude Code on a subscription login, a raw API key,
  or Amazon Bedrock — no dependency on native voice being enabled for your plan.
- **Works over SSH / remote.** The mic, the overlay, and the bridge live on your
  local Mac; the agent reaches them over a local socket while it works on a remote
  host. Native audio in a remote shell has nowhere to go.
- **Real ask→answer voice loop with anti-feedback.** It speaks the question, waits
  for the TTS to finish, *then* opens the mic — so the app's own voice is never
  captured and returned as your answer.
- **Per-capability consent + signed-client-only transport.** Approving voice
  questions doesn't grant history or refine; only OpenWhisp's own signed clients
  connect unless you explicitly allow third-party ones.

## Where the others may fit better

- **Claude Code `/voice`** — zero install, nothing to register; if your org allows
  its speech backend and you only use Claude Code, it's the simplest path.
- **VoiceMode** — if you want a fully spoken back-and-forth conversation (the agent
  *talks back* at length, not just asks a question), and cloud STT/TTS is
  acceptable, its speak/listen model is richer than OpenWhisp's ask→answer loop.
- **Spokenly** — if your primary need is general system-wide dictation into any
  app rather than an agent question loop.

## A note on honesty

We can only speak authoritatively for OpenWhisp. The competitor cells are
deliberately hedged ("depends", "varies", "check vendor docs") wherever we don't
have first-hand certainty, because these products evolve and we'd rather under-claim
than mislead. If you spot a stale or wrong cell, please open an issue.

## See also

- [Claude Code guide](claude-code.md)
- [Cursor guide](cursor.md)
- [Generic MCP client guide](generic-mcp.md)
- [Agent Bridge reference](../AGENT_BRIDGE.md)
