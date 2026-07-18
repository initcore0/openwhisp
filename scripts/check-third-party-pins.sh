#!/bin/bash
# Supply-chain hygiene gate for native deps (MAK-64).
#
# Asserts two things about third_party/ without hitting the network:
#
#   1. Every submodule in .gitmodules is pinned to a commit that is REACHABLE
#      FROM A TAG (a real upstream release), OR is explicitly allowlisted below
#      with a documented reason. A bare, untagged master commit is a supply-
#      chain smell (nothing upstream guarantees it stays fetchable / unforced),
#      so it must be justified in the allowlist.
#
#   2. Any dependency URL that points at a PERSONAL FORK (github.com/initcore0/*)
#      — whether a git submodule or a SwiftPM `.package(url:)` under
#      third_party/*-dep/Package.swift — has a corresponding entry in
#      third_party/PATCHES.md, so the fork's delta stays reconstructible if the
#      fork ever disappears.
#
# Runs offline: it reads .gitmodules + the checked-out submodule git state
# (`git describe --tags`, which needs tags fetched — CI checks out submodules
# with tags) and greps the *-dep manifests. No clones, no remote calls.
#
# Usage: scripts/check-third-party-pins.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

fail=0
err() { echo "  ✗ $*" >&2; fail=1; }
ok()  { echo "  ✓ $*"; }

# ---------------------------------------------------------------------------
# Allowlist: submodule path -> reason a NON-tagged (bare) commit is required.
# Add an entry ONLY with a real justification; the whole point of the gate is
# that a bare pin is a deliberate, documented exception, not the default.
# Format: one "path|reason" per line. (Currently empty — both submodules are
# tag-pinned, which is the goal state.)
# ---------------------------------------------------------------------------
allowlist_reason() {
    case "$1" in
        # third_party/example) echo "needs unreleased fix #NNNN, no tag yet" ;;
        *) echo "" ;;
    esac
}

PATCHES="third_party/PATCHES.md"

# A URL pointing at a personal fork must be documented in PATCHES.md.
check_patches_entry() {
    local url="$1" where="$2"
    # Reduce a URL to owner/repo for a stable grep key.
    local key
    key=$(echo "$url" | sed -E 's#^https?://github\.com/##; s#^git@github\.com:##; s#\.git$##')
    if [ -f "$PATCHES" ] && grep -q "$key" "$PATCHES"; then
        ok "$where -> personal fork $key documented in $PATCHES"
    else
        err "$where -> personal fork $key has NO entry in $PATCHES. Document the fork delta there."
    fi
}

echo "== third_party pin hygiene =="

# ---- 1. submodules pinned to a tag (or allowlisted) -----------------------
# Parse .gitmodules for path + url pairs.
paths=()
while IFS= read -r line; do
    paths+=("$line")
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

for path in "${paths[@]}"; do
    name=$(git config -f .gitmodules --get-regexp '\.path$' | awk -v p="$path" '$2==p {print $1}' | sed -E 's/^submodule\.(.*)\.path$/\1/')
    url=$(git config -f .gitmodules --get "submodule.${name}.url")

    if [ ! -e "$path/.git" ] && [ ! -f "$path/.git" ]; then
        err "$path: submodule not checked out (run: git submodule update --init $path)"
        continue
    fi

    # Reachable-from-a-tag check. `git describe --tags <sha>` succeeds iff the
    # commit is reachable from some tag; it fails ("no tag can describe") for a
    # bare untagged commit ahead of every tag.
    if desc=$(git -C "$path" describe --tags HEAD 2>/dev/null); then
        ok "$path @ $desc (tag-reachable)"
    else
        reason=$(allowlist_reason "$path")
        if [ -n "$reason" ]; then
            ok "$path: bare commit, allowlisted — $reason"
        else
            err "$path: pinned to a commit not reachable from any tag, and not allowlisted. Repin to a release tag or add an allowlist entry with a reason."
        fi
    fi

    # ---- 2a. personal-fork submodule needs a PATCHES.md entry -------------
    if echo "$url" | grep -qiE 'github\.com[:/]initcore0/'; then
        check_patches_entry "$url" "$path (.gitmodules)"
    fi
done

# ---- 2b. personal-fork SwiftPM deps need a PATCHES.md entry ----------------
while IFS= read -r manifest; do
    # Pull each initcore0 package URL out of the manifest.
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        check_patches_entry "$url" "$manifest"
    done < <(grep -oE 'https://github\.com/initcore0/[A-Za-z0-9._-]+(\.git)?' "$manifest" || true)
done < <(find third_party -name Package.swift 2>/dev/null)

echo
if [ "$fail" -ne 0 ]; then
    echo "third_party pin hygiene: FAILED" >&2
    exit 1
fi
echo "third_party pin hygiene: OK"
