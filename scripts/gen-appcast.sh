#!/bin/bash
# Generate a Sparkle appcast.xml for the latest OpenWhisp release (MAK-56).
#
# The appcast is a single <item> pointing at the newest DMG. We host it as a
# GitHub Release asset and reference it from Info.plist's SUFeedURL via the
# stable "releases/latest/download/appcast.xml" redirect, so every install always
# fetches the newest feed. A single item is sufficient: Sparkle only needs the
# LATEST version to offer an update, and older clients still see it.
#
# IMPORTANT: the enclosure <url> is the TAG-SPECIFIC asset URL
# (…/releases/download/<tag>/OpenWhisp.dmg), NOT latest/download — so the URL
# keeps resolving to this exact build even after newer releases ship.
#
# Usage:
#   scripts/gen-appcast.sh \
#     --version <shortVersion> \
#     --build <CFBundleVersion> \
#     --dmg <path/to/OpenWhisp.dmg> \
#     --url <https://…/releases/download/<tag>/OpenWhisp.dmg> \
#     --notes-link <https://…/releases/tag/<tag>> \
#     --sign-tool <path/to/sign_update> \
#     [--min-system <14.0>] \
#     [--changelog <docs/changelog/changelog.json>] \
#     --out <appcast.xml>
#
# The EdDSA private key is read from the SPARKLE_ED_PRIVATE_KEY environment
# variable (piped to sign_update --ed-key-file -). Never pass it on argv.
set -euo pipefail

VERSION=""
BUILD=""
DMG=""
URL=""
NOTES_LINK=""
SIGN_TOOL=""
MIN_SYSTEM="14.0"
CHANGELOG=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version)     VERSION="$2"; shift 2 ;;
        --build)       BUILD="$2"; shift 2 ;;
        --dmg)         DMG="$2"; shift 2 ;;
        --url)         URL="$2"; shift 2 ;;
        --notes-link)  NOTES_LINK="$2"; shift 2 ;;
        --sign-tool)   SIGN_TOOL="$2"; shift 2 ;;
        --min-system)  MIN_SYSTEM="$2"; shift 2 ;;
        --changelog)   CHANGELOG="$2"; shift 2 ;;
        --out)         OUT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

for req in VERSION BUILD DMG URL NOTES_LINK SIGN_TOOL OUT; do
    if [ -z "${!req}" ]; then
        echo "ERROR: missing required --$(echo "$req" | tr '[:upper:]' '[:lower:]')" >&2
        exit 2
    fi
done

[ -f "$DMG" ] || { echo "ERROR: DMG not found at $DMG" >&2; exit 1; }
[ -x "$SIGN_TOOL" ] || { echo "ERROR: sign_update not executable at $SIGN_TOOL" >&2; exit 1; }
: "${SPARKLE_ED_PRIVATE_KEY:?ERROR: SPARKLE_ED_PRIVATE_KEY env var is required to sign the update}"

# --- EdDSA signature + length -------------------------------------------------
# sign_update -p prints "sparkle:edSignature=... length=..." attributes. Read the
# key from stdin so it never appears in the process list.
SIGN_OUTPUT="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_TOOL" --ed-key-file - "$DMG" -p)"
# The -p output for signing an archive is the raw edSignature (base64). Length we
# compute ourselves for robustness across sign_update versions.
ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | tr -d '[:space:]')"
LENGTH="$(stat -f%z "$DMG" 2>/dev/null || stat -c%s "$DMG")"

if [ -z "$ED_SIGNATURE" ]; then
    echo "ERROR: sign_update produced an empty signature." >&2
    exit 1
fi

# --- Release headline (from changelog.json, best-effort) ----------------------
# Prefer the newest release's title for the item; fall back to the version.
TITLE="OpenWhisp $VERSION"
if [ -n "$CHANGELOG" ] && [ -f "$CHANGELOG" ] && command -v python3 >/dev/null 2>&1; then
    HEADLINE="$(python3 - "$CHANGELOG" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    rels = data.get("releases", [])
    if rels:
        r = rels[0]
        print(r.get("title") or r.get("id") or "")
except Exception:
    pass
PY
)"
    [ -n "$HEADLINE" ] && TITLE="OpenWhisp $VERSION — $HEADLINE"
fi

# RFC-822 pubDate (Sparkle sorts items by this + version).
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# XML-escape helper for text nodes/attributes.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

TITLE_ESC="$(xml_escape "$TITLE")"
URL_ESC="$(xml_escape "$URL")"
NOTES_ESC="$(xml_escape "$NOTES_LINK")"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>OpenWhisp</title>
        <description>OpenWhisp automatic updates.</description>
        <language>en</language>
        <item>
            <title>${TITLE_ESC}</title>
            <link>${NOTES_ESC}</link>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:releaseNotesLink>${NOTES_ESC}</sparkle:releaseNotesLink>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
            <pubDate>${PUBDATE}</pubDate>
            <enclosure url="${URL_ESC}" sparkle:version="${BUILD}" sparkle:shortVersionString="${VERSION}" length="${LENGTH}" type="application/octet-stream" sparkle:edSignature="${ED_SIGNATURE}" />
        </item>
    </channel>
</rss>
EOF

echo "Wrote appcast: $OUT (version $VERSION build $BUILD, length $LENGTH)" >&2
