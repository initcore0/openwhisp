# Security & Privacy

Privacy is OpenWhisp's whole point, so we treat it as a security property.

## The privacy model

- **Transcription is 100% on-device.** Audio is captured locally, written to a
  temporary WAV in `~/Library/Caches/com.openwhisp.app/`, transcribed by
  whisper.cpp on your Mac, and the WAV is **deleted after each transcription**.
- **No telemetry.** OpenWhisp sends no analytics, crash reports, or usage data.
- **The only network egress** is optional AI post-processing **with the OpenAI
  (cloud) provider**. If you use the **local** provider (llama.cpp / Ollama),
  text stays on your machine / LAN. If AI post-processing is off, nothing leaves
  the device at all. The Settings → Status panel shows the current state.
- **Secrets** (the OpenAI API key) are stored in the macOS **Keychain**, never in
  plain text.
- **Secure fields** (password fields) are detected and OpenWhisp refuses to
  dictate into, insert, or store their contents.

### Verify it yourself
Because OpenWhisp is open source you don't have to take our word for it:

```bash
# Watch for any network activity by OpenWhisp while you dictate (should be silent
# unless you enabled the OpenAI cloud provider):
nettop -p "$(pgrep -x OpenWhisp)"
```

You can also read the relevant code: audio capture (`OpenWhisp/Services/AudioRecorder.swift`),
the WAV deletion and HTTP calls (`OpenWhisp/Services/WhisperEngine.swift`), and
the only outbound endpoint (`OpenWhisp/Services/OpenAITranslationService.swift`).

## Reporting a vulnerability

If you find a security or privacy issue (e.g. a path where audio/text could leak
off-device unexpectedly), please **do not open a public issue**. Instead, report
it privately via GitHub's **"Report a vulnerability"** (Security → Advisories) on
the repository, or open a minimal private channel with the maintainer.

Please include: macOS version, OpenWhisp version, the engine/provider in use, and
clear reproduction steps. We aim to acknowledge reports promptly.

## Supported versions

OpenWhisp is pre-1.0; security fixes target the latest `main` / latest release.
