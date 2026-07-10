#!/bin/bash
# OpenWhisp — Start / Toggle Dictation (Raycast Script Command)
#
# @raycast.schemaVersion 1
# @raycast.title Start Dictation
# @raycast.mode silent
# @raycast.packageName OpenWhisp
# @raycast.icon 🎙️
# @raycast.description Start (or stop) OpenWhisp dictation — same as the hotkey.
#
# Drives the openwhisp:// URL scheme. OpenWhisp must be running.
open "openwhisp://record"
