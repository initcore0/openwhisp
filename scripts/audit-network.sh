#!/usr/bin/env bash
#
# audit-network.sh — reproducible "Nothing leaves your Mac" network audit.
#
# Watches OpenWhisp's own network activity over a timed window while you dictate,
# then prints a clear verdict listing every destination it talked to and
# classifies each against the KNOWN, HONEST list of things OpenWhisp can legitimately
# contact:
#
#   • Sparkle update check      — github.com appcast (default-on, once/day)
#   • Model downloads           — huggingface.co / *.hf.co / CDNs (first-run only)
#   • OPT-IN cloud refine       — api.openai.com (only if you chose the cloud LLM
#                                 provider AND enabled "Allow agents to use cloud AI")
#   • User-configured sinks     — a webhook URL / openURL rule YOU set up
#
# Anything OUTSIDE that list is flagged as UNEXPECTED — that's the whole point.
# The transcription itself (Parakeet / WhisperKit / whisper.cpp on the Apple
# Neural Engine) never touches the network, so during pure dictation you should
# see silence.
#
# This is an observational tool: it reports what the OS says the process did. It
# does not, and cannot, prove a negative on its own — pair it with Little Snitch
# and the open source (see docs/PRIVACY_PROOF.md). But it makes "watch it yourself"
# a one-command thing anyone can reproduce.
#
# Usage:
#   scripts/audit-network.sh                 # find OpenWhisp by name, watch 60s
#   scripts/audit-network.sh -p 12345        # audit a specific PID
#   scripts/audit-network.sh -d 30           # 30-second window
#   scripts/audit-network.sh -n MyApp        # match a different process name
#
# Exit codes: 0 = ran cleanly (see the verdict for what was seen);
#             1 = could not run (app not found, missing tools, etc.).

set -euo pipefail

PROC_NAME="OpenWhisp"
DURATION=60
PID=""

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--pid)      PID="${2:-}"; shift 2 ;;
    -d|--duration) DURATION="${2:-}"; shift 2 ;;
    -n|--name)     PROC_NAME="${2:-}"; shift 2 ;;
    -h|--help)     usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -lt 1 ]; then
  echo "error: --duration must be a positive integer (seconds)." >&2
  exit 1
fi

# --- locate the process -------------------------------------------------------

if [ -z "$PID" ]; then
  # -x = exact name match; take the first if several.
  PID="$(pgrep -x "$PROC_NAME" 2>/dev/null | head -n1 || true)"
fi

if [ -z "$PID" ]; then
  cat >&2 <<EOF
error: could not find a running "$PROC_NAME" process.

  • Start OpenWhisp (or pass a PID explicitly with -p <pid>).
  • If your app has a different process name, pass it with -n <name>.
  • List candidates:  pgrep -fl -i openwhisp

Nothing to audit — exiting.
EOF
  exit 1
fi

if ! kill -0 "$PID" 2>/dev/null; then
  echo "error: PID $PID is not a live process." >&2
  exit 1
fi

# --- tool availability --------------------------------------------------------

HAVE_NETTOP=0; command -v nettop >/dev/null 2>&1 && HAVE_NETTOP=1
HAVE_LSOF=0;   command -v lsof   >/dev/null 2>&1 && HAVE_LSOF=1

if [ "$HAVE_NETTOP" -eq 0 ] && [ "$HAVE_LSOF" -eq 0 ]; then
  echo "error: neither 'nettop' nor 'lsof' is available; cannot observe the network." >&2
  echo "Both ship with macOS by default — check your PATH." >&2
  exit 1
fi

echo "=============================================================="
echo " OpenWhisp network audit"
echo "=============================================================="
echo " Process : $PROC_NAME (PID $PID)"
echo " Window  : ${DURATION}s"
echo " Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo
echo " >>> DICTATE NOW. Speak, refine, do whatever you want to test."
echo "     (Watching for ${DURATION}s...)"
echo "--------------------------------------------------------------"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/openwhisp-audit.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

RAW="$WORK/raw.txt"
: > "$RAW"

# --- capture with nettop (preferred) ------------------------------------------
# nettop -P -x -J : per-process, machine-readable, chosen columns.
# -l takes a bounded number of 1s samples so the script self-terminates cleanly
# on any macOS version (streaming -l 0 would never stop).
if [ "$HAVE_NETTOP" -eq 1 ]; then
  # -n = numeric (don't resolve to friendly names) so we capture real hosts/IPs.
  # We tolerate nettop exiting non-zero (e.g. permissions) and fall back to lsof.
  nettop -P -n -x -J bytes_in,bytes_out \
         -p "$PID" -l "$DURATION" -s 1 >"$WORK/nettop.txt" 2>"$WORK/nettop.err" || true
  # Pull out lines that carry a remote endpoint (host:port or ip:port), skipping
  # the header and the per-process summary rows.
  grep -Eo '[A-Za-z0-9._-]+:[0-9]+|[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+' \
       "$WORK/nettop.txt" 2>/dev/null \
    | grep -vE '^(127\.0\.0\.1|::1|localhost)' \
    | sort -u >> "$RAW" || true
fi

# --- also snapshot established sockets with lsof throughout the window --------
# nettop's sampling can miss a short-lived connection; lsof snapshots catch open
# sockets. We poll a few times across the window.
if [ "$HAVE_LSOF" -eq 1 ]; then
  polls=$(( DURATION / 5 )); [ "$polls" -lt 1 ] && polls=1
  i=0
  while [ "$i" -lt "$polls" ]; do
    lsof -nP -p "$PID" -i 2>/dev/null \
      | awk 'NR>1 && $0 ~ /->/ { for (j=1;j<=NF;j++) if ($j ~ /->/) print $j }' \
      | sed 's/.*->//' \
      | grep -vE '^(127\.0\.0\.1|\[::1\]|localhost)' \
      | sort -u >> "$RAW" || true
    i=$(( i + 1 ))
    [ "$i" -lt "$polls" ] && sleep 5
  done
else
  # nettop-only path: if nettop returned instantly (e.g. it errored), still
  # consume the window. nettop -l blocks for DURATION on success.
  [ -s "$WORK/nettop.txt" ] || sleep "$DURATION"
fi

# --- classify -----------------------------------------------------------------

DEST="$WORK/dests.txt"
sort -u "$RAW" > "$DEST" 2>/dev/null || : > "$DEST"

classify() {
  # $1 = "host:port" or "ip:port"; echo a category tag.
  local host="${1%:*}"
  case "$host" in
    *github.com|*githubusercontent.com|*.github.io)
      echo "SPARKLE-UPDATE (appcast / release download — default-on, ~once/day)" ;;
    *huggingface.co|*.hf.co|cdn-lfs*|*.cloudfront.net)
      echo "MODEL-DOWNLOAD (first-run engine/model fetch — HuggingFace/CDN)" ;;
    api.openai.com|*.openai.com|*.azure.com)
      echo "CLOUD-REFINE (OPT-IN — only if you chose a cloud LLM provider)" ;;
    *apple.com|*icloud.com|*.mzstatic.com)
      echo "APPLE-OS (notarization/OCSP/CDN — macOS itself, not app data)" ;;
    *)
      echo "UNEXPECTED (not on the known-legitimate list — investigate!)" ;;
  esac
}

echo
echo "--------------------------------------------------------------"
echo " VERDICT"
echo "--------------------------------------------------------------"

if [ "$HAVE_NETTOP" -eq 1 ] && [ -s "$WORK/nettop.err" ] && ! [ -s "$WORK/nettop.txt" ]; then
  echo " note: nettop produced no data (it may need elevated privileges on"
  echo "       this macOS version — try: sudo $0 -p $PID). Relied on lsof."
  echo
fi

if ! [ -s "$DEST" ]; then
  cat <<EOF
 [OK]  SILENCE. No outbound connections observed from $PROC_NAME during the
       ${DURATION}s window.

 This is the expected result for pure on-device dictation: transcription runs
 on the Apple Neural Engine and never touches the network. If you expected an
 update check or a cloud-refine call and saw nothing, it simply didn't fire in
 this window (Sparkle checks ~once/day; refine only on a cloud provider).
EOF
  echo
  echo "--------------------------------------------------------------"
  echo " Cross-check with Little Snitch and the source — see docs/PRIVACY_PROOF.md"
  exit 0
fi

unexpected=0
while IFS= read -r hp; do
  [ -z "$hp" ] && continue
  tag="$(classify "$hp")"
  printf '   %-40s  %s\n' "$hp" "$tag"
  case "$tag" in UNEXPECTED*) unexpected=$(( unexpected + 1 )) ;; esac
done < "$DEST"

echo
if [ "$unexpected" -gt 0 ]; then
  echo " [!]  $unexpected connection(s) are NOT on the known-legitimate list above."
  echo "      Investigate them (see docs/PRIVACY_PROOF.md). If OpenWhisp made them,"
  echo "      that's a bug worth reporting privately (SECURITY.md)."
else
  echo " [OK]  Every observed connection maps to a known, documented, legitimate"
  echo "       purpose (update check / model download / your opt-in cloud refine)."
  echo "       No dictation audio or text is sent by the on-device transcription path."
fi
echo
echo "--------------------------------------------------------------"
echo " Cross-check with Little Snitch and the source — see docs/PRIVACY_PROOF.md"
exit 0
