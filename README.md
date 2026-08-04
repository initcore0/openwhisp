# OpenWhisp

**Talk to your Mac. And to your AI agents.**
Realtime dictation that runs entirely on your device — free, open source, no account, no subscription.

[![Download](https://img.shields.io/badge/Download-OpenWhisp.dmg-blue?style=for-the-badge)](../../releases/latest)
[![License](https://img.shields.io/badge/license-MIT-green?style=for-the-badge)](LICENSE)

**[openwhisp.app](https://openwhisp.app)** · macOS 15+ · Apple Silicon · signed & notarized

<!-- HERO GIF PLACEHOLDER (MAK-26): streaming demo — words appearing ~0.3s behind
     the voice, punctuated, on-device. Drop the recorded GIF in docs/assets/ and
     replace this comment with the image, e.g.:
     ![OpenWhisp streaming dictation](docs/assets/hero-streaming.gif) -->

> **Words appear ~0.3s behind your voice** — punctuated, on-device, free.
> **And it's voice for your coding agent, fully local:** works where Claude Code's `/voice` doesn't — API keys, Bedrock, over SSH, HIPAA, Cursor, any MCP client.

---

## Hold a key. Speak. Your words are there.

Words appear **as you talk** — about a third of a second behind your voice, already punctuated and capitalized. Release the key and the finished text lands in whatever app you're using. Mail, Slack, your terminal, anywhere.

Nothing is uploaded. Nothing is logged. There's no account to make.

---

## What makes it different

### 🎙️ Your voice, for your AI agents

This is the part no other dictation app does.

OpenWhisp exposes itself as a **local MCP server**, so Claude Code, Cursor, and any MCP-aware agent can use your voice — while every word stays on your Mac.

| | |
|---|---|
| **Speak to your agent** | Talk instead of typing your prompts. |
| **Your agent asks, you answer out loud** | It hits a decision point, opens the voice overlay, asks a question — you just answer. It's a conversation, not a prompt box. |
| **Rewrite with your on-device AI** | Agents can clean up or reformat text using your local model. |
| **Recall what you said** | Agents can read your recent dictations. |

```sh
openwhisp setup claude-code    # or: cursor, hermes, openclaw
```

It's **off until you turn it on**, talks over a private socket (never a network port), and asks your permission per capability — voice, history, and rewriting are each their own yes.

**Works where built-in voice modes don't:** any API key or Bedrock setup, over SSH, in regulated environments, and in any editor — because it never phones home in the first place.

→ [Agent Bridge & MCP docs](docs/AGENT_BRIDGE.md)

### ⚡ Actually realtime

Powered by **Parakeet**, the default engine: true streaming, ~0.3s behind your voice, punctuation as you go. No spinner when you let go of the key. Multilingual and Whisper engines are a click away when you need them.

### 🔒 Private in a way you can check

Everything runs on-device. Don't take our word for it — watch the network yourself:

```sh
nettop -p "$(pgrep -x OpenWhisp)"   # silence
```

Password fields are detected and skipped. History stays on your machine. The only thing that ever leaves is text you explicitly send to a cloud AI, if you choose to turn that on.

Don't want to trust — want to *check*? The [Privacy Proof](docs/PRIVACY_PROOF.md) page enumerates every network path in the code and ships a `scripts/audit-network.sh` you can run to see the verdict yourself.

### ✍️ It writes like you meant it

Filler words disappear. "New paragraph" becomes one. Your jargon and names are spelled right. Optionally, a small AI model — **running on your Mac** — polishes the result. Say *"make it a Slack message"* mid-sentence and it will.

---

## Install

```sh
brew install --cask initcore0/openwhisp/openwhisp
```

Or grab it directly: **[⬇ Download OpenWhisp.dmg](../../releases/latest)** — drag to Applications, open. That's it.

Signed and notarized by Apple: no scary warnings, no Terminal gymnastics. Updates arrive in-app automatically.

On first launch a short setup walks you through the microphone and accessibility permissions, downloads your engine, and lets you test it. About two minutes.

<details>
<summary>Build from source instead</summary>

```sh
git clone --recursive https://github.com/initcore0/openwhisp.git
cd openwhisp
./scripts/build-whisper.sh     # transcription runtime
./scripts/build-llama.sh       # optional: on-device AI cleanup
./build.sh && ./package.sh     # -> build/OpenWhisp.app
```

Needs Xcode 16+ command-line tools and `cmake`. `swift test` runs the core suite.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the full dev setup.

</details>

---

## Also in the box

Everything below is on-device too, and off unless you want it.

- **Meetings** — record, separate you from them, get a local summary
- **Files** — drop in audio or video, or point it at a folder to watch; exports SRT/VTT
- **Modes** — per-app rules for language, tone, and formatting
- **Automation** — `openwhisp://` URLs for Raycast, Alfred, and Shortcuts; send transcripts to a file, a webhook, or your own script
- **Scratchpad** — a floating note that's always ready for your voice
- **Insights** — your words, speed, and streaks, visible only to you
- **Plugins** — optional add-ons with their own window and voice commands, off until you enable one; the first turns a spoken description into a captioned meme, rendered on your Mac ([docs](docs/PLUGINS.md))

---

## Why OpenWhisp

Local, free, and open source is table stakes now — **Handy** and **VoiceInk** are both there. What sets OpenWhisp apart is the combination no one else ships: **Parakeet streaming that trails your voice by ~0.3s, and a local voice bridge your coding agent can actually use.**

| | Latency | Agent bridge (MCP) | Price | License |
|---|---|---|---|---|
| **OpenWhisp** | **~0.3s streaming, punctuated** | **yes — Claude Code, Cursor, any MCP client** | **free** | **MIT** |
| Wispr Flow / Aqua | cloud round-trip | no | ~$144/yr | closed |
| Superwhisper | file-based | no | ~$250 lifetime | closed |
| VoiceInk | file-based | no | free | open |
| Handy | file-based | no | free | open |

Wispr Flow and Aqua are polished but cloud-based. Superwhisper and MacWhisper are file-first. Apple's built-in dictation stops at plain text. None of them can hand your voice to an agent while keeping every word on your Mac.

---

## Docs

[Agent Bridge & MCP](docs/AGENT_BRIDGE.md) · [Architecture](docs/ARCHITECTURE.md) · [Plugins](docs/PLUGINS.md) · [Settings](docs/SETTINGS.md) · [Engine Benchmarks](docs/BENCHMARKS.md) · [Privacy & Security](SECURITY.md) · [Roadmap](docs/ROADMAP.md) · [Contributing](CONTRIBUTING.md)

Mirror for regions where the main site is blocked: [initcore0.github.io/openwhisp-mirror](https://initcore0.github.io/openwhisp-mirror/)

Built on [FluidAudio/Parakeet](https://github.com/FluidInference/FluidAudio), [WhisperKit](https://github.com/argmaxinc/WhisperKit), [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and [llama.cpp](https://github.com/ggerganov/llama.cpp).

**MIT** — see [LICENSE](LICENSE).
