#!/bin/bash
# Tier-2 E2E — live app-feature tests over the agent bridge.
#
# Drives the RUNNING OpenWhisp app through its `openwhisp` CLI (the agent bridge)
# and asserts each user-facing text feature end-to-end against the REAL LLM /
# real app state — the part `swift test` can't cover (it stubs the LLM). This is
# the "give it something, ask it to refine, and confirm the output actually
# changed" test.
#
#   text + instruction ──openwhisp refine──▶ bridge ──▶ AppState ──▶ real LLM
#                                                                       │
#                            refined text  ◀────────── stdout ◀─────────┘
#
# Covers: refine (rephrase / grammar / translate / no-op), status, history.
# Dictation-through-a-mic is a separate script (scripts/e2e-smoke.sh, BlackHole).
#
# Prereq: the OpenWhisp app must be RUNNING with an LLM configured
# (`openwhisp status` shows `llm=configured`). Refine needs a local or cloud LLM
# set up in Settings; without one the refine cases are skipped, not failed.
#
# Usage:
#   ./scripts/e2e-app-features.sh          # run all live feature checks
#   ./scripts/e2e-app-features.sh refine   # just the refine checks

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BINARY="OpenWhisp"

log()  { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

PASS=0; FAIL=0; SKIP=0
pass() { ok "$*"; PASS=$((PASS + 1)); }
failed() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
skip() { warn "SKIP: $*"; SKIP=$((SKIP + 1)); }

# Locate the CLI: the installed app first, then a local build, then swift build.
find_cli() {
    local candidates=(
        "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp"
        "$PROJECT_DIR/build/$APP_BINARY.app/Contents/Helpers/openwhisp"
        "$PROJECT_DIR/.build/debug/openwhisp"
        "$PROJECT_DIR/.build/release/openwhisp"
    )
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

CLI="$(find_cli)" || die "openwhisp CLI not found — build/install the app first (./build.sh && ./package.sh)."
log "Using CLI: $CLI"

STATUS="$("$CLI" status 2>/dev/null)" || die "OpenWhisp app not running / bridge unreachable. Launch the app, then retry."
log "App: $STATUS"
LLM_OK=0
printf '%s' "$STATUS" | grep -q "llm=configured" && LLM_OK=1

# lower-case + collapse whitespace, for tolerant comparisons.
norm() { tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//'; }

# refine_assert "<label>" "<instruction>" "<input>" "<mode>" ["<needle>"]
#   mode=changed   → output must differ from input (case-insensitive)
#   mode=contains  → normalized output must contain <needle>
#   mode=unchanged → output must equal input (no-op instruction)
refine_assert() {
    local label="$1" instr="$2" input="$3" mode="$4" needle="${5:-}"
    if [[ "$LLM_OK" != "1" ]]; then skip "$label (no LLM configured)"; return; fi

    local out rc
    out="$("$CLI" refine -i "$instr" "$input" 2>/dev/null)"; rc=$?
    if [[ $rc -ne 0 ]]; then failed "$label — refine exited $rc"; return; fi
    if [[ -z "${out// }" ]]; then failed "$label — empty output"; return; fi

    case "$mode" in
        changed)
            if [[ "$(printf '%s' "$out" | norm)" != "$(printf '%s' "$input" | norm)" ]]; then
                pass "$label — refined to: \"$out\""
            else
                failed "$label — output unchanged from input: \"$out\""
            fi ;;
        contains)
            if printf '%s' "$out" | norm | grep -qF "$(printf '%s' "$needle" | norm)"; then
                pass "$label — contains \"$needle\": \"$out\""
            else
                failed "$label — expected \"$needle\" in: \"$out\""
            fi ;;
        unchanged)
            if [[ "$(printf '%s' "$out" | norm)" == "$(printf '%s' "$input" | norm)" ]]; then
                pass "$label — correctly left unchanged"
            else
                failed "$label — should have been unchanged, got: \"$out\""
            fi ;;
    esac
}

run_refine() {
    log "── Refine (real LLM) ──"
    # 1) Rephrase changes the text.
    refine_assert "rephrase" \
        "make this formal and polite" \
        "hey can u send me the report thx" \
        changed
    # 2) Grammar/spelling fix produces a corrected, different string.
    refine_assert "grammar+spelling" \
        "fix grammar and spelling" \
        "i has three apple and dont no how to spel" \
        changed
    # 3) Translation to French → a French marker word appears.
    #    Kept tolerant: any of a few common tokens counts (models vary).
    if [[ "$LLM_OK" == "1" ]]; then
        local fr; fr="$("$CLI" refine -i "translate to French" "good morning, how are you" 2>/dev/null | norm)"
        if printf '%s' "$fr" | grep -qE "bonjour|comment|va|vous|matin"; then
            pass "translate-fr — got French: \"$fr\""
        else
            failed "translate-fr — no French markers in: \"$fr\""
        fi
    else
        skip "translate-fr (no LLM configured)"
    fi
    # 4) A no-op instruction returns the text unchanged (guards over-eager rewriting).
    refine_assert "no-op passthrough" \
        "return the text exactly unchanged" \
        "already perfect text." \
        unchanged
    # 5) stdin form (pipeline: echo … | openwhisp refine -i …) works too.
    if [[ "$LLM_OK" == "1" ]]; then
        local piped; piped="$(printf '%s\n' "the door is open" | "$CLI" refine -i "make it a question" 2>/dev/null)"
        if [[ -n "${piped// }" && "$(printf '%s' "$piped" | norm)" != "the door is open" ]]; then
            pass "stdin-refine — \"$piped\""
        else
            failed "stdin-refine — unexpected: \"$piped\""
        fi
    else
        skip "stdin-refine (no LLM configured)"
    fi
    # 6) --json output is well-formed and carries a non-empty text field.
    if [[ "$LLM_OK" == "1" ]]; then
        local js; js="$("$CLI" refine -i "shorten" "this sentence is much longer than it needs to be" --json 2>/dev/null)"
        if printf '%s' "$js" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('text') else 1)" 2>/dev/null; then
            pass "refine --json — well-formed: $js"
        else
            failed "refine --json — malformed or empty: $js"
        fi
    else
        skip "refine --json (no LLM configured)"
    fi
}

run_status() {
    log "── Status ──"
    local s; s="$("$CLI" status 2>/dev/null)"
    if printf '%s' "$s" | grep -qE "OpenWhisp .* engine="; then
        pass "status — \"$s\""
    else
        failed "status — unexpected: \"$s\""
    fi
    local js; js="$("$CLI" status --json 2>/dev/null)"
    if printf '%s' "$js" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        pass "status --json — valid JSON"
    else
        failed "status --json — invalid: $js"
    fi
}

run_history() {
    log "── History ──"
    # history must at least return valid JSON with an entries array (may be empty).
    local js; js="$("$CLI" history --limit 3 --json 2>/dev/null)"
    if printf '%s' "$js" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'entries' in d else 1)" 2>/dev/null; then
        pass "history --json — valid, entries present"
    else
        failed "history --json — missing entries / invalid: $js"
    fi
}

case "${1:-all}" in
    refine)  run_refine ;;
    status)  run_status ;;
    history) run_history ;;
    all)     run_status; run_history; run_refine ;;
    *)       die "unknown suite '${1}': use refine | status | history | all" ;;
esac

echo ""
log "Results: $PASS passed, $FAIL failed, $SKIP skipped."
[[ $FAIL -eq 0 ]] || exit 1
[[ $PASS -gt 0 ]] || { warn "nothing ran (LLM not configured?)"; exit 2; }
ok "Live app-feature tests passed."
