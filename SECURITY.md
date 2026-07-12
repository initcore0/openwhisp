# Security & Privacy

Privacy is OpenWhisp's whole point, so we treat it as a security property.

## The privacy model

- **Transcription is 100% on-device.** Audio is captured locally, written to a
  temporary WAV in `~/Library/Caches/com.openwhisp.app/`, transcribed by
  whisper.cpp on your Mac, and the WAV is **deleted after each transcription**.
- **No telemetry.** OpenWhisp sends no analytics, crash reports, or usage data.
- **The one network call made by default is the update check.** OpenWhisp uses
  [Sparkle](https://sparkle-project.org) to check for new versions. On a scheduled
  interval (once a day) it fetches a small signed feed (`appcast.xml`) over HTTPS.
  What it sends: **only your app version and macOS version** (standard HTTP
  request headers Sparkle adds). System profiling is **deliberately disabled**
  (`SUEnableSystemProfiling` is not set), so no hardware/usage profile is ever
  sent. No dictation text, audio, or personal data is involved. Updates are
  **EdDSA-signed** — OpenWhisp refuses to install one whose signature doesn't match
  the public key baked into the app — and official builds are additionally
  **Developer ID signed and notarized by Apple**. Turn the check off entirely in
  **Settings → General → Software Update** (then it never contacts the network on
  its own); see [docs/AUTO_UPDATE.md](docs/AUTO_UPDATE.md) for the full pipeline.
- **The only egress of your dictated text** is optional AI post-processing **with
  the OpenAI (cloud) provider**. If you use the **local** provider (llama.cpp /
  Ollama), text stays on your machine / LAN. If AI post-processing is off, no
  text leaves the device. The Settings → Status panel shows the current state.
- **Secrets** (the OpenAI API key) are stored in the macOS **Keychain**, never in
  plain text.
- **Secure fields** (password fields) are detected and OpenWhisp refuses to
  dictate into, insert, or store their contents.

### Verify it yourself
Because OpenWhisp is open source you don't have to take our word for it:

```bash
# Watch for any network activity by OpenWhisp while you dictate. It should be
# silent except for the daily Sparkle update check (and the OpenAI cloud provider
# if you enabled it). Disable Settings → General → Software Update to see zero egress:
nettop -p "$(pgrep -x OpenWhisp)"
```

You can also read the relevant code: audio capture (`OpenWhisp/Services/AudioRecorder.swift`),
the WAV deletion and HTTP calls (`OpenWhisp/Services/WhisperEngine.swift`), the
only outbound text endpoint (`OpenWhisp/Services/OpenAITranslationService.swift`),
and the auto-update wiring (`OpenWhisp/Services/UpdaterManager.swift`,
`OpenWhisp/Services/UpdatePreferences.swift`, and the `SU*` keys in
`OpenWhisp/Info.plist`).

## Reporting a vulnerability

If you find a security or privacy issue (e.g. a path where audio/text could leak
off-device unexpectedly), please **do not open a public issue**. Instead, report
it privately via GitHub's **"Report a vulnerability"** (Security → Advisories) on
the repository, or open a minimal private channel with the maintainer.

Please include: macOS version, OpenWhisp version, the engine/provider in use, and
clear reproduction steps. We aim to acknowledge reports promptly.

## Supported versions

OpenWhisp is pre-1.0; security fixes target the latest `main` / latest release.
