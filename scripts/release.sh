#!/bin/bash
# Cut a manual OpenWhisp release (MAK-58).
#
# OpenWhisp used to publish a release on *every* merge to main. It now releases
# only when you deliberately cut one: this script bumps the version, writes it
# into Info.plist, and creates + pushes an annotated tag. The tag push is what
# fires .github/workflows/release.yml — nothing releases without a tag.
#
# Usage:
#   scripts/release.sh [major|minor|patch]     # default: patch
#   scripts/release.sh --version 1.4.0         # set an explicit version
#   scripts/release.sh patch --dry-run         # show what would happen, change nothing
#
# The tag is  v<version>+<build>  (e.g. v1.0.1+156). Two numbers travel in it:
#   - <version>  the human short version (CFBundleShortVersionString), which you
#                bump here (major/minor/patch).
#   - <build>    the monotonic CFBundleVersion that Sparkle orders updates by.
#                It is ALWAYS (highest existing build across every tag) + 1, so
#                the appcast never offers an installed fleet a *lower* build than
#                it already has — which Sparkle would silently refuse to install.
#                This is why we can't reset it when the version changes.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

PLIST="OpenWhisp/Info.plist"
BUMP="patch"
EXPLICIT_VERSION=""
DRY_RUN="0"

while [ $# -gt 0 ]; do
    case "$1" in
        major|minor|patch) BUMP="$1"; shift ;;
        --version) EXPLICIT_VERSION="${2:?--version needs an argument}"; shift 2 ;;
        --dry-run) DRY_RUN="1"; shift ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

command -v git >/dev/null || die "git not found"
[ -f "$PLIST" ] || die "Info.plist not found at $PLIST (run from the repo)"

# --- Preconditions ------------------------------------------------------------
# Releases are cut from a clean, up-to-date main so the tag points at exactly
# what's on origin. --dry-run relaxes nothing here: the checks are the point.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "not on main (on '$BRANCH'). Releases are cut from main."

if [ -n "$(git status --porcelain)" ]; then
    die "working tree is dirty. Commit or stash before releasing."
fi

echo "Fetching origin (tags + main) …"
git fetch --quiet origin main --tags

LOCAL="$(git rev-parse @)"
REMOTE="$(git rev-parse origin/main)"
[ "$LOCAL" = "$REMOTE" ] || die "local main ($LOCAL) != origin/main ($REMOTE). Pull/push first."

# --- Compute the new short version --------------------------------------------
CURRENT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
[[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString '$CURRENT' is not X.Y.Z"

if [ -n "$EXPLICIT_VERSION" ]; then
    [[ "$EXPLICIT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must be X.Y.Z, got '$EXPLICIT_VERSION'"
    NEW_VERSION="$EXPLICIT_VERSION"
else
    IFS='.' read -r MAJ MIN PAT <<< "$CURRENT"
    case "$BUMP" in
        major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
        minor) MIN=$((MIN + 1)); PAT=0 ;;
        patch) PAT=$((PAT + 1)) ;;
    esac
    NEW_VERSION="${MAJ}.${MIN}.${PAT}"
fi

# --- Compute the monotonic build number ---------------------------------------
# Highest build across ALL v*+<n> tags, then +1. Falls back to CFBundleVersion
# so the very first tagless run still climbs from the Info.plist value.
HIGHEST_TAG_BUILD="$(git tag --list 'v*+*' | sed -n 's/.*+\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo 0)"
[[ "$PLIST_BUILD" =~ ^[0-9]+$ ]] || PLIST_BUILD=0
BASE_BUILD="${HIGHEST_TAG_BUILD:-0}"
[ "$PLIST_BUILD" -gt "$BASE_BUILD" ] && BASE_BUILD="$PLIST_BUILD"
NEW_BUILD=$((BASE_BUILD + 1))

TAG="v${NEW_VERSION}+${NEW_BUILD}"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists. Bump the version or delete the tag."
fi

# --- Summary ------------------------------------------------------------------
PREV_TAG="$(git tag --list 'v*' | sort -V | tail -1 || true)"
echo
echo "  Release plan"
echo "  ------------"
echo "  version:   $CURRENT  ->  $NEW_VERSION   ($BUMP)"
echo "  build:     $NEW_BUILD   (was highest ${BASE_BUILD})"
echo "  tag:       $TAG"
echo "  from:      $(git rev-parse --short HEAD) on main"
echo
if [ -n "$PREV_TAG" ]; then
    COUNT="$(git rev-list --count "${PREV_TAG}..HEAD" 2>/dev/null || echo '?')"
    echo "  $COUNT commit(s) since $PREV_TAG:"
    git log --no-merges --pretty='    - %s' "${PREV_TAG}..HEAD" 2>/dev/null | head -30 || true
    echo
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run — no changes made, no tag created."
    exit 0
fi

read -r -p "Cut this release? Commits the version bump, tags, and pushes. [y/N] " REPLY
case "$REPLY" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
esac

# --- Bump, commit, tag, push --------------------------------------------------
# Stamp the short version into Info.plist and commit it, so main always reflects
# the released version. CFBundleVersion is stamped by CI from the tag at build
# time (keeping the plist's build number stable in git).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "$PLIST"

git add "$PLIST"
git commit -m "chore(release): ${NEW_VERSION}

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"

git tag -a "$TAG" -m "OpenWhisp $TAG"

echo
echo "Pushing main + tag $TAG …"
git push origin main
git push origin "$TAG"

REPO_SLUG="$(git config --get remote.origin.url | sed -E 's#(git@|https://)github.com[:/]##; s/\.git$//')"
echo
echo "Done. Release workflow is building $TAG."
echo "Watch it: https://github.com/${REPO_SLUG}/actions/workflows/release.yml"
echo "Release:  https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
