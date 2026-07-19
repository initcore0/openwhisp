# Nothing leaves your Mac — and here's how to prove it

OpenWhisp's whole pitch is that your voice and your words stay on your machine.
That's a claim you should be able to *check*, not just trust. This page is the
proof: what "local-first" concretely means per feature, an honest enumeration of
**every** code path in this repo that can touch the network (with file
references and when it fires), and three independent ways to verify it yourself —
a one-liner, a reproducible script, and Little Snitch.

If you find a network path we didn't list here, that's a bug in this document
(or the app) and we want to know — see [SECURITY.md](../SECURITY.md).

---

## What "local-first" means, per feature

| Feature | Where it runs | Can it touch the network? |
|---|---|---|
| **Dictation / transcription** | Apple Neural Engine (Parakeet / WhisperKit / whisper.cpp) | **Never** — after the model is downloaded, transcription is 100% offline. |
| **Formatting, filler removal, "new paragraph", vocabulary** | On-device, pure text logic | **Never.** |
| **Local AI refine (cleanup / reformat)** | llama.cpp on your Mac (or a local `llama-server` / Ollama on your LAN) | **No egress off-device** with the local provider. |
| **Cloud AI refine** | api.openai.com | **Only if you opt in** — see touchpoint #3 below. |
| **History, insights, meetings, scratchpad** | On-disk under your user library | **Never** for storage. Sync (below) is LAN-only. |
| **iPhone sync** | Bonjour + TLS over your LAN | **LAN only** — never the public internet; see touchpoint #4. |
| **Update check** | github.com appcast (Sparkle) | **Yes, by default, ~once/day** — app+OS version only; see touchpoint #1. |
| **Model / engine download** | huggingface.co + CDNs | **First run only**, to fetch the model you chose; see touchpoint #2. |
| **Webhook / open-URL output rules** | Wherever *you* pointed them | **Only if you configured them**; see touchpoint #5. |

The single most important line: **the transcription path itself never opens a
socket.** Everything that *can* reach the network is either a one-time setup
fetch, an update check you can disable, or something you explicitly turned on.

---

## The complete network-touchpoint inventory

This is the honest, exhaustive list. It was built by grepping the source for
`URLSession`, `URLRequest`, `dataTask`, `NWListener`/`NWConnection`, Bonjour, and
every hard-coded host. Each entry says **what**, **where in the source**, and
**when it activates**.

### 1. Sparkle update check — DEFAULT ON

- **What:** fetches a small, EdDSA-signed `appcast.xml` over HTTPS to see if a
  newer OpenWhisp exists. Sends only your app version and macOS version (standard
  headers Sparkle adds). System profiling is deliberately **off**
  (`SUEnableSystemProfiling` is unset), so no hardware/usage profile is sent. No
  dictation text or audio is ever involved.
- **Destination:** `github.com` —
  `https://github.com/initcore0/openwhisp/releases/latest/download/appcast.xml`
- **Where:** `OpenWhisp/Info.plist` (`SUFeedURL`, `SU*` keys);
  `OpenWhisp/Services/UpdaterManager.swift`,
  `OpenWhisp/Services/UpdatePreferences.swift`; kicked off in
  `OpenWhisp/AppMain.swift` (see the "network call to fetch the appcast" note).
- **When:** on a scheduled interval (~once/day) and on manual "Check for
  Updates". **Turn it off** in **Settings → General → Software Update** — then
  OpenWhisp never contacts the network on its own.

### 2. Model / engine downloads — FIRST RUN ONLY

- **What:** downloads the transcription model you pick (and, if you enable it, a
  local LLM for on-device refine). One-time; cached locally afterward, then
  everything runs offline.
- **Destinations:**
  - **whisper.cpp models:** `huggingface.co/ggerganov/whisper.cpp/...` —
    `OpenWhisp/Resources/models/manifest.json`,
    `OpenWhisp/Models/AppState.swift` (`ModelDownloader`, a
    `URLSessionDownloadDelegate`, ~line 6365/6415).
  - **WhisperKit CoreML models:** `argmaxinc/whisperkit-coreml` on HuggingFace,
    fetched by the WhisperKit SDK's Hub client —
    `OpenWhisp/Services/WhisperKitModelCatalog.swift`.
  - **Parakeet models:** HuggingFace (`FluidInference` repos), fetched by the
    FluidAudio SDK (`AsrModels.downloadAndLoad`, `CtcModels.downloadAndLoad`,
    Nemotron multilingual) — `OpenWhisp/Services/ParakeetBridge.swift`.
  - **Local LLM (optional on-device refine):**
    `huggingface.co/Qwen/...`, `huggingface.co/bartowski/...` —
    `OpenWhisp/Resources/models/llm-manifest.json`.
  - HuggingFace serves large files via a CDN (`cdn-lfs*` / CloudFront), so you
    may see a CDN host rather than `huggingface.co` directly.
- **When:** only when a needed model isn't already on disk (first run, or when
  you switch engine/model). No per-transcription download.

### 3. Cloud AI refine (OpenAI) — OPT-IN, OFF BY DEFAULT

- **What:** the **only** path that can send your *dictated text* off-device. It
  POSTs the text you're refining to an OpenAI-compatible chat endpoint.
- **Destination:** `https://api.openai.com/v1/chat/completions` (the base URL is
  configurable; the same client also serves **local** `llama-server`/Ollama at
  `http://localhost:...`, which does **not** leave your machine).
- **Where:** `OpenWhisp/Services/OpenAITranslationService.swift`
  (`LLMEndpoint.openAI`, the `URLSession.shared.dataTask` calls);
  `OpenWhisp/Models/OpenAIRefiner.swift`.
- **When:** only when **all** of these hold — you selected the **cloud (OpenAI)**
  provider in Cleanup, *and* refine is actually invoked. For **agent-initiated**
  refine there's an additional gate: it's blocked unless you also enable
  **"Allow agents to use cloud AI"** (`OpenWhisp/Views/Settings/AgentBridgePane.swift`,
  enforced in `OpenWhisp/Services/BridgeWire.swift`). Pick a local provider and
  no text leaves the Mac. The API key is stored in the macOS **Keychain**.

### 4. iPhone sync — LAN ONLY, opt-in

- **What:** syncs vocabulary, per-app profiles, modes, and history with a paired
  iPhone. Discovery is **Bonjour on your LAN**; the link is **TLS with a
  pre-shared key you pair by QR**. Nothing goes to the public internet, and there
  is no cloud relay.
- **Where:** `OpenWhisp/Services/LANBridgeServer.swift` (an `NWListener`
  advertising `_openwhisp._tcp` over Bonjour, TLS-PSK connections),
  `OpenWhisp/Services/LANPairing.swift`, `OpenWhisp/Models/AppState+Sync.swift`,
  `OpenWhisp/Views/Settings/SyncPane.swift`; `NSBonjourServices` in
  `OpenWhisp/Info.plist`.
- **When:** only when you enable sync and pair a phone. The listener is torn down
  otherwise. It binds to the local network, not a routable internet address.

> Note: the **agent bridge** that Claude Code / Cursor talk to is **not** a
> network listener at all — it's a UNIX-domain socket (`0600`, signed-clients
> only) in `OpenWhisp/Services/AgentBridgeServer.swift`. It never opens a TCP
> port, so it won't appear in a network audit.

### 5. User-configured output sinks — only what YOU set up

- **What:** OpenWhisp can POST a transcript to a **webhook** or open a **URL**
  template — but only to endpoints **you** type into Settings. OpenWhisp ships no
  default webhook.
- **Where:** `OpenWhisp/Services/WebhookRequest.swift` (pure request builder),
  `OpenWhisp/Services/WebhookOutputTarget.swift` (the `URLSession` call),
  `OpenWhisp/Services/RuleEngineRunner.swift`; configured in
  `OpenWhisp/Views/Settings/OutputPane.swift` and
  `OpenWhisp/Views/Settings/RulesPane.swift`.
- **When:** only when you add a webhook/open-URL rule and it fires on a
  transcript. The destination is entirely yours.

**That's the whole list.** No analytics, no telemetry, no crash reporting, no
"phone home". If a future change adds a network path, it belongs in this table.

---

## Verify it yourself

### The one-liner

```sh
nettop -p "$(pgrep -x OpenWhisp)"
```

Run that, then dictate. During pure dictation you should see **no outbound
connections** — silence. The only things that can legitimately appear are the
touchpoints above (a daily Sparkle check, a first-run model download, or your
opt-in cloud refine). Disable **Settings → General → Software Update** to see
zero egress.

### The reproducible audit script

For a clearer, classified verdict — and something you can hand to a skeptical
teammate — use the bundled script:

```sh
scripts/audit-network.sh            # find OpenWhisp, watch 60s, dictate, get a verdict
scripts/audit-network.sh -d 30      # shorter 30s window
scripts/audit-network.sh -p 12345   # audit a specific PID
```

What it does:

1. Finds the running `OpenWhisp` process (or takes a `-p PID`). If the app isn't
   running it exits with a clear error — nothing to audit.
2. Watches that PID's network activity for the window (default 60s) using
   `nettop` and cross-checking open sockets with `lsof`, while you dictate.
3. Prints a **verdict**: every remote destination it saw, each **classified** as
   `SPARKLE-UPDATE`, `MODEL-DOWNLOAD`, `CLOUD-REFINE`, `APPLE-OS`, or —
   critically — **`UNEXPECTED`** for anything not on the known-legitimate list.
   Pure dictation should print `SILENCE`.

It's an observational tool: it reports what the OS says the process did. It can't
prove a negative by itself — that's what Little Snitch and the open source are
for — but it makes "watch it yourself" a single command anyone can reproduce.

### Little Snitch (belt and suspenders)

[Little Snitch](https://www.obdev.at/products/littlesnitch/) enforces at the
kernel level, so it catches anything a sampling tool might miss:

1. Put Little Snitch in **Alert Mode**.
2. Launch OpenWhisp and dictate. You should get **no connection prompts** from
   OpenWhisp during transcription.
3. The only prompts you should ever see map to the touchpoints above:
   `github.com` (update check), `huggingface.co`/a CDN (first-run model
   download), and — only if you turned it on — `api.openai.com` (cloud refine).
   **Deny** any of them and the rest of the app keeps working offline.
4. If OpenWhisp ever asks to reach a host **not** in the inventory above, that's
   exactly the kind of thing to report privately (see SECURITY.md).

### The ultimate check: read the source

OpenWhisp is MIT-licensed and open source — the audit is the code itself. Every
network path is listed above with its file. Grep for yourself:

```sh
grep -rInE 'URLSession|URLRequest|dataTask|NWListener|NWConnection|https://' OpenWhisp
```

You'll find exactly the touchpoints enumerated here and nothing else. That's the
strongest guarantee: not "trust us", but "here's all of it, go look."

---

## Idle footprint (measurement recipe)

"Local-first" shouldn't mean "melts your battery." OpenWhisp sits idle in the
menu bar most of the time; here's how to measure what it actually costs while
idle so we (and you) can hold it to a number.

**Recipe:**

1. Launch OpenWhisp, finish any first-run model download, and leave it **idle**
   (not dictating) for ~5 minutes so it settles.
2. Sample CPU and memory:

   ```sh
   # One-shot snapshot of just OpenWhisp:
   top -l 1 -stats pid,command,cpu,mem,threads -pid "$(pgrep -x OpenWhisp)"
   ```

   Or watch it live with `top -pid "$(pgrep -x OpenWhisp)"`, or use **Activity
   Monitor** (CPU tab → OpenWhisp) and note **% CPU**, **Memory**, and **Energy
   Impact** over a minute of idle.
3. Record the machine (chip, macOS version), the active engine, and whether a
   model was resident.

**Measured numbers: TODO — pending a live measurement run.**

> These are intentionally left blank. We will not invent idle CPU%/RAM figures;
> they belong here only after a real measurement on known hardware. If you run
> the recipe above, feel free to open a PR filling in the table with your
> machine + numbers, or share them in an issue.

| Metric | Value | Machine / macOS / engine |
|---|---|---|
| Idle CPU % | _TODO_ | _TODO_ |
| Idle memory (RSS) | _TODO_ | _TODO_ |
| Energy Impact (idle) | _TODO_ | _TODO_ |

---

## See also

- [SECURITY.md](../SECURITY.md) — the privacy model and how to report an issue
- [Auto-update pipeline](AUTO_UPDATE.md) — exactly what the Sparkle check does
- [Comparison](guides/comparison.md) — where audio goes vs. the alternatives
