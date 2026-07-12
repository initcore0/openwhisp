#!/usr/bin/env bash
#
# sync-loopback-server.sh -- boot the REAL LANBridgeServer standalone on 127.0.0.1
# for cross-repo P2P-sync integration (MAK-51 WP6). The openwhisp-ios sync test
# drives this over TLS-TCP: it dials the fixed port with the fixed PSK, runs
# hello -> consent -> sync.manifest -> sync.push -> sync.pull, and asserts the
# merged fixture store on disk.
#
# It compiles + runs the `openwhisp-sync-loopback` SwiftPM executable, which wires
# the live sync verb handlers (SyncVerbHandlers over a file-backed SyncStore) to a
# pinned PSK + port from the environment and prints "READY <port>" on stdout once
# the listener is up.
#
# USAGE
#   OPENWHISP_SYNC_PSK=<base64-32-bytes> \
#   OPENWHISP_SYNC_PORT=<port> \
#   OPENWHISP_SYNC_FIXTURE_DIR=<dir with vocabulary.json/profiles.json/modes.json/history.json> \
#   [OPENWHISP_SYNC_PEER_ID=<uuid>] \
#     scripts/sync-loopback-server.sh
#
# The script generates any unset value and ECHOES the resolved settings to stderr
# (so a caller that let it pick a PSK/port can read them back), then execs the
# server in the foreground. Send SIGINT/SIGTERM to stop it.
#
# ENV
#   OPENWHISP_SYNC_PSK          base64 of the 32-byte pre-shared key. If unset, a
#                               fresh one is generated and printed to stderr.
#   OPENWHISP_SYNC_PORT         TCP port on 127.0.0.1. If unset, defaults to 53535.
#   OPENWHISP_SYNC_PEER_ID      UUID the client presents as the TLS identity hint.
#                               If unset, a fixed test UUID is used by the server.
#   OPENWHISP_SYNC_FIXTURE_DIR  fixture store dir. If unset, a fresh mktemp dir is
#                               created and printed to stderr.
#
# EXAMPLE (manual probe with the peer UUID as the PSK identity hint)
#   OPENWHISP_SYNC_PSK=$(head -c32 /dev/urandom | base64) \
#   OPENWHISP_SYNC_PORT=53535 \
#   OPENWHISP_SYNC_PEER_ID=0BADF00D-0000-0000-0000-00000000CAFE \
#   OPENWHISP_SYNC_FIXTURE_DIR=/tmp/owsync \
#     scripts/sync-loopback-server.sh
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Resolve settings, generating what is unset.
if [ -z "${OPENWHISP_SYNC_PSK:-}" ]; then
  OPENWHISP_SYNC_PSK="$(head -c 32 /dev/urandom | base64)"
  echo "sync-loopback: generated OPENWHISP_SYNC_PSK=$OPENWHISP_SYNC_PSK" >&2
fi
export OPENWHISP_SYNC_PSK

if [ -z "${OPENWHISP_SYNC_PORT:-}" ]; then
  OPENWHISP_SYNC_PORT="53535"
  echo "sync-loopback: defaulted OPENWHISP_SYNC_PORT=$OPENWHISP_SYNC_PORT" >&2
fi
export OPENWHISP_SYNC_PORT

if [ -z "${OPENWHISP_SYNC_FIXTURE_DIR:-}" ]; then
  OPENWHISP_SYNC_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/owsync.XXXXXX")"
  echo "sync-loopback: created OPENWHISP_SYNC_FIXTURE_DIR=$OPENWHISP_SYNC_FIXTURE_DIR" >&2
fi
export OPENWHISP_SYNC_FIXTURE_DIR

if [ -n "${OPENWHISP_SYNC_PEER_ID:-}" ]; then
  export OPENWHISP_SYNC_PEER_ID
fi

echo "sync-loopback: building openwhisp-sync-loopback..." >&2
swift build --product openwhisp-sync-loopback >&2

BIN="$(swift build --product openwhisp-sync-loopback --show-bin-path)/openwhisp-sync-loopback"
if [ ! -x "$BIN" ]; then
  echo "sync-loopback: FATAL: built binary not found at $BIN" >&2
  exit 70
fi

echo "sync-loopback: starting on 127.0.0.1:$OPENWHISP_SYNC_PORT (fixtures: $OPENWHISP_SYNC_FIXTURE_DIR)" >&2
exec "$BIN"
