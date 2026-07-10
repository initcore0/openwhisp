# OpenWhisp launcher integrations — the `openwhisp://` URL scheme

OpenWhisp registers an `openwhisp://` URL scheme so any launcher — Raycast, Alfred,
a Shortcuts action, or a plain `open openwhisp://…` in a script — can drive its
control surface without shelling out to the CLI. It reuses the same in-app actions
the hotkey and menu bar already use.

**Requirement:** OpenWhisp must be installed. If it's running, the URL is delivered
immediately; if not, macOS launches it and delivers the URL on start. The scheme
carries no secrets and no arbitrary commands — see *Security* below.

## URL grammar

Two equivalent surfaces. Use whichever your launcher makes easy:

**Single verb as the URL host:**

```
openwhisp://record
openwhisp://paste-last-result
openwhisp://refine?instruction=make%20it%20formal
openwhisp://switch-mode?key=email
openwhisp://activate-mode?key=slack
```

**Chained verbs as query keys** (run in order, all-or-nothing):

```
openwhisp://?switch-mode=email&record        # switch mode, then start recording
openwhisp://?record&paste-last-result
openwhisp://?refine&instruction=tighten
```

Parameter values are percent-encoded (`%20` for a space, etc.). A verb that takes a
parameter can carry it as its own query value (`switch-mode=email`) or as a
following named key (`switch-mode&key=email`).

## The verb allow-list

| Verb | Parameters | Status | What it does |
|------|-----------|--------|--------------|
| `record` | — | **live** | Start (or stop) a dictation — same as the hotkey. |
| `refine` | `instruction` (required), `text` (optional, defaults to last result) | **live** | Rewrite text with the on-device AI; result goes to the clipboard. |
| `paste-last-result` | — | **live** | Paste the last dictation/refine result into the focused app. |
| `switch-mode` | `key` (required) | **live** | Queue a Mode (by key) for your **next dictation** only, then revert. |
| `activate-mode` | `key` (required) | **live** | Set a Mode (by key) as the **sticky active Mode** — no recording. |

All five verbs work today. `switch-mode` / `activate-mode` invoke the first-class
**Modes** registry (MAK-39): a Mode bundles a tone, an AI instruction, and optional
overrides under a stable `key`. `switch-mode?key=email` applies that Mode to just
your next dictation; `activate-mode?key=email` makes it the sticky active Mode until
you change it. The `key` is normalized (lowercased, spaces → hyphens), so
`key=Email%20Reply` and `key=email-reply` address the same Mode. An **unknown key**
is logged as a miss and changes nothing, rather than silently pinning a phantom
mode. Create and name Modes in **Settings › Modes**.

## Security

The scheme is a control surface any local process can drive, so it exposes **only
this fixed allow-list of safe verbs** — never a shell string, a file path to run, or
arbitrary text to execute. Parsing, validation, and the allow-list live in a pure,
unit-tested core type (`OpenWhisp/Services/URLScheme.swift`, tests in
`Tests/OpenWhispCoreTests/URLSchemeTests.swift`), exercised against hostile inputs
(unknown verbs, injection-ish params, path-separator keys, over-long values,
malformed URLs) — all rejected as a whole, with nothing partially executed.
Parameter values are treated as opaque data and length-capped.

## Integrations

- [`raycast/`](raycast/) — Raycast Script Commands (no build step).
- [`alfred/`](alfred/) — an Alfred recipe (keyword triggers over `open`).
