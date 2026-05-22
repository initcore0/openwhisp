#!/bin/bash
# Reset only VoiceNote's macOS privacy records so stale rebuilt app identities
# can be removed from Accessibility and Input Monitoring.

set -euo pipefail

BUNDLE_ID="com.encryptedcat.voicenote"

echo "Resetting TCC permissions for $BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID" || true
tccutil reset ListenEvent "$BUNDLE_ID" || true
tccutil reset Microphone "$BUNDLE_ID" || true

echo ""
echo "Done."
echo "Now open the current app bundle and re-enable permissions when prompted:"
echo "  open /Users/encryptedcat/projects/voice-note/build/VoiceNote.app"
