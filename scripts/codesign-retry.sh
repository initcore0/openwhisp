#!/bin/bash
# codesign wrapper that retries on Apple timestamp-service flakiness.
#
# `codesign --timestamp` contacts Apple's timestamp server; when it's slow or
# unreachable it fails with "A timestamp was expected but was not found" (or
# "timestamp service is not available"). On a release runner that error lands
# AFTER the ~1h native builds, wasting the whole run (v1.0.1 died exactly this
# way). The failure is transient, so retry it — but ONLY the timestamp flavor;
# real signing errors (bad identity, malformed bundle) still fail immediately.
#
# Usage: codesign-retry.sh <codesign args...>
set -uo pipefail

ATTEMPTS=5
for i in $(seq 1 "$ATTEMPTS"); do
    ERR="$(codesign "$@" 2>&1)"
    STATUS=$?
    [ -n "$ERR" ] && echo "$ERR" >&2
    [ "$STATUS" -eq 0 ] && exit 0
    if echo "$ERR" | grep -qi "timestamp"; then
        if [ "$i" -lt "$ATTEMPTS" ]; then
            DELAY=$((i * 15))
            echo "codesign: timestamp-service failure (attempt $i/$ATTEMPTS); retrying in ${DELAY}s..." >&2
            sleep "$DELAY"
            continue
        fi
        echo "codesign: timestamp-service failure persisted after $ATTEMPTS attempts." >&2
    fi
    exit "$STATUS"
done
exit 1
