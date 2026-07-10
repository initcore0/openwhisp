# OpenWhisp — Alfred recipe

A minimal Alfred recipe over the `openwhisp://` URL scheme. Works with the free
Alfred (no Powerpack needed for the keyword→`open` path; the argument-passing
`refine` keyword needs Powerpack's Workflows).

## The one-liner (no workflow needed)

Alfred can run a shell command from a **Universal Action** or a **Workflow "Run
Script"** action. The whole recipe is just:

```sh
open "openwhisp://record"                       # start / toggle dictation
open "openwhisp://paste-last-result"            # paste the last result
open "openwhisp://switch-mode?key=email&record" # (coming soon) switch mode, then record
```

## Recommended: three keyword triggers (Powerpack)

Create a blank workflow (**Alfred Preferences → Workflows → + → Blank Workflow**),
then add these objects:

1. **Keyword `dictate`** (no argument) → **Run Script** action:
   ```sh
   open "openwhisp://record"
   ```

2. **Keyword `owpaste`** (no argument) → **Run Script** action:
   ```sh
   open "openwhisp://paste-last-result"
   ```

3. **Keyword `refine`** (argument required, "with space") → **Run Script**
   action (Language `/bin/bash`, input as `{query}`):
   ```sh
   encoded=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1")
   open "openwhisp://refine?instruction=${encoded}"
   ```
   Then type `refine make it formal` in Alfred to rewrite the last result.

## URL grammar

See [`../README.md`](../README.md) for the full grammar, the verb allow-list, and
which verbs are live vs. coming soon. OpenWhisp must be running for any of these to
do anything (they hand a URL to the app; if it's not running, macOS launches it and
delivers the URL on start).
