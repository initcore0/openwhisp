# OpenWhisp vs. the alternatives

An honest comparison of "voice for your agent" options. **The OpenWhisp column
describes only what the code in this repository actually does** — every claim maps
to the Agent Bridge, CLI, or MCP adapter implementation. The competitor columns
are our best-effort summary of publicly documented behavior; they change over
time, so verify against each vendor's current docs before relying on them.
Competitor claims below were last checked on **2026-07-18** against the sources
cited under each product — treat anything undated as potentially stale.

## What's being compared

- **OpenWhisp** — this project. On-device dictation with an Agent Bridge that
  exposes `openwhisp_dictate` / `openwhisp_refine` / `openwhisp_history` over MCP +
  CLI.
- **Claude Code `/voice`** — Claude Code's built-in voice dictation.
  (Source: `code.claude.com/docs/en/voice-dictation`.)
- **VoiceMode** — the community MCP voice server (`voice-mode`) that gives agents
  speak/listen tools, typically wired to cloud STT/TTS.
- **Spokenly** — a closed-source macOS dictation app that also ships a local MCP
  server for agent question loops.
  (Source: `spokenly.app/docs/macos/voice-for-agents`.)
- **Superwhisper** — a macOS dictation app that added Claude Code / OpenCode agent
  integration in **v2.13.0** (2026-04-24).
  (Source: `superwhisper.com/changelog`.)

## At a glance

| | **OpenWhisp** | Claude Code `/voice` | VoiceMode (MCP) | Spokenly |
|---|---|---|---|---|
| **MCP server for agents** | Yes — three tools: `openwhisp_dictate` (ask by voice), `openwhisp_refine`, `openwhisp_history` | No — it's a dictation input for the CLI, not an MCP server for the agent to call | Yes — speak/listen tools | Yes — a **free** local MCP server at `localhost:51089` exposing one tool, `ask_user_dictation` (per its docs) |
| **Transcription latency** | Local, no network round-trip; silence auto-stop returns the answer promptly | Cloud round-trip (audio streamed to Anthropic's servers) | Cloud STT round-trip typical | Local dictation |
| **Privacy / where audio goes** | 100% on-device (WhisperKit / whisper.cpp on the ANE); nothing leaves the Mac unless you opt into a cloud LLM for *refine* only | Audio is streamed to Anthropic's servers; "Audio is not processed locally" (their docs) | Commonly cloud STT/TTS | On-device dictation; its agent-question **TTS uses cloud credits** (per its docs) — check vendor docs for other cloud features |
| **Auth-mode independence** | Independent of how you auth the agent — works on subscription, `ANTHROPIC_API_KEY`, or Bedrock | **No** — requires a Claude.ai login; not available with an API key, Amazon Bedrock, Google Cloud, or Microsoft Foundry (their docs) | Independent (separate MCP server) | Independent of agent auth |
| **Works over SSH / remote** | Yes — mic + overlay + bridge live on your local Mac; the agent reaches them over a local socket while working on a remote host | **No** — "does not work in remote environments such as Claude Code on the web or SSH sessions" (their docs) | Depends on the server | App-local |
| **TTS ask→answer loop** | Yes — reads the question aloud with **fully-local TTS**, then opens the mic *after* speech finishes so TTS isn't captured as the answer | It's dictation into the prompt, not an agent ask→answer voice loop | Yes (speak + listen tools) | Yes — reads questions aloud, but via **cloud TTS that consumes credits** (per its docs) |
| **EOU / silence auto-stop** | Yes — end-of-utterance auto-stop, on by default, agent sessions only | Recording stops after ~15s silence / 2min total (tap mode; their docs) | Depends on config | Per-question recording session (per its docs); auto-stop behavior not documented on the cited page |
| **Editor / client coverage** | Any MCP client: Claude Code, Cursor, Hermes, OpenClaw, custom (stdio) + a shell CLI | Claude Code CLI + VS Code extension only | Any MCP client | Its own app + built-in setup flows for Claude Code, Codex, Cursor, and any MCP client (per its docs) |
| **Transport** | MCP adapter speaks JSON-RPC 2.0 over **stdio** (no third-party SDK); agent clients reach the app over a local UNIX-domain socket (`0600`), **signed-clients-only** by default | Built into the client | Depends on the server | Local HTTP on `localhost:51089` (per its docs) |
| **Open source** | **Yes — MIT** | No (part of Claude Code) | Yes (community project) | **No** — closed source |
| **Per-capability consent** | Yes — dictate / history / refine each prompt separately (always / while running / once / deny) | N/A (single built-in) | Depends on the server | Not documented on the cited page |
| **Cost model** | Free, local, no per-minute cloud STT | Included with Claude Code; transcription doesn't consume tokens (their docs) | Cloud STT/TTS usage may bill | MCP server is free; cloud TTS "consumes credits" and "may not be available on the free tier" (per its docs) |

## Where OpenWhisp wins

Spokenly's free local MCP server is a genuinely good option for an agent that just
needs to ask a spoken question — credit where due. OpenWhisp's edge is **breadth
and locality**, not the existence of the feature:

- **Three tools, not one.** OpenWhisp exposes `openwhisp_dictate`,
  `openwhisp_refine`, and `openwhisp_history` — ask by voice, rewrite text with your
  configured LLM, and read recent dictations. Spokenly's documented MCP surface is a
  single `ask_user_dictation` tool.
- **Fully-local TTS for agent questions.** OpenWhisp reads the question aloud
  on-device. Spokenly's agent-question TTS is **cloud-based and consumes credits**
  (its docs note it "may not be available on the free tier"); Claude Code `/voice`
  streams your audio to Anthropic's servers for transcription and "is not processed
  locally."
- **Nothing leaves your Mac.** Transcription runs on the Apple Neural Engine.
  `openwhisp_dictate` and `openwhisp_history` never touch the network;
  `openwhisp_refine` is the only tool that *can* reach a cloud provider, and only
  when you've selected a cloud LLM **and** flipped on **Allow agents to use cloud
  AI**. This is what lets HIPAA / privacy-locked orgs that disable native `/voice`
  still get voice-driven agents — Claude Code's docs confirm `/voice` is disabled
  under an organization's HIPAA policy.
- **Auth-mode agnostic.** Because it's a separate local MCP server, it works
  identically whether you drive Claude Code on a subscription login, a raw API key,
  or Amazon Bedrock. Claude Code `/voice`, by contrast, requires a Claude.ai login
  and is unavailable with an API key, Bedrock, Google Cloud, or Microsoft Foundry.
- **Works over SSH / remote.** The mic, the overlay, and the bridge live on your
  local Mac; the agent reaches them over a local socket while it works on a remote
  host. Claude Code `/voice` "does not work in remote environments such as Claude
  Code on the web or SSH sessions."
- **Open source (MIT) + signed-client-only transport + per-capability consent.**
  Approving voice questions doesn't grant history or refine; only OpenWhisp's own
  signed clients connect unless you explicitly allow third-party ones. Spokenly is
  closed source.
- **EOU auto-stop and stdio transport.** End-of-utterance auto-stop (on by default,
  agent sessions only) returns a spoken answer promptly, and the MCP adapter speaks
  JSON-RPC 2.0 over stdio directly with no third-party SDK dependency.

## Where the others may fit better

- **Spokenly** — if you want a free, drop-in local MCP `ask_user_dictation` loop
  with built-in setup flows for Claude Code, Codex, and Cursor, and you're fine with
  closed source and cloud-credit TTS for spoken questions. It's also a solid choice
  for general system-wide dictation into any app.
- **Superwhisper** — if you already use it for dictation and want its built-in
  Claude Code / OpenCode agent integration (added in v2.13.0, 2026-04-24) without
  running a separate MCP server.
- **Claude Code `/voice`** — zero install, nothing to register; if you have a
  Claude.ai login (not an API key / Bedrock), aren't in a HIPAA-gated org, work
  locally (not over SSH), and only need to *dictate prompts into the CLI* rather than
  have the agent ask you spoken questions, it's the simplest path.
- **VoiceMode** — if you want a fully spoken back-and-forth conversation (the agent
  *talks back* at length, not just asks a question), and cloud STT/TTS is
  acceptable, its speak/listen model is richer than OpenWhisp's ask→answer loop.

## A note on honesty

We can only speak authoritatively for OpenWhisp. The competitor cells are
deliberately hedged ("per its docs", "depends", "not documented on the cited page")
wherever we don't have first-hand certainty, because these products evolve and we'd
rather under-claim than mislead. Every competitor claim above is either quoted from
the vendor's own docs (cited under **What's being compared**, checked 2026-07-18) or
explicitly hedged. Where a source page didn't mention a feature — e.g. Spokenly's
per-capability consent or auto-stop behavior — we say so rather than assume. If you
spot a stale or wrong cell, please open an issue.

## See also

- [Claude Code guide](claude-code.md)
- [Cursor guide](cursor.md)
- [Generic MCP client guide](generic-mcp.md)
- [Agent Bridge reference](../AGENT_BRIDGE.md)
