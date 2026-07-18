#!/bin/bash
# AppState LOC ratchet (MAK-32).
#
# AppState is a 6,900+-line @MainActor god-object (128 @Published, ~91 didSet
# persistence blocks). The decomposition epic strangles it into Core types +
# coordinators. This ratchet stops it from silently regrowing while that work is
# in flight: it fails if the tracked AppState source exceeds a checked-in
# high-water mark. Every PR may only keep the mark equal or LOWER — and the mark
# is only ever lowered in the SAME PR that actually shrinks the files.
#
# Tracked file set (the whole AppState surface — the class + its extensions):
#   OpenWhisp/Models/AppState.swift
#   OpenWhisp/Models/AppState+Sync.swift
# Adding a NEW AppState+*.swift extension counts toward the budget too — list it
# here so splitting the file into extensions can't dodge the ratchet.
#
# High-water mark lives in scripts/appstate-loc-budget.txt (one integer: total
# `wc -l` across the tracked files).
#
# Run: scripts/check-appstate-ratchet.sh   (used by CI; also fine pre-commit)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

budget_file="scripts/appstate-loc-budget.txt"

tracked_files=(
    "OpenWhisp/Models/AppState.swift"
    "OpenWhisp/Models/AppState+Sync.swift"
)

if [[ ! -f "$budget_file" ]]; then
    echo "error: budget file not found: $budget_file" >&2
    exit 2
fi

budget="$(tr -d '[:space:]' < "$budget_file")"
if ! [[ "$budget" =~ ^[0-9]+$ ]]; then
    echo "error: $budget_file must contain a single integer (got: '$budget')" >&2
    exit 2
fi

for f in "${tracked_files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "error: tracked file missing (did it move? update this script): $f" >&2
        exit 2
    fi
done

# `wc -l < file` per file, summed — avoids the trailing "total" line and any
# path formatting differences between wc implementations.
actual=0
for f in "${tracked_files[@]}"; do
    n="$(wc -l < "$f" | tr -d '[:space:]')"
    actual=$((actual + n))
done

echo "AppState ratchet: ${actual} LOC (budget ${budget})"
for f in "${tracked_files[@]}"; do
    printf '  %6s  %s\n' "$(wc -l < "$f" | tr -d '[:space:]')" "$f"
done

if (( actual > budget )); then
    over=$((actual - budget))
    cat >&2 <<EOF

AppState ratchet FAILED: tracked AppState LOC = ${actual}, budget = ${budget} (over by ${over}).

  The AppState god-object is under a decomposition ratchet (MAK-32): it may only
  shrink or stay the same, never grow. Your change adds ${over} net line(s) to:
$(printf '    %s\n' "${tracked_files[@]}")

  Fix it the right way — do NOT just raise the budget:
    * Put new logic in OpenWhispCore (a resolver / store / coordinator) and have
      AppState call into it, instead of adding lines to AppState itself.
    * If you are LEGITIMATELY shrinking AppState (moved code out), lower the
      number in ${budget_file} to the new total IN THE SAME PR — that is the
      only sanctioned way the budget changes, and it should go DOWN.

  Raising the budget to let AppState grow defeats the ratchet and will be
  rejected in review.
EOF
    exit 1
fi

if (( actual < budget )); then
    cat >&2 <<EOF

Note: tracked AppState LOC (${actual}) is BELOW the budget (${budget}).
You shrank AppState — lock in the win by lowering ${budget_file} to ${actual}
in this PR so the ratchet can never drift back up. (This check passes either way,
but leaving slack lets a future change regrow AppState silently.)
EOF
fi

echo "AppState ratchet OK."
