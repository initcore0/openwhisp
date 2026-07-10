#!/bin/bash
# OpenWhisp — Refine Last Result (Raycast Script Command)
#
# @raycast.schemaVersion 1
# @raycast.title Refine Last Result
# @raycast.mode silent
# @raycast.packageName OpenWhisp
# @raycast.icon ✨
# @raycast.description Rewrite OpenWhisp's last result with the on-device AI; result goes to the clipboard.
#
# @raycast.argument1 { "type": "text", "placeholder": "instruction (e.g. make it formal)" }
#
# Drives the openwhisp:// URL scheme. The instruction is URL-encoded so spaces and
# punctuation survive. OpenWhisp must be running with an LLM configured.
instruction="$1"

# Percent-encode the instruction (RFC 3986) via python3, which ships with macOS.
encoded=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$instruction")

open "openwhisp://refine?instruction=${encoded}"
