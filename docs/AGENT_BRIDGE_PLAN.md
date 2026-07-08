# M8 — Agent Bridge: local control plane, CLI, and MCP server

**Status:** Plan (not yet implemented). **Supersedes:** nothing; extends the M0–M7 roadmap.
**Doubles as:** the long-deferred `DictationCoordinator` extraction from the ~3,468-line `AppState.swift`.

This plan is the synthesis of a multi-agent design pass: six read-only code mappers + four technical
fact-checks, then three independently-authored designs judged by a three-judge panel. The
**incremental-first** design won (106/96/85 across judges) for protecting the working daily-driver app;
the security and adoption designs contributed the grafts folded in below. Every judge concern is tracked
in [§10](#10-hardening-decisions-resolved-judge-concerns).

---

## 1. What we are building and why

A **local control plane** exposed by the running OpenWhisp app, plus two thin adapters that are dumb
clients of it:

```
Claude Code / Cursor / Hermes Agent / OpenClaw
        │  (spawns; stdio JSON-RPC)
   openwhisp mcp          ← MCP stdio server, ships in the .app bundle
        │
   openwhisp <verb>       ← agent-callable CLI (transcribe/refine/dictate/history), same bundle
        │  (local IPC: unix socket, 0700 dir / 0600 socket, peer-verified)
   OpenWhisp.app          ← the running menu-bar app: overlay, engines, history, all state
```

**The wedge (verified market facts, 2026-07-03 deep-research pass, primary-source verified):**
no product ships **system-wide dictate + refine + history behind one local MCP server**, and **no product
exposes a `refine` tool at all**. Spokenly ships only `ask_user_dictation` over TCP `localhost:51089`;
Voicebox ships a TTS-first 4-tool HTTP server on `127.0.0.1:17493`; VoiceMode does agent voice
*conversations* only. Claude Code's own voice is cloud-only and unavailable on API-key/Bedrock/Vertex/Foundry
auth and disabled for HIPAA orgs — a captive segment a 100%-local bridge serves and cloud dictation
competitors structurally cannot. VoiceInk issues [#91](https://github.com/Beingpax/VoiceInk/issues/91)/[#704](https://github.com/Beingpax/VoiceInk/issues/704) (MCP) and [#801](https://github.com/Beingpax/VoiceInk/issues/801) (agent-callable CLI, verbatim) are open and unshipped.

**Why a control plane, not a plugin system:** OpenWhisp holds the three scariest macOS TCC grants
(microphone, Accessibility, input synthesis). In-process third-party code silently inherits all of them,
which would turn "never phones home, fully yours" into a keyl-distribution platform. An MCP stdio server is
*already* a separate process the agent spawns — so the safe out-of-process architecture is the natural one.
The control-plane API surface **is** the `DictationCoordinator` extraction: it forces us to name the
operations `AppState` currently smears across 3,468 lines. Anything that speaks JSON over the socket (a
Raycast script, a Hammerspoon config, a user's Rust daemon) can extend OpenWhisp from outside — more
hackable than dylib plugins, with no ABI and no trust inheritance.

**Two personas, one app** (do **not** split into two apps — they share the engines, the overlay, and the
TCC grants): pure-dictation users pay nothing (Agent Bridge is default-off; off means no socket, no
listener thread, no overhead on the dictation hot path). Agent-native users flip one toggle and every
MCP-aware agent can dictate on their behalf, refine text through their local LLM, and read their voice
history — all local.

---

## 2. Transport & wire format

- **Transport:** UNIX domain socket at `~/Library/Application Support/OpenWhisp/agent.sock` (parent dir
  `0700`, socket `chmod 0600`, stale socket unlinked before `bind()`). Path is ~55 chars, safely under the
  104-byte `sockaddr_un.sun_path` limit; a short filename preserves headroom for long usernames. For
  pathological (>104-byte) home paths, fall back to `$TMPDIR/openwhisp-<uid>/bridge.sock` and write a
  `bridge.path` pointer file clients read first (graft from adoption-first) — better than failing closed for
  a legitimate long username.
- **Why UDS over `127.0.0.1` TCP** (what Spokenly/Voicebox do): loopback TCP has **no peer credentials**, is
  reachable by any local user, by sandboxed apps holding `network.client`, and by browser pages via DNS
  rebinding. The socket file is gated by filesystem perms **and** supports `getpeereid`/`LOCAL_PEERTOKEN`.
  This is a documented security differentiator.
- **Why not XPC:** a mach-service `NSXPCListener` needs a launchd agent + Login Item, and our client is a CLI
  the app did not spawn (anonymous XPC listeners can't be discovered by an unrelated process). UDS fits the
  spawn model directly.
- **Wire format:** newline-delimited JSON-RPC 2.0 (one UTF-8 object per line, **1 MiB frame cap**),
  camelCase keys. Integer `protocolVersion` in the handshake with `ConfigBundle`'s reject-newer / tolerate-older
  decode semantics (`OpenWhisp/Services/ConfigBundle.swift` precedent). Requests client→app; responses **and**
  server-initiated notifications (`dictate.state`, `dictate.partial`) travel the **same** connection — no
  second channel, and **connection close doubles as cancellation** (crash-safe cleanup for free).

---

## 3. Authentication (per-connection, before reading any request bytes)

Three layers, evaluated at `accept()` in `AgentBridgeServer.swift`:

1. **`getpeereid(fd)`** → require peer `euid == geteuid()`. Kernel-guaranteed; kills the cross-user case.
2. **`getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`** → `audit_token_t` → `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`
   → `SecCodeCheckValidity` against a requirement **derived at runtime from the app's own signature**
   (`SecCodeCopySelf` → designated requirement / Team ID). Release builds thus require a Developer ID Team-ID
   match; dev builds signed with "OpenWhisp Self-Signed" verify against *themselves* with no hardcoded Team
   ID. **Never `kSecGuestAttributePid`** — PID-based lookup is the documented CVE-class race
   (Little Snitch CVE-2019-13013, OneDrive LPE, F-Secure CVE-2020-14977): a client can `exec` into a signed
   binary between connect and lookup. `LOCAL_PEERTOKEN` names one specific process *incarnation*
   (`audit_token` carries `p_idversion`), which is why it's used instead of `LOCAL_PEERPID`.
3. **Reserved, not shipped in v1:** an optional bearer-token field in `bridge.hello`, plus a per-launch token
   file (`0600`, constant-time compare) so a future TCP/HTTP transport can be added without a wire break
   (graft: ship the token layer in v1 if cheap — ~20 lines, second independent same-user proof).

A Settings toggle **"Allow unsigned / third-party clients"** (default **OFF**, never silently downgraded)
relaxes layer 2 only — on-brand for the hackable positioning, explicit opt-in for users writing their own
clients.

**Failure behavior:** any check failing (euid mismatch, `getsockopt` error, *any* `SecCode` error, malformed
first frame, `protocolVersion` newer than supported) → `close(fd)` **immediately with no response** (no oracle
about which check failed). `os_log` the pid/euid; **≥3 denials/minute → user notification** "A process was
blocked from controlling OpenWhisp" + a `SettingsCallout`.

**Consent-store integrity** (judge concern): `agent-clients.json` and the enable flag live in same-user-writable
plaintext, so a malicious same-user process could pre-approve itself by editing the file. Within the
same-user threat model this is acknowledged; the cheap mitigation is an HMAC over the consent store keyed by a
Keychain-held secret, re-checked on load. Ship the HMAC if time permits; document the residual risk if not.

---

## 4. Consent model

Layered, and **scoped** (graft from security-first — the single-grant designs lost points here):

0. **Master switch** — Agent Bridge default-OFF; enabling it in a new Settings pane is itself an act of
   consent. **Toggle-on pre-trusts the bundle's own TeamID-signed adapters** (graft from adoption-first), so
   the first Claude Code call needs zero extra dialogs on the happy path; first-use prompts remain for
   everything else.
1. **Client identity** — `bridge.hello` carries `clientName`/`clientVersion` (the MCP adapter forwards MCP
   `initialize` `clientInfo.name`, e.g. `claude-code`; the bare CLI sends `openwhisp-cli` + parent process
   hint). Because every connection already passed the signature gate, `clientName` is honest-but-claimed
   within the same-user boundary. **The consent record is keyed by the layer-2 `(signingIdentifier, teamID,
   cdhash-or-path)` the server already computed, with `clientName` display-only** (graft; closes the "any
   client can claim `claude-code`" gap all judges flagged) — and the consent UI says "**agents on this Mac**"
   honestly rather than implying per-agent identity.
2. **Scopes** (graft — do not ride history on a mic grant): at minimum **dictate/mic**, **history-read**, and
   **refine**, with **paste** a separate never-default privilege. Agent dictate sessions **never paste**
   (they return text to the agent), so paste stays a distinct capability.
3. **First-use approval** — the first call in an ungranted scope suspends the request and presents a consent
   window using the onboarding-window pattern (`NSWindow` + `makeKeyAndOrderFront` + `NSApp.activate`,
   `main.swift` precedent — no `NSAlert` exists in the app and the overlay panel can never be key). It shows
   the verified binary identity, claimed client name, the specific scope requested, and choices
   **Ask every time / Allow while running / Always allow / Deny**. Deny (or window close, or 60s no-answer)
   → `consentDenied`, and a **denied record is stored so subsequent calls fail fast without re-prompting**
   (no consent spam; un-deny in Settings).
4. **Consent-window presentation** (judge concern): detect fullscreen / Do Not Disturb / screen-sharing;
   defer with a **menu-bar badge** rather than stealing focus over a fullscreen app; **debounce initial
   keyboard input** on the window (~300 ms) so a stray Return/Space can't accidentally Allow; relay `pending`
   to the agent (see §5) so an unattended workflow reports "waiting for user approval" instead of hanging.
5. **The cloud-refine gate** (the #1 graft — all three judges named it): refuse agent-initiated `refine`
   (and force-off whole-text enhancement for agent sessions) when `llmProvider == openai` **unless** the user
   flips an explicit **"Allow agents to use cloud AI"** toggle → error `cloudRefineDisabled`. Without this a
   prompt-injected agent exfiltrates arbitrary text through the user's OpenAI key — a direct hole in the
   never-phones-home moat. `status` also exposes `sendsTextToCloud` so adapters can disclose posture before
   calling.
6. **Agent dictate skips whole-text LLM enhancement** (graft) — returns the raw transcript; the agent calls
   `refine` explicitly when it wants cleanup. This preserves the moat, removes bundled-LLM cold-start latency
   from every dictate round-trip, and avoids the `quiesceWhisper` hazard (see §7 step 7).

---

## 5. Control-plane API (`agent.sock`)

All methods JSON-RPC 2.0. `bridge.hello` must be the first message on a connection. Response fields are
additive-only within a `protocolVersion`; unknown request fields are ignored (tolerant decode).

| Method | Params | Returns | Notes |
|---|---|---|---|
| `bridge.hello` | `{protocolVersion, clientName, clientVersion, parentProcess?}` | `{protocolVersion (negotiated=min), appVersion, capabilities: [String], clientId, consent: granted\|pending\|denied}` | First message or the connection closes. `capabilities` (e.g. `["dictate","refine","history"]`) lets adapters degrade gracefully and gates deferred tools. `consent` + a `bridge.consent` notification let adapters render "waiting for approval" (graft). |
| `status` | `{}` | `{appVersion, engine, model, sessionActive, llmConfigured, llmProvider, sendsTextToCloud, historyEnabled}` | Read-only. **First method implemented** (step 3) so the whole transport/auth stack is verifiable before any session-touching code exists. The CLI's liveness probe. |
| `dictate` | `{prompt?, timeoutSeconds?=60 (max 300), language?}` | `{text, durationSeconds, timedOut, endedBy: user\|timeout\|stop}` | **Blocking**: response sent when the session finalizes. Server pushes `dictate.state {state}` and (v1.1) `dictate.partial {text}` notifications on the same connection. Routed through the existing `startDictation` entry with `initiator=.agent`, `suppressOutput=true`. |
| `dictate.stop` | `{}` | `{stopped}` | Agent-signaled "user said they're done" finalize (graft) — maps to the existing `pendingStop` discipline. Returns partial text via the pending `dictate` response with `endedBy: stop`. |
| `dictate.cancel` | `{}` | `{cancelled}` | Cancels **this connection's** in-flight dictate (session-ID guarded so it can never kill a user session). The pending `dictate` then errors `cancelled` and returns **no text, ever** (see §10 Esc invariant). |
| `refine` | `{text, instruction}` | `{text}` | The unclaimed differentiator. Reuses the overlay-refine contract exactly: `InstructionChain.systemDirective` as `customInstruction` + `InstructionChain.userPayload(instruction:text:)` via `translationService.processFinalText`, endpoint/model from the user's provider, bracketed by `ensureBundledLLMReady`'s `requestStarted/requestFinished`. Gated by the cloud-refine toggle. On LLM failure returns the **original text in `error.data`** (graft; mirrors the overlay's `.llmFailed` insert-unrefined) with an explicit error code so the agent knows refinement didn't happen. |
| `history.list` | `{limit?=20 (max 200)}` | `{entries: [{id, text, date (ISO8601), appBundleID?, appName?, initiator?}]}` | Served from `AppState`'s in-memory array on the MainActor (**not** by reading `history.json` out-of-process — the app is single-writer and clobbers external reads). Empty when `historyEnabled` is off (explainable empty, not error). **History filtering is required** (see §10). |
| `transcribe.file` | `{path, language?}` | `{text}` | **DEFERRED to v1.1** (name/description reserved, capabilities-gated). See §6. |

**`promptText` sanitization** (graft — was an open question, now a requirement): the agent's `prompt` shown
in the overlay is **plain text only, hard length cap (200 chars), control + bidi/RTL characters stripped**,
and **always rendered prefixed by the verified client name** ("Claude Code asks: …") so agent-controlled text
can never impersonate OpenWhisp UI.

---

## 6. MCP tools (`openwhisp mcp`)

Built on the **official MCP Swift SDK** — `github.com/modelcontextprotocol/swift-sdk`, pinned `.exact("0.12.1")`
(server support is mature: `Server` + `withMethodHandler(ListTools/CallTool)` + `StdioTransport`; pre-1.0, so
pin exactly). Tool names are **namespaced** `openwhisp_*` (graft — Anthropic's documented guidance; avoids
cross-server collisions). Descriptions lead with the trigger condition ("Call this when…") — the #1 lever for
whether an agent ever calls a niche tool. The MCP server's `instructions` field at `initialize` carries the
"ask questions by voice" guidance so it works even before a CLAUDE.md edit.

- **`openwhisp_dictate`** — "Call this whenever you need to ask the user a question, get a decision, or
  collect free-form input mid-task — instead of ending your turn with a plain-text question. Activates the
  user's on-device voice overlay; your prompt is shown on their screen, they speak, and their answer returns
  as transcribed text. Everything runs locally; no audio leaves the machine." → `dictate`.
- **`openwhisp_refine`** — "Call this when you have text to rewrite per a natural-language instruction using
  the user's own on-device LLM — cleaning up a raw transcript, changing tone, tightening wording, applying
  their personal style. Same model and prompt chain as the user's refine hotkey." → `refine`.
- **`openwhisp_history`** — "Call this when the user refers to something they recently dictated ('what I just
  said', 'my last dictation', 'that note I dictated in Slack'). Returns recent dictation history, newest
  first, with text, ISO-8601 timestamp, and the app it was dictated into." → `history.list`.
- **`openwhisp_transcribe_file`** (v1.1, not in the v1 server; designed once, capabilities-gated) → `transcribe.file`.

**MCP long-running-tool handling** (`dictate` blocks 5–120 s):
- Emit `notifications/progress` every 10 s while listening (message like "Listening — 12 s") when the client
  sent a `progressToken`; honor `notifications/cancelled` by sending `dictate.cancel`; stdin/connection close
  → session cancelled in-app.
- **Timeout posture (corrected — judge concern, all three got the arithmetic wrong):** Claude Code stdio
  tools default to **effectively unlimited** wall clock (`MCP_TOOL_TIMEOUT` unset ≈ 28 h) and are exempt from
  the idle timeout, so a per-server `"timeout"` in `.mcp.json` only **lowers** the ceiling. **Omit the timeout
  for Claude Code.** Cursor and other MCP-TypeScript-SDK-derived clients default to a **60 s** request timeout
  with no `resetTimeoutOnProgress` — so the adapter **caps `timeoutSeconds` at 50 universally** unless it
  positively identifies Claude Code via `clientInfo`, and the shipped Cursor docs say answers must arrive
  within ~55 s.

---

## 7. `openwhisp` CLI

Ships in `Contents/Helpers/openwhisp` inside the bundle. **stdout = result only** (the transcript / refined
text / JSON), **all diagnostics to stderr** — so `openwhisp dictate | pbcopy` and `pbpaste | openwhisp refine
-i 'make it formal' | pbcopy` just work (the verbatim VoiceInk #801 use case). Uniform, sysexits-compatible
exit codes.

| Verb | Behavior |
|---|---|
| `openwhisp status [--json]` | Liveness probe. `OpenWhisp <v> · engine=<e> model=<m> llm=<configured\|unconfigured> session=<idle\|active>`. Exit 0 ok, 2 unreachable. |
| `openwhisp dictate [--prompt T] [--timeout S] [--language C] [--json]` | Blocks while the user speaks; transcript to stdout, progress to stderr. |
| `openwhisp refine --instruction T [TEXT \| stdin] [--json]` | Refines the arg or stdin. Refined text to stdout. |
| `openwhisp history [--limit N] [--json]` | One line per entry (`date \t appName \t text`), or `--json`. Exit 0 even when empty. |
| `openwhisp cancel` | Panic button — cancels the active agent session (graft). |
| `openwhisp mcp` | Runs the MCP stdio server. All logging to stderr; one `Server` per invocation. |
| `openwhisp setup <claude-code\|cursor\|hermes\|openclaw\|agents-md> [--print]` | **Actually writes the config** (graft — the difference between adoption and shelfware): runs `claude mcp add openwhisp -- "<resolved bundle path>" mcp` and appends the CLAUDE.md / AGENTS.md / `.cursor/rules` trigger snippet with a confirmation prompt; `--print` falls back to copy-paste. **Resolves its own bundle path at runtime (`Bundle.main`)** so the snippet isn't broken for `~/Applications` or renamed bundles (judge concern). |
| `openwhisp transcribe FILE [--language C] [--json]` | v1.1, hidden until the capabilities handshake advertises it. Never deletes/modifies FILE. |

**Exit codes:** 0 success · 1 internal/engine error · 2 app unreachable (message: "OpenWhisp not running, or
Agent Bridge is disabled in Settings → Agent Bridge") · 3 consent denied · 4 busy · 5 cancelled · 6 timeout
(no speech) · 7 permission/secure-field · 65 version mismatch.

---

## 8. Refactor sequence (each step compiles, passes `swift test`, is manually verifiable)

The ordering principle: **ship the bridge FIRST against the already-trigger-agnostic
`startDictation`/`stopDictation`/`cancelDictation` entry points** (verified: `AppState.swift:1077/1117/1135`,
`insertCompletedText:2590`, `finishSessionUI:2727`) with one additive nil-defaulted change to the sacred
funnel; the `DictationCoordinator` extraction comes **LAST**, with the bridge acting as a second production
driver and regression harness. Steps 1–5 provably cannot start a session.

0. **Platform floor (day-one decision, not a question).** `Package.swift` is `swift-tools-version:5.9` /
   `.macOS(.v13)`; `build.sh` targets `arm64-apple-macosx14.0`; the MCP SDK wants Swift 6.0+ / macOS 13+.
   **Decision:** keep the core library at `.macOS(.v13)`, set `.macOS(.v14)` on the new CLI executable target
   only, and bump `swift-tools-version` as needed for the SDK. Resolve deliberately before adding the first
   dependency, or CI resolves it by accident.
1. **`BridgeWire` DTOs in the core module.** New `OpenWhisp/Services/BridgeWire.swift`: pure `Codable`
   request/response/notification/error types, error-code enum, `protocolVersion=1` with `ConfigBundle`-style
   reject-newer decode, ISO8601 date coding, its own `HistoryEntryDTO` (no existing core type goes public).
   `Tests/OpenWhispCoreTests/BridgeWireTests.swift` (round-trip, version rejection, tolerant decode). No
   app-side change. *Risk: ~zero.*
2. **Dormant session plumbing in `AppState`.** `SessionInitiator` enum (`.user` / `.agent(client, prompt)`);
   a `suppressOutput` session snapshot (frozen in `beginSession` like `isPreviewSession`, cleared in
   `finishSessionUI`); a `sessionOutcome` set at each existing terminal point; an optional `onSessionEnd`
   callback keyed to `activeSessionID`, fired **exactly once** in `finishSessionUI`. `insertCompletedText`
   checks `suppressOutput` exactly where it checks `isPreviewSession`: skip paste/clipboard/ScriptRunner,
   **still record history**. *Risk: low-medium — touches the most-guarded code, but purely additively with
   nil/false defaults; `finishSessionUI` as the single fire-once site sidesteps the 12-terminal-points
   problem.*
3. **`AgentBridgeServer` skeleton, read-only methods only.** New `OpenWhisp/Services/AgentBridgeServer.swift`
   (app target, not in the core package — uses Darwin sockets + Security). `@Published agentBridgeEnabled`
   (UserDefaults, default false). When enabled: create App Support dir `0700`, unlink stale socket, bind,
   `chmod 0600`, accept loop on a background thread; per-connection auth; NDJSON loop; handlers hop to
   MainActor. Implement **only** `bridge.hello`, `status`, `history.list`. *Risk: low — default-off = zero
   hot-path overhead; read-only methods can't disturb a session; auth bugs fail closed.*
4. **`openwhisp` CLI executable target + bundle/signing.** `Package.swift`: first
   `.executableTarget(name: "openwhisp", dependencies: ["OpenWhispCore"], path: "Sources/OpenWhispCLI")` —
   **outside `OpenWhisp/`** so `build.sh`'s source glob never sees it. Hand-rolled arg parsing (defers the
   first external dependency to step 8). Implements `status` + `history` + the exit-code table + socket
   client. Build: `swift build -c release --product openwhisp` → `cp` to `Contents/Helpers/openwhisp`;
   **widen `build-dmg.sh`'s nested-signing to cover `Contents/Helpers` with hardened runtime**, and add a
   strict-verify (`codesign --verify --deep --strict`) to catch the release-signing trap in dev. *Risk:
   medium but confined to packaging; runtime untouched.*
5. **Consent store, consent window, Settings pane.** `AgentClientStore` (core, pure, tested): `agent-clients.json`
   with the **shared corrupt-quarantine idiom** — extract the 4×-duplicated quarantine helper while here (the
   [bug-hunt follow-up](bug-hunt-followups.md)). App-side: consent `NSWindow` (onboarding pattern,
   close/60s = deny, focus/fullscreen/DND handling per §4); a new **Agent Bridge** settings pane (between
   Profiles and Privacy) with per-scope toggles, per-client rows + Revoke, last-call line, a callout when a
   client is waiting, the copyable PATH symlink command, and clipboard-snippet buttons; a Privacy-pane
   summary banner. *Risk: low — additive UI + tested store.*
6. **`dictate` over the bridge** (first session-touching method). Handler: MainActor hop → scope/consent gate
   → busy guard (`isRecording || isTranscribing || sessionActive → busy`) → `startDictation` with
   `initiator=.agent`, `suppressOutput=true` → completion via `onSessionEnd` → response. Overlay: agent
   accent + "X asks:" row + always-show bypass for the agent initiator; agent fields cleared in
   `finishSessionUI` and `abortSessionBeforeStart`. Hotkey semantics per §10. Timeout: session-scoped `Task`
   with `activeSessionID` guard. *Risk: highest bridge step — but reuses the exact public entry points the
   menu already calls, busy-reject means no interleave with user sessions, `suppressOutput` means no paste.*
7. **`refine` over the bridge + CLI `dictate`/`refine`.** New `AppState.refineText(text:instruction:completion:)`
   reusing endpoint/model resolution, `ensureBundledLLMReady` with the `requestStarted/requestFinished`
   bracket fired **exactly once on every path**, `InstructionChain` directive/payload, `processFinalText`,
   completion rewrapped on MainActor. **Busy-reject while a session is active** (the `quiesceWhisper`
   hazard: refine's `ensureBundledLLMReady(quiesceWhisper:)` could stop the whisper-server under a live
   session — the only design that caught this). The differentiator is now demoable end-to-end. *Risk:
   low-medium; the one sharp edge is the done-exactly-once LLM bracket — copy the three existing call sites
   verbatim and unit-test with a fake.*
8. **MCP adapter + adoption kit.** Add `modelcontextprotocol/swift-sdk` `.exact("0.12.1")`, used **only** by
   the CLI target (the `build.sh` app build is unaffected; CI gains `Package.resolved` + a network fetch).
   `Server` + `withMethodHandler` + `StdioTransport`; stderr-only logging; the three namespaced tools with
   prescriptive descriptions; progress every 10 s during dictate; cancellation; the `instructions` field.
   Ship `openwhisp setup <agent>` + `docs/AGENT_BRIDGE.md` + the `.mcp.json` / CLAUDE.md / `.cursor/rules` /
   Hermes `~/.hermes/config.yaml` / OpenClaw stanzas. Reserve `io.github.<owner>/openwhisp` on the MCP
   registry once descriptions have survived a few weeks of real agent use (an `npx openwhisp-mcp` shim that
   locates and execs the bundle binary is the concrete path to registry publishing for a DMG-distributed
   binary — graft). *Risk: low — pure adapter over a working socket; SDK pre-1.0 churn contained by the exact
   pin.*
9. **`DictationCoordinator` extraction proper** (strangler, 3 shippable sub-steps) — deliberately **LAST**,
   now that the seam has two production drivers (hotkey + bridge) as a regression harness.
   (9a) `DictationSessionState` struct gathering the state inventory (`activeSessionID`,
   `sessionActive`/`pendingStop`, all snapshots incl. `suppressOutput`/`initiator`, `currentSessionText`, the
   refine quintet, `targetApplication`, `profileOverrideBackup`) with `AppState` pass-through computed
   properties so every hand-written guard keeps byte-identical semantics.
   (9b) Move the lifecycle funnel (`startDictation`/`stop`/`cancel`, `beginSession`/`abortSessionBeforeStart`,
   the three start/stop routes' orchestration, `handleTranscription` routing, `completeFinalText`,
   `insertCompletedText`) into `DictationCoordinator`, keeping UI-only concerns in `AppState`.
   (9c) Flip the bridge and hotkey paths to call the coordinator directly.
   *Risk: high — the three documented hazards live here (profile persistence suppression, the refine-latch's
   4 clear-sites, cancel-during-async discipline). Mitigated by shipping LAST (M8 user value never depends on
   it) and by individually-shippable strangler sub-steps.*

---

## 9. v1 scope

**v1 ships:** `agent.sock` control plane (default OFF, zero overhead when off) with
`bridge.hello`/`status`/`dictate`/`dictate.stop`/`dictate.cancel`/`refine`/`history.list`; three-layer peer
verification with silent-close deny; **scoped** per-client consent (window + store + Settings pane +
revocation) keyed to signing identity; the cloud-refine gate; agent-tinted always-visible overlay with the
sanitized "X asks:" row; `openwhisp` CLI in `Contents/Helpers` (status/dictate/refine/history/cancel/mcp/setup,
uniform exit codes, stdout=result-only); `openwhisp mcp` on Swift SDK 0.12.1 exposing the three namespaced
tools with progress/cancellation/instructions; the adoption kit; refactor steps 0–8; and step 9 sequenced last
(not a shipping gate).

**v1 explicitly defers, with reasons:**
- **`transcribe_file` → v1.1.** Three sharp edges: session-less request routing in `handleTranscription`; the
  `deleteWhenDone:true` foot-gun (the convenience overload **deletes the input on success and every error
  path** — `WhisperEngine.swift`); and format conversion (whisper.cpp accepts 16 kHz mono 16-bit WAV only).
  Real demand (VoiceInk #801) but nobody's mic depends on it. Tool name/description already reserved and
  capabilities-gated.
- **HTTP/TCP transport.** Kills the peer-credential security story; add only if a concrete client can't spawn
  stdio (the bearer-token field is reserved in `hello`).
- **TTS / `speak` / voice conversations.** The human↔agent bridge is symmetric by design — `speak` is one
  more control-plane verb on the same seam (AVSpeechSynthesizer first, a neural voice like Kokoro later as a
  downloadable *asset*, not code). Out of M8 scope.
- **Silence-VAD auto-stop** for agent dictate (see §11).

---

## 10. Hardening decisions (resolved judge concerns)

- **Esc / cancel invariant (hard rule):** Esc is the user's "discard this" gesture. A **cancelled** dictate
  returns **zero transcript text, ever** — never leak partials in `error.data` on cancel. **Timeout** and
  **`dictate.stop`** may return partial text (a slow answer beats none). Cancel ≠ timeout ≠ stop.
- **Hotkey semantics during an agent session (explicit matrix, not "tap = stop"):** the safe default is
  **cancel-agent-and-arm-user** — if the user presses the dictation hotkey during an agent session, cancel
  the agent session (returning no text) and start the user's own session, because "hotkey-down = stop agent
  and ship whatever was captured to the agent" is an intent inversion with exfiltration flavor. Define
  `down` vs `tap` vs `hold` (push-to-talk) vs the refine key vs Esc per `triggerMode`; a user holding Fn
  mid-agent-session must land their speech in *their* session, not the agent's.
- **First-ever mic use by an agent:** require microphone permission to be **already granted** — the bridge
  must not let an agent surface the macOS TCC mic dialog with no user gesture behind it. Error
  `micPermissionNeeded` with a deep link to grant it.
- **History filtering (required, not optional):** the `history` scope must not expose everything ever
  dictated into any app (password managers, banking, private messages). Ship at least a **per-app
  bundle-ID exclusion denylist** and a **per-client history window** (last N or last 24 h). The `appBundleID`
  metadata is already recorded — use it for policy. Consider an "agent sees only agent-initiated entries"
  mode.
- **Rate limiting on allowed clients (shipped, MAK-10):** deny-cooldowns aren't enough — an always-allowed
  client can chain max-length dictate sessions forever (overlay-visible but effectively continuous
  listening). `AgentRateLimiter` (pure, unit-tested) enforces a per-client **cooldown between dictation
  starts** *and* a **sessions-per-hour cap**, checked in `AppState.bridgeStartDictation` after the
  busy/permission/secure-field guards (those aren't the client's fault, so they don't consume budget) and
  keyed on the same `clientName` consent uses. Only accepted starts are recorded. A trip returns a distinct
  `rateLimited` reason (not `busy`) with a `retryAfterSeconds` hint so a well-behaved agent backs off; the
  CLI maps it to the busy exit code. Revoking a client clears its budget.
- **App update / quit mid-call:** `package.sh --install` `pkill`s the running app and `rm -rf`s the bundle,
  leaving a held `openwhisp mcp` process against a stale inode. Specify drain-on-quit (refuse new requests,
  resolve in-flight `dictate` with an "app quitting" error, `unlink` the socket in
  `applicationWillTerminate`); on next launch the app already unlinks the stale socket before bind. Document
  that Claude Code users respawn the MCP server after an app update (or the adapter reconnects on
  connection drop).
- **Connect-time-only auth (accepted residual risk):** the long-lived adapter connection is verified once at
  `accept()`. A post-connect `exec`/FD-pass inside that connection isn't re-checked — accepted under the
  same-user threat model, documented, with per-request re-verification as a future option for the
  long-lived case.
- **Concurrent LLM serialization:** two simultaneous `refine` calls (or `refine` racing whole-text
  enhancement) hit a single llama-server slot. The `requestStarted/requestFinished` bracket prevents idle
  teardown but does **not** queue — v1 **busy-rejects** concurrent LLM work; a post-step-9 scheduler could
  serialize instead.
- **`history.json` schema evolution:** adding `initiator` to `TranscriptionEntry` means new-app-written
  history is read by older app versions on downgrade. Tolerant decode covers unknown keys, but **version the
  file** the way `ConfigBundle` versions its envelope now that it's a semi-public surface.

---

## 11. Open questions

- Silence-VAD auto-stop for agent dictate (probably the correct UX for question-answering) — needs a VAD
  threshold on `AudioRecorder`'s level stream; ship v1 with hotkey-tap finish and instrument how often users
  reach for it.
- Should `refine` be allowed *while* a dictation session is active once the coordinator owns
  `ensureBundledLLMReady`? v1 busy-rejects solely because `quiesceWhisper` can stop the whisper-server under a
  live session; a post-step-9 scheduler could serialize.
- PATH install: v1 ships the copyable `ln -s` command; an in-app "Install command-line tool" button (needs
  admin auth) in v1.1?
- OpenClaw: track the upstream **pluggable Talk transcription provider** surface
  (`talk.catalog.transcription`) — if it accepts third-party engines, registering OpenWhisp as OpenClaw's STT
  engine (beyond MCP tools) is the higher-leverage integration and an **M9** item. See
  [ai-native-feature-research.md](../../.claude/projects/-Users-maksymnaboka-projects-mnaboka-openwhisp/memory/ai-native-feature-research.md).
- Hermes `optional-mcps/` catalog PR: submit once descriptions have proven out.

---

## 12. Provenance

Deep-research feature pass (run `wf_79c12516`): 103 agents, 21 sources, 25 claims verified by 3-vote
adversarial panels — established the market gap and the M8/M9/M10 pick. Design pass (run `wf_1c065a32`): 6
code readers + 4 technical fact-checks → 3 lens-diverse designs → 3-judge panel (incremental-first won
106/96/85), grafting the cloud-refine gate, scoped consent, `promptText` sanitization, signing-keyed consent,
one-command `setup`, and `dictate.stop`/fail-open/pending-relay from the runner-up designs. Full outputs in
the session scratchpad.
