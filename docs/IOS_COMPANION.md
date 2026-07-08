# OpenWhisp → iPhone Companion (Dictation Keyboard + Sync + MCP)

> A feasibility study and design for an iPhone companion to the OpenWhisp macOS
> app: a custom **dictation keyboard** backed by on-device Whisper, that stays
> true to OpenWhisp's philosophy — **fully local, no subscription, no tracking,
> no third parties** — and **syncs** with the Mac (vocabulary, history, prompts,
> per-app modes) and participates in **MCP** so agents can dictate through the
> phone too.
>
> **Bottom line first:** This is buildable and a strong strategic fit, but the
> iOS platform imposes one hard architectural constraint that shapes everything:
> **a custom keyboard extension cannot use the microphone — even with Full Access
> granted.** So Whisper capture + transcription must live in the **host app**, and
> the **keyboard is a thin client** that inserts finished text from a shared App
> Group container. Everything below follows from that.

All load-bearing platform claims here were fact-checked (2026-07-08 deep-research
run, 24/25 claims confirmed 3-0 against primary Apple sources; 1 refuted). A
same-day PR-review pass added three more verified constraints ([C9]–[C11]) that
reshape the capture-trigger UX (§2) and the risk plan (§8). Cited inline; sources
listed at the end.

---

## 1. Why this fits OpenWhisp

The pitch writes itself and it's on-brand ([[product-positioning]]):

> **"Your Mac's dictation, now in your pocket — same private engine, no cloud,
> no subscription, no keylogger keyboard."**

Third-party iOS keyboards are notorious for demanding "Full Access" and shipping
your keystrokes to a server for "prediction." OpenWhisp's angle #1 ("never phones
home") is *exactly* the reassurance that market is starving for. A keyboard that
transcribes **on-device with Whisper** and whose network use is **only** an
opt-in LAN link to your own Mac is a genuinely differentiated, trustworthy
product in a category defined by distrust.

It also extends all three strategic angles to a second device:
1. **Never phones home** — on-device WhisperKit on the phone; sync is peer-to-peer to *your* Mac.
2. **Pay once, own it** — no subscription on either device.
3. **Power user's kit** — same vocabulary, prompt packs, per-app modes, and MCP, now on iOS.

---

## 2. The one hard constraint (and the architecture it forces)

**iOS custom keyboard extensions have no microphone access — full stop, even with
Full Access enabled.** Apple's own docs: *"Custom keyboards… have no access to the
device microphone, so dictation input is not possible."* This is not legacy
lore — a Dec-2023 developer hit the runtime sandbox error with `RequestsOpenAccess`
**on**: *"was NOT allowed to start recording because it is an extension and
doesn't have entitlements to record audio."* Confirmed in force through iOS 18/26.
[C1]

Consequences, all confirmed:
- The keyboard **cannot** run Whisper on live mic audio. Capture + transcription
  **must** run in the containing **host app**.
- The keyboard talks to text only through `UITextDocumentProxy`: `insertText()`,
  `deleteBackward()`, `hasText`, and context readers
  (`documentContextBeforeInput`, `adjustTextPositionByCharacterOffset`). It
  **cannot select text** — selection belongs to the host app. So "dictate and
  insert" works cleanly; "select this phrase and replace it" cannot be driven
  from the keyboard. [C3]
- The keyboard and host app share data **only** via an **App Group** container,
  and that (plus network) is unlocked **only** by `RequestsOpenAccess` = Full
  Access. By default a keyboard has neither. [C2]

### The forced design: thin keyboard + host engine

```
┌─────────────────────────── iPhone ───────────────────────────┐
│                                                               │
│   Keyboard Extension            Host App (OpenWhisp iOS)      │
│   (thin, ~memory-tight)         (the real engine)            │
│   ┌───────────────────┐         ┌──────────────────────────┐ │
│   │ mic button ───────┼────────▶│ AVAudioEngine capture    │ │
│   │ (deep-links /      │ trigger │ WhisperKit (CoreML/ANE)  │ │
│   │  wakes host)       │         │ SmartFormatter, Vocab,   │ │
│   │                    │         │ VoiceCommandParser (Core)│ │
│   │ inserts text ◀─────┼─────────┤ writes transcript →      │ │
│   │ via UITextProxy    │ App     │   App Group container    │ │
│   └───────────────────┘  Group  └──────────────────────────┘ │
│            ▲  reads finished transcript from shared container  │
└────────────┼──────────────────────────────────────────────────┘
             │  (Full Access required for App Group + network)
```

**The keyboard never touches the mic or the model.** It shows a mic button,
triggers the host app to capture+transcribe, and — the instant the host writes a
finished transcript into the App Group container — inserts it at the caret. All
the heavy, memory-hungry work (WhisperKit) is in the host app, which has a normal
foreground memory budget, not the punishing extension jetsam limit.

> **Memory note (open question, measure don't guess):** the exact custom-keyboard
> jetsam ceiling isn't officially documented; community reports cluster around
> ~30–60 MB and it has tightened over iOS versions. A Whisper CoreML model
> (even `tiny`/`base`) would not reliably fit *inside the extension* regardless —
> but we don't need it to, because the model lives in the host app. What we
> **must** measure empirically is peak WhisperKit memory *in the host app* on
> low-RAM iPhones. [C1, caveat]

### The UX problem this creates (and how to solve it)

Because the mic is in the host app, tapping the keyboard's mic button can't just
silently record — the **host app must become active to capture**. And two more
platform walls stand between "tap mic key" and "host records", both verified:

- **A keyboard extension has no supported way to open its containing app.**
  `extensionContext.open(_:)` is documented to work **only from Today widgets**;
  Apple's QA1924 explicitly calls the responder-chain `openURL:` workaround "not
  allowed." Keyboards that do this ship on an unsupported hack that Apple has
  broken before and can break/reject again. [C9]
- **An app cannot *start* mic capture from the background.** The audio background
  mode only lets a *foreground-started* session continue; attempts to activate a
  recording session from the background fail (the system denies recording-start
  to backgrounded processes). So even if the keyboard could wake the host, a
  backgrounded host still couldn't begin recording. [C10]
- Corollary: a Live Activity can't paper over this — Live Activities are started
  by the foreground app (or an ActivityKit push), not by an extension.

There *is* one sanctioned crack in the wall: **`AudioRecordingIntent` (iOS 18+)**,
the App Intent Apple added precisely so recording can start from the **Action
button or a Control Center control** without foregrounding the app (this is how
modern voice-memo apps do it), surfaced with a Live Activity while recording.
A keyboard extension cannot invoke it — but the user's finger can. [C11]

Options, best-first:

1. **Action button / Control Center capture + Live Activity (hero, iOS 18+).**
   User triggers OpenWhisp's `AudioRecordingIntent` from the Action button or a
   Control Center control; the host records without an app switch, Dynamic Island
   shows "listening…"; on stop (silence auto-stop, reusing our
   `SilenceAutoStop.swift`) the host writes the transcript to the App Group and
   the keyboard inserts it at the caret. Honest trade-off: the trigger lives on
   the Action button/Control Center, **not on the keyboard's mic key** — the mic
   key becomes a teaching affordance ("set up the Action button") plus the
   fallback below. Real-device validation of intent-initiated capture is still
   **the #1 prototype risk to burn down first** — reports exist of background
   errors when the intent fires from some surfaces. [C10, C11]
2. **Quick app-switch (the floor).** Keyboard mic key sends the user to the host
   app's compact "dictation sheet"; user speaks; user returns via the status-bar
   back-breadcrumb (there is **no API for the host to programmatically return** to
   the previous app) and the keyboard, on reappearing, inserts the pending
   transcript from the App Group. Caveat inside the caveat: because of [C9] even
   this "tap to switch" needs either the unsupported openURL hack or a UX that
   asks the user to switch apps themselves — prototype both and decide with eyes
   open. Less seamless, but App-Store-safe in its manual form.
3. **"Dictate here" in-app.** Inside the OpenWhisp host app itself, dictation is
   trivial (normal app mic access) — good for composing longer notes to copy out.

Ship **(2) as the floor** (always works, easy review), pursue **(1)** as the hero
experience. This staging also satisfies review guideline 4.4.1 (below): the
keyboard must **remain functional without Full Access** — as a plain keyboard —
and dictation is an *enhancement*, not a precondition for typing. [C8]

---

## 3. What we reuse for free (the `OpenWhispCore` dividend)

We already paid the platform-agnostic-core tax for the Windows study
([[phase-2.5-progress]], docs/WINDOWS_PORT.md). That investment pays off *harder*
on iOS than on Windows, because iOS **is** an Apple platform — SwiftUI, WhisperKit,
and the Swift toolchain all carry over. Unlike Windows (no SwiftUI, CoreAudio→WASAPI
rewrite), iOS reuses the UI *framework* and the *engine*, not just the logic.

| Layer | Status on iOS | Notes |
|---|---|---|
| **`OpenWhispCore`** (Foundation-only: SmartFormatter, Vocabulary, VoiceCommandParser, MetaInstructionStripper, PostProcessor, AppProfile, TranscriptionHistory, ConfigBundle/Pack, SecureFieldPolicy, PrivacyStatus, TranscriptCleaner, SilenceAutoStop, DictationSession, InstructionChain, RefineFlow…) | **Reuse as-is** | Already compiles for any Apple platform. This is the whole formatting/vocab/voice-command/history/profile brain. |
| **WhisperKit engine** (`WhisperKitBridge`, `WhisperKitStreamingEngine`, `WhisperKitModelCatalog`) | **Reuse, retune** | WhisperKit is iOS-native (that's its origin). Model choice shifts smaller (`tiny`/`base`/`small`) for phone RAM/thermals. The macOS-26 GPU-encoder gotcha ([[whisperkit-backend]]) is a Mac quirk; re-benchmark ANE on iPhone. |
| **Agent Bridge wire** (`BridgeWire`, `BridgeRouter`, `AgentClientStore`, `AgentRateLimiter`, `DictationSession`) | **Reuse as-is** | Foundation-only NDJSON JSON-RPC control plane. This *is* our sync + MCP substrate (§5, §6). |
| **Audio capture** | **Rewrite (small)** | Mac uses CoreAudio device enumeration + `AVAudioEngine`. iPhone has one route model; `AVAudioEngine` capture + our VAD/RMS math (already portable) carries the logic. Much smaller job than the Windows WASAPI rewrite. |
| **Text insertion** | **Rewrite (different model)** | Mac = Accessibility (`AXUIElement`) into arbitrary apps. iOS = `UITextDocumentProxy` from the keyboard. Simpler surface, but insert/delete-only, no selection. [C3] |
| **App shell / UI** | **New (SwiftUI)** | New host app + keyboard extension. But SwiftUI knowledge and many views' logic transfer; no framework switch (contrast Windows). |
| **Hotkey / menu bar / launch-at-login** | **Drop / re-conceive** | No global hotkey or menu bar on iOS. The "hold to talk" gesture becomes the keyboard mic button + Live Activity. |

**Reuse estimate:** meaningfully higher than the Windows study's ~40%. The pure
core (~40% of logic) reuses *plus* the entire WhisperKit engine and the Agent
Bridge wire, because those are Apple-platform Swift, not Mac-only. Rough split:
**~55–60% reusable (core + engine + wire), ~30% new SwiftUI UI + keyboard
extension, ~10% audio/insertion adapters.**

---

## 4. Product surface — what the iPhone app *is*

Two targets in one app, plus optional widgets:

1. **OpenWhisp (host app).** The engine + settings + history browser + the
   in-app dictation composer. Owns WhisperKit, the mic, the App Group, sync, and
   the MCP client. This is where privacy toggles, model download, vocabulary,
   prompt packs, and per-app modes live — mirroring the Mac settings.
2. **OpenWhisp Keyboard (extension).** A **real, usable keyboard** (so it passes
   4.4.1's "functional without Full Access" bar) with one extra affordance: a mic
   key that fires the host-app dictation flow and inserts the result. Optionally a
   "refine" key mirroring the Mac's refine-selection gesture — subject to the
   selection limitation (it can refine the *last dictation*, not an arbitrary host
   selection). [C3, C8]
3. **Live Activity / Dynamic Island** for the "listening…" state during capture.

Feature parity worth carrying over from the Mac (all core-backed, so cheap):
smart formatting (default-on), custom vocabulary + substitutions, spoken
punctuation, voice commands, transcription history, per-app modes (caveat: a
keyboard extension has **no supported API to identify its host app**, so iOS
"per-app" modes likely degrade to a user-picked mode on the keyboard or
text-content heuristics), and the local-LLM refine step.

---

## 5. Sync — local-first, no third parties

Goal: vocabulary, history, prompt packs, per-app modes, and settings stay
consistent between Mac and iPhone **without any server we don't own, and ideally
without any server at all.** Our `ConfigBundle`/`ConfigPack` types already define
a portable JSON export format ([[phase-3-progress]]) — sync moves *that* payload.

Three tiers, in order of philosophical purity:

### Tier A — Peer-to-peer over the local network (recommended default)
Apple's **Network framework** (`NWListener` advertises, `NWBrowser` discovers,
`NWConnection` connects) over **Bonjour** supports a fully peer-to-peer link with
**no external server at all** — confirmed by Apple DTS as a supported "star"
topology where each device runs both listener and browser. No special entitlement
for Bonjour discovery; it does require declaring the `_openwhisp._tcp` service in
`NSBonjourServices` and an `NSLocalNetworkUsageDescription`, which triggers the
iOS 14+ Local Network consent prompt. [C4]

This is the truest to "no third parties": your Mac and phone talk **directly** on
your Wi-Fi, encrypted (TLS via `NWProtocolTLS`), authenticated by a shared
key/QR-pairing. **This is literally the same shape as the Agent Bridge** — a local
JSON-RPC control plane — just over TLS-TCP instead of a UNIX socket. We can reuse
`BridgeWire`/`BridgeRouter` almost verbatim and add sync verbs
(`sync.push`/`sync.pull`/`sync.manifest`).

- **Pro:** zero cloud, zero account, direct, fast, on-brand.
- **Con:** both devices must be on the same LAN at sync time (fine for a
  companion; sync is not real-time-critical). Backgrounded/locked-phone
  advertising is subject to the same suspension limits as MCP hosting (§6) — so
  sync is a **foreground, on-demand or on-launch** operation, not a silent
  daemon. That's acceptable for config/history sync.

### Tier B — CloudKit private database (optional convenience, defensible)
For users who want off-LAN sync (phone syncs history from anywhere), **CloudKit's
private database** is the *Apple-but-arguably-not-a-third-party* option: it's the
user's own iCloud, **invisible to us as developers** (*"Data in the private
database isn't visible in the developer portal"*), and for E2EE-designated
categories the keys *"are never made available to Apple servers."* [C5]

**Honest caveat (must be in the UI, not buried):** CloudKit is still Apple's
cloud. Standard CloudKit is *not* end-to-end encrypted by default — full
zero-Apple-access requires an E2EE-designated category or the user having
**Advanced Data Protection** on. So "no third parties" is defensible for CloudKit
(it's *your* iCloud, not our server, and we can't see it), but "nothing leaves
your devices" is **only** true for Tier A. We should say exactly that. [C5, caveat]

### Tier C — Self-hosted / file-based
Manual `ConfigBundle` JSON export/import (AirDrop, Files, a git repo) — already
supported by the core. The zero-magic escape hatch for the maximalist.

**Recommendation:** ship **Tier A (P2P) as the default and the headline**, offer
**Tier C** free (it already exists), and treat **Tier B (CloudKit)** as an
explicitly-labeled opt-in for convenience with the honest caveat shown. Default
posture stays "nothing leaves your devices."

---

## 6. MCP on the phone

**What's confirmed:** an iOS app can participate in MCP natively via the official
**MCP Swift SDK (iOS 16+)** as a **client** (`Client.connect`) and even embed
server logic. Among the two *standard* transports, only **Streamable HTTP** is
viable — iOS sandboxed apps **cannot spawn subprocesses**, so stdio is out.
(Custom in-process transports also exist, so "HTTP only" is precise just for the
standard transports.) [C6]

**What's not viable:** the phone as an **always-on MCP *host*.** Streamable HTTP
needs an independent always-listening process, and iOS backgrounding kills that:
~5 s to enter background, a variable (~30 s, *not guaranteed*) `beginBackgroundTask`
grant, and **termination on overrun**. A phone cannot reliably keep an MCP server
socket open in the background. [C7]

So the phone's MCP role, from most to least practical:

1. **Phone as MCP client → Mac as MCP host (recommended).** The Mac already runs
   the Agent Bridge MCP server (`openwhisp mcp`, [[ai-native-feature-research]],
   docs/AGENT_BRIDGE.md). Expose it on the LAN (TLS + the Agent Bridge's existing
   3-layer auth + per-capability consent) and the **phone connects as a client** —
   letting the phone drive `openwhisp_dictate` / `openwhisp_refine` /
   `openwhisp_history` on the Mac, or letting a **phone-side agent app** reach the
   Mac's tools. This reuses the entire bridge security model (scoped consent,
   cloud-refine gate, signed clients) with the socket swapped for a paired TLS
   connection.
2. **Foreground-only phone MCP server.** While the OpenWhisp app is *open*, it can
   host a Streamable-HTTP MCP server exposing the phone's on-device dictate/refine
   to an agent on the same LAN (e.g. a Mac agent that wants the phone's mic). Works,
   but only while foregrounded — a "hold the app open to lend your phone's mic to
   an agent" mode, not a daemon. [C6, C7]
3. **Phone as an agent-dictation *target* via the Mac.** An agent asks a question;
   the Mac's bridge can surface it and the human answers **by voice on the phone**,
   routed back through the paired link. This is the mobile analog of the
   agent-waiting overlay work ([[agent-waiting-ux]]).

**Bottom line:** the phone is an MCP **client and an occasional foreground
server**, and the **Mac stays the always-on MCP hub**. That's the correct division
of labor given iOS backgrounding — and it means the phone gets "all the features
including MCP" (the user's ask) without pretending iOS can host a daemon it can't.

---

## 7. App Store review constraints

**Guideline 4.4.1 (keyboard extensions) is the controlling rule**, and our design
already aligns — but two clauses are mandatory: [C8]

1. *"Remain functional without full network access and without requiring full
   access."* → The keyboard **must** work as a plain keyboard with Full Access
   **off**. Dictation is an enhancement that lights up when Full Access is granted
   (needed for the App Group hand-off + LAN). **Do not gate basic typing on Full
   Access.** Our staged plan (real keyboard first, dictation as add-on) satisfies
   this by construction.
2. *"Collect user activity only to enhance the functionality of the user's keyboard
   extension on the iOS device."* → We collect **nothing** and send **nothing**
   off-device except the opt-in LAN link to the user's own Mac. This is a *stronger*
   privacy posture than the guideline demands — lean into it in the review notes
   and the privacy nutrition label.

Other review realities:
- **Full Access will draw scrutiny.** Third-party keyboards with Full Access are
  reviewed carefully because it's the flag abused by keyloggers. Our defense is
  radical transparency: an on-device-only privacy label, a plain-language "here's
  exactly what Full Access does and doesn't do" screen, open-source code, and no
  analytics SDKs. Full Access is *permitted* for a Whisper keyboard; it just must
  not be *required* for typing and must not exfiltrate. [C8]
- **Replacing dictation is allowed** — third-party keyboards are a first-class
  extension point; there's no rule against offering your own dictation button. The
  constraint is the *mechanism* (mic-in-host-app), not permission to compete with
  Apple dictation.
- **Local Network prompt** (Tier A sync / LAN MCP) needs a clear
  `NSLocalNetworkUsageDescription`; expect the consent dialog. [C4]

---

## 8. Effort, risk, and a staged plan

**Risk-burndown first — validate the two things that can kill the hero UX
(decomposed, because they fail independently):**

- **R0a: capture-start without foregrounding.** Prove `AudioRecordingIntent`
  (Action button / Control Center) reliably starts host-app capture on a real
  device with the app backgrounded or not running, with a Live Activity showing
  state. Known reports of background-start errors from some trigger surfaces make
  this genuinely uncertain. [C10, C11] If it fails, the hero UX degrades to
  app-switch — shippable, but we must know before committing to the hero framing.
- **R0b: keyboard→host trigger.** Measure how bad the sanctioned path is (user
  switches apps / taps the back-breadcrumb) vs. the unsupported responder-chain
  openURL hack [C9] — and whether the hack survives current iOS + App Review.
  Decide the mic key's real behavior from data, not hope.
- **R0c: the return-trip insert.** Verify the keyboard reliably learns of and
  inserts a pending transcript when it reappears (App Group read on
  `viewWillAppear` + Darwin notification while alive) across the app-switch
  round-trip.

*R0a is the highest-uncertainty item in the whole plan.*

**Then, incremental milestones (each shippable/testable):**

| # | Milestone | Reuses | New work |
|---|---|---|---|
| iM0 | **Host app skeleton + WhisperKit on iPhone.** In-app "dictate & copy". Benchmark `tiny`/`base`/`small` peak memory + latency + thermals on real devices. | `OpenWhispCore`, WhisperKit engine | SwiftUI host app, iOS audio capture adapter |
| iM1 | **Real keyboard extension** (no dictation yet) — passes 4.4.1 as a plain keyboard. | — | Keyboard UI, `UITextDocumentProxy` insertion |
| iM2 | **Dictation hand-off** — App Group container, capture → transcript → keyboard insert on reappear (Darwin notification + `viewWillAppear` read). Ship app-switch fallback; layer `AudioRecordingIntent` + Live Activity if R0a proved it. | SmartFormatter, Vocabulary, SilenceAutoStop | App Group plumbing, App Intent, Live Activity |
| iM3 | **Local-first sync (Tier A P2P)** of vocab/history/packs/profiles via Network framework, reusing the bridge wire. | `ConfigBundle/Pack`, `BridgeWire/Router` | `NWListener`/`NWBrowser`, QR pairing, TLS |
| iM4 | **MCP client → Mac hub** over the paired link; phone drives Mac dictate/refine/history; optional voice-answer-to-agent. | Agent Bridge auth + consent model, MCP SDK | TLS transport for the bridge, phone MCP UI |
| iM5 | **Polish** — per-app modes, refine key (last-dictation), CloudKit opt-in (Tier B) with the honest caveat, prompt packs. | core profiles/refine | CloudKit schema, settings parity |

**Overall effort:** **L–XL** for a small OSS project, but front-loaded risk is
narrow (R0), and reuse is high. The economics are *far* better than the Windows
port: same language, same UI framework, the engine and the core and the bridge
wire all carry over. The genuinely new surface is the keyboard extension + iOS
audio adapter + the P2P transport — bounded, well-understood work.

---

## 9. Recommendation

**Build it, in this order, and be honest about the constraint.**

1. **Accept the thin-keyboard/host-engine architecture** — it's not a compromise,
   it's the only correct design, and it *keeps the model and mic in the host app*
   where privacy and memory are easiest to reason about.
2. **Prototype R0a/R0b immediately** (`AudioRecordingIntent` capture-start;
   keyboard→host trigger). They're the only things that can change the product's
   shape — and note the hero trigger is the **Action button / Control Center**,
   not the keyboard's mic key, because a keyboard cannot wake its host app and a
   backgrounded host cannot start recording. [C9, C10, C11]
3. **Ship the on-device keyboard first**, with dictation as the Full-Access-gated
   enhancement, so review is clean and the privacy story is airtight.
4. **Make Tier A P2P sync the headline** ("nothing leaves your devices"), CloudKit
   an honestly-captioned opt-in, file export the free escape hatch.
5. **Let the Mac stay the MCP hub; the phone is a client** (+ foreground server).
   That gives users "all the features including MCP" without faking an iOS daemon.

This is the rare feature that is simultaneously a great product, a natural
extension of the existing codebase, and a pure expression of the project's
values — a private keyboard in a category built on distrust.

---

## Open questions to resolve during R0/iM0 (measure, don't assume)

1. Peak WhisperKit memory (`tiny`/`base`/`small`) in the **host app** on low-RAM
   iPhones — does even the host risk jetsam during transcription? [caveat]
2. Does `AudioRecordingIntent` reliably start capture with the host backgrounded
   / not running, from Action button *and* Control Center? (Defines the hero vs.
   fallback UX — R0a.) [C11, openQ]
2a. Does the responder-chain openURL hack still work on current iOS, and does it
   pass review? (Defines the mic key's behavior — R0b.) [C9, openQ]
3. How does the Tier-A Bonjour peer behave when the phone locks/backgrounds — is
   sync strictly foreground/on-launch? (Expected: yes.) [openQ]
4. Exactly what must the mandatory "functional without Full Access" degraded mode
   look like to satisfy 4.4.1, given dictation needs the App Group? [openQ]

---

## Sources (fact-checked, 2026-07-08)

- **[C1]** No mic in keyboard extensions, even with Full Access → host-app engine:
  Apple *App Extension Programming Guide — Custom Keyboard*; *Handling text
  interactions in custom keyboards*; Apple Developer Forums thread/742601 (runtime
  sandbox error with open access on). Confirmed 3-0.
- **[C2]** `RequestsOpenAccess` = the single flag for shared App Group container +
  network: Apple *Custom Keyboard* guide; *Configuring open access for a custom
  keyboard*; `RequestsOpenAccess` reference. Confirmed 3-0.
- **[C3]** `UITextDocumentProxy` insert/delete-only, no selection: Apple *Custom
  Keyboard* guide; *Handling text interactions*; `UIKeyInput`. Confirmed 3-0.
- **[C4]** P2P LAN sync with no server via Network framework/Bonjour; Local Network
  consent required: Apple Developer news 0oi77447; Apple Forums thread/780379.
  Confirmed 3-0.
- **[C5]** CloudKit private DB is developer-invisible; E2EE only for designated
  categories / with Advanced Data Protection: Apple *CKContainer privateCloudDatabase*;
  *Apple Platform Security — iCloud encryption*; support/102651. Core 3-0
  (developer-invisibility 2-1).
- **[C6]** iOS MCP via Swift SDK (iOS 16+), client + embeddable; Streamable HTTP
  only among standard transports (no subprocess stdio): modelcontextprotocol/swift-sdk;
  MCP transports spec (2025-03-26); Apple Forums thread/747499. SDK/platform 3-0.
- **[C7]** Phone can't host an always-on MCP server (backgrounding: ~5 s to suspend,
  variable ~30 s grant, terminate on overrun): MCP transports spec; Apple *Extending
  your app's background execution time*. Confirmed 3-0.
- **[C8]** Guideline 4.4.1: keyboard must remain functional without Full Access;
  data collection limited to on-device keyboard enhancement: Apple *App Review
  Guidelines*. Full-access clause 3-0.
- **[C9]** Keyboard extensions cannot open their containing app:
  `extensionContext.open(_:)` is supported **only in Today widgets**; Apple QA1924
  (*Opening Keyboard Settings from a Keyboard Extension*) states the
  responder-chain `openURL:` workaround "is not allowed"; Apple Forums
  thread/65621. *(Added 2026-07-08 PR review pass.)*
- **[C10]** Apps cannot *start* mic capture from the background: background audio
  mode only continues foreground-started sessions; recording-session activation
  from background is denied by the system (Apple Forums thread/120038,
  thread/756507 — "client … in the background doesn't have the entitlement to
  start recording"). *(Added 2026-07-08 PR review pass.)*
- **[C11]** `AudioRecordingIntent` (App Intents, iOS 18+) is the sanctioned way to
  start/stop recording from the Action button / Control Center without
  foregrounding the app: Apple Developer Documentation *AudioRecordingIntent*;
  community reports of background-start errors from some trigger surfaces
  (hackingwithswift.com forums thread 29100) — hence R0a. *(Added 2026-07-08 PR
  review pass.)*

*Related: [[product-positioning]], [[roadmap]], [[phase-2.5-progress]],
[[phase-3-progress]], [[ai-native-feature-research]], [[agent-bridge-followups]],
[[whisperkit-backend]], [[agent-waiting-ux]]. See also docs/WINDOWS_PORT.md
(the platform-agnostic-core precedent) and docs/AGENT_BRIDGE.md.*
