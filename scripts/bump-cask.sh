#!/bin/bash
# Update the Homebrew cask for a tagged release and push it to the self-hosted
# tap repo (MAK-55).
#
# On each tagged release the CI computes the DMG sha256, rewrites the version +
# sha256 lines of packaging/homebrew/Casks/openwhisp.rb, and commits the result
# into the tap repo initcore0/homebrew-openwhisp so `brew upgrade` sees the new
# build.
#
# GUARD: if no push token is available (TAP_PUSH_TOKEN secret absent — e.g. the
# tap repo hasn't been created yet, or a fork build), the script updates the cask
# in-tree and logs clearly, but does NOT attempt a push and exits 0. Releases
# must never fail just because the tap isn't published yet.
#
# Usage:
#   scripts/bump-cask.sh \
#     --version <shortVersion> \      # e.g. 1.0.0
#     --build <CFBundleVersion> \     # e.g. 155
#     --dmg <path/to/OpenWhisp.dmg> \
#     [--cask <path/to/openwhisp.rb>] # default: packaging/homebrew/Casks/openwhisp.rb
#
# Environment:
#   TAP_PUSH_TOKEN   GitHub token with push access to the tap repo (optional).
#   TAP_REPO         Tap repo slug (default: initcore0/homebrew-openwhisp).
#   GIT_AUTHOR_*     Optional; falls back to a bot identity.
set -euo pipefail

VERSION=""
BUILD=""
DMG=""
CASK="packaging/homebrew/Casks/openwhisp.rb"
TAP_REPO="${TAP_REPO:-initcore0/homebrew-openwhisp}"

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build)   BUILD="$2"; shift 2 ;;
        --dmg)     DMG="$2"; shift 2 ;;
        --cask)    CASK="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

for req in VERSION BUILD DMG; do
    if [ -z "${!req}" ]; then
        echo "ERROR: missing required --$(echo "$req" | tr '[:upper:]' '[:lower:]')" >&2
        exit 2
    fi
done
[ -f "$DMG" ]  || { echo "ERROR: DMG not found at $DMG" >&2; exit 1; }
[ -f "$CASK" ] || { echo "ERROR: cask not found at $CASK" >&2; exit 1; }

# --- Compute the new sha256 + Homebrew version string -------------------------
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
CASK_VERSION="${VERSION},${BUILD}"   # Homebrew version,revision → rebuilds v<version>+<build>

echo "bump-cask: version=${CASK_VERSION} sha256=${SHA256}"

# --- Rewrite version + sha256 lines in place ----------------------------------
# Portable in-place edit (BSD + GNU sed) via a temp file.
tmp="$(mktemp)"
sed -E \
    -e "s/^([[:space:]]*version )\"[^\"]*\"/\1\"${CASK_VERSION}\"/" \
    -e "s/^([[:space:]]*sha256 )\"[^\"]*\"/\1\"${SHA256}\"/" \
    "$CASK" > "$tmp"
mv "$tmp" "$CASK"

echo "----- updated cask -----"
sed -n '1,10p' "$CASK"

# --- Push to the tap repo (guarded) -------------------------------------------
if [ -z "${TAP_PUSH_TOKEN:-}" ]; then
    echo "TAP_PUSH_TOKEN not set — the tap repo (${TAP_REPO}) is not wired up yet."
    echo "Skipping tap push. The cask was updated in-tree; publish the tap and set"
    echo "the TAP_PUSH_TOKEN secret to enable automatic cask pushes (see"
    echo "packaging/homebrew/README.md)."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Cloning tap ${TAP_REPO}…"
git clone --depth 1 "https://x-access-token:${TAP_PUSH_TOKEN}@github.com/${TAP_REPO}.git" "$WORK/tap"

mkdir -p "$WORK/tap/Casks"
cp "$CASK" "$WORK/tap/Casks/openwhisp.rb"

cd "$WORK/tap"
git config user.name  "${GIT_AUTHOR_NAME:-openwhisp-release-bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-noreply@openwhisp.app}"

if git diff --quiet -- Casks/openwhisp.rb; then
    echo "Tap cask already up to date for ${CASK_VERSION} — nothing to push."
    exit 0
fi

git add Casks/openwhisp.rb
git commit -m "openwhisp ${VERSION} (build ${BUILD})"
git push origin HEAD
echo "Pushed openwhisp ${CASK_VERSION} to ${TAP_REPO}."
