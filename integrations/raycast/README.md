# OpenWhisp — Raycast Script Commands

Thin [Raycast Script Commands](https://github.com/raycast/script-commands) over the
`openwhisp://` URL scheme. No npm build, no extension store — just point Raycast at
the `scripts/` folder.

## Install

1. Open **Raycast → Settings → Extensions → Script Commands → Add Directories**.
2. Add this repo's `integrations/raycast/scripts` folder.
3. The commands appear in Raycast:
   - **Start Dictation** (`openwhisp-record.sh`) — start / stop dictation.
   - **Paste Last Result** (`openwhisp-paste-last.sh`) — paste the last result.
   - **Refine Last Result** (`openwhisp-refine.sh`) — takes an instruction argument;
     the refined text lands on your clipboard.

Bind any of them to a Raycast hotkey for a one-key launcher action.

## Requirements

- OpenWhisp installed (running, or macOS launches it on the URL).
- For **Refine**: an LLM configured in OpenWhisp (Settings → AI). The instruction
  is percent-encoded with `python3` (bundled with macOS).

See [`../README.md`](../README.md) for the full URL grammar and the verb
allow-list (and which verbs are live vs. coming soon).
