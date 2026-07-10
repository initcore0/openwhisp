#!/bin/bash
# OpenWhisp — Paste Last Result (Raycast Script Command)
#
# @raycast.schemaVersion 1
# @raycast.title Paste Last Result
# @raycast.mode silent
# @raycast.packageName OpenWhisp
# @raycast.icon 📋
# @raycast.description Paste OpenWhisp's last dictation/refine result into the focused app.
#
# Drives the openwhisp:// URL scheme. OpenWhisp must be running.
open "openwhisp://paste-last-result"
