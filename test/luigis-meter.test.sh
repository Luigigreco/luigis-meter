#!/bin/bash
#
# luigis-meter.test.sh — TDD RED-phase harness for luigis-meter.sh
#
# This suite is written AGAINST FUTURE BEHAVIOR that does not exist in the
# script yet. It is expected (and correct) that it FAILS right now. It goes
# green only after the implementer adds the seams below to luigis-meter.sh.
#
# ============================================================================
# REQUIRED TESTABILITY SEAMS (implementer TODO — Phase 2)
# ============================================================================
#
# 1. CLAUDE_PROJECTS_DIR (env override)
#    Today PROJECTS_DIR is hardcoded at line 41:
#        PROJECTS_DIR="$HOME/.claude/projects"
#    Needed:
#        PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
#    Without this the script can never be pointed at a fixture directory,
#    so it always reads the real (uncontrolled) transcript history — no test
#    here can be deterministic until this lands.
#
# 2. CLAUDE_NOW_EPOCH (env override for "now")
#    Today `NOW=$(date +%s)` (line 65) and the weekly-reset DOW/HOUR
#    computation (line 159, 163) call `date +%u` / `date +%H` against the
#    real wall clock. Needed: a single seam, e.g.
#        NOW="${CLAUDE_NOW_EPOCH:-$(date +%s)}"
#    and derive DOW/CURR_HOUR from $NOW (not fresh `date` calls) so time-based
#    assertions are reproducible regardless of when/where the test runs.
#
# 3. CLAUDE_WEEKLY_RESET_DOW / CLAUDE_WEEKLY_RESET_HHMM (env override)
#    Today the weekly reset day is hardcoded to Friday and the hour to 14:00
#    (lines 156-174). Needed: read target dow (1=Mon..7=Sun) and HH:MM from
#    CLAUDE_WEEKLY_RESET_DOW / CLAUDE_WEEKLY_RESET_HHMM (defaulting to 5 /
#    14:00 to preserve current behavior), and print the actual configured
#    HH:MM in RESET_WEEK_STR (today it prints the CURRENT wall-clock hour on
#    the Sat/Sun branch inputs — that's the "buggy" behavior Test Group A
#    pins down).
#
# 4. CLAUDE_FABLE_WEEKLY_TOKENS (env override) + a distinct Fable gauge
#    Today all models are summed into one weighted total; there is no
#    per-model breakout. Needed: when CLAUDE_FABLE_WEEKLY_TOKENS is set,
#    compute a second weighted sum restricted to
#    `.message.model == "claude-fable-5"` and print a second gauge (e.g.
#    "fable left: NN%") alongside the existing line(s).
#
# None of the above exist yet. Every RED failure below is a direct
# consequence of one of these four gaps. Do not "fix" this test file to
# work around their absence — add the seams to luigis-meter.sh instead.
# ============================================================================
#
# Fixtures: test/fixtures/projects/{testA,testB,testC}/*.jsonl are generated
# fresh on every run (timestamps relative to actual "now", file mtime = now)
# so `find -mtime -7` always picks them up once CLAUDE_PROJECTS_DIR exists.
#
# Usage: bash test/luigis-meter.test.sh

set -u

# --- Paths ---------------------------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$ROOT_DIR/luigis-meter.sh"
FIXTURES_ROOT="$TEST_DIR/fixtures/projects"
CACHE_FILE="${TMPDIR:-/tmp}/luigis-meter.cache"

PASS=0
FAIL=0

# --- Assert helpers --------------------------------------------------------
assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "        expected to find: [$needle]"
        echo "        in output:"
        printf '%s\n' "$haystack" | sed 's/^/          | /'
        FAIL=$((FAIL + 1))
    fi
}

assert_matches() {
    local haystack="$1" pattern="$2" desc="$3"
    if printf '%s' "$haystack" | grep -Eq -- "$pattern"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "        expected to match regex: [$pattern]"
        echo "        in output:"
        printf '%s\n' "$haystack" | sed 's/^/          | /'
        FAIL=$((FAIL + 1))
    fi
}

assert_not_matches() {
    local haystack="$1" pattern="$2" desc="$3"
    if printf '%s' "$haystack" | grep -Eq -- "$pattern"; then
        echo "  FAIL: $desc"
        echo "        expected NOT to match regex: [$pattern]"
        echo "        in output:"
        printf '%s\n' "$haystack" | sed 's/^/          | /'
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_equal_approx() {
    local actual="$1" expected="$2" tolerance="$3" desc="$4"
    if [ -z "$actual" ]; then
        echo "  FAIL: $desc"
        echo "        could not extract an actual value from output"
        FAIL=$((FAIL + 1))
        return
    fi
    local diff=$(( actual - expected ))
    if [ "$diff" -lt 0 ]; then diff=$(( -diff )); fi
    if [ "$diff" -le "$tolerance" ]; then
        echo "  PASS: $desc (actual=$actual expected=$expected +/-$tolerance)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (actual=$actual expected=$expected +/-$tolerance)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Timestamp helper (BSD date w/ GNU fallback, matches script's style) ---
iso_from_epoch() {
    local epoch="$1"
    date -u -r "$epoch" "+%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || \
    date -u -d "@$epoch" "+%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null
}

write_record() {
    # write_record <file> <epoch> <model> <input> <output> <cache_creation> <cache_read>
    local file="$1" epoch="$2" model="$3" in="$4" out="$5" cc="$6" cr="$7"
    local ts
    ts=$(iso_from_epoch "$epoch")
    printf '{"type":"assistant","timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
        "$ts" "$model" "$in" "$out" "$cc" "$cr" >> "$file"
}

run_meter() {
    # run_meter <env assignments...> -- captures stdout, deletes cache first.
    # Invoked as `bash "$SCRIPT"` (not executed directly) so the test harness
    # never needs to touch the script's file permissions.
    rm -f "$CACHE_FILE"
    env "$@" bash "$SCRIPT"
}

# strip_ansi: removes CSI color codes (ESC [ ... letter) and OSC 8 hyperlink
# sequences (ESC ] 8 ;; ... BEL) so numeric extraction via grep isn't broken
# by an escape sequence sitting between a label and its value (the script
# colors every percentage, e.g. "week left: \x1b[32m88%\x1b[0m"). This does
# not change what is being asserted, only makes the extraction robust to
# terminal styling.
strip_ansi() {
    local esc bel
    esc=$(printf '\033')
    bel=$(printf '\007')
    sed -E "s/${esc}\\[[0-9;]*[A-Za-z]//g; s/${esc}\\][^${bel}]*${bel}//g"
}

NOW_EPOCH=$(date +%s)
CURRENT_HHMM=$(date +%H:%M)

echo "=============================================================="
echo "luigis-meter TDD harness — RED phase (seams not yet implemented)"
echo "=============================================================="

# ============================================================================
# GROUP A — weekly reset configurable via env
# ============================================================================
echo ""
echo "--- Group A: configurable weekly reset (CLAUDE_WEEKLY_RESET_DOW/HHMM) ---"

FIX_A="$FIXTURES_ROOT/testA"
rm -rf "$FIX_A"
mkdir -p "$FIX_A"
write_record "$FIX_A/session1.jsonl" "$NOW_EPOCH" "claude-opus-4-8" 1000 500 0 0

OUT_A=$(run_meter \
    CLAUDE_PROJECTS_DIR="$FIX_A" \
    CLAUDE_NOW_EPOCH="$NOW_EPOCH" \
    CLAUDE_WEEKLY_RESET_DOW=7 \
    CLAUDE_WEEKLY_RESET_HHMM=14:59)

assert_contains "$OUT_A" "14:59" \
    "reset field shows configured HH:MM (14:59), not hardcoded 14:00/current clock"
assert_matches "$OUT_A" "(Sun|dom)" \
    "reset field shows configured weekday label (Sunday), not hardcoded Friday"
assert_not_matches "$OUT_A" "reset Fri" \
    "reset field must NOT read 'reset Fri ...' when DOW override=7 (Sunday)"
assert_not_matches "$OUT_A" "reset [A-Za-z]+ ${CURRENT_HHMM}" \
    "reset HH:MM must NOT be the current wall-clock time (${CURRENT_HHMM}) — that was the original bug"

# ============================================================================
# GROUP B — separate Fable gauge line
# ============================================================================
echo ""
echo "--- Group B: distinct Fable gauge (CLAUDE_FABLE_WEEKLY_TOKENS) ---"

FIX_B="$FIXTURES_ROOT/testB"
rm -rf "$FIX_B"
mkdir -p "$FIX_B"
write_record "$FIX_B/session1.jsonl" "$NOW_EPOCH" "claude-fable-5" 2000 1000 0 0
write_record "$FIX_B/session1.jsonl" "$(( NOW_EPOCH - 3600 ))" "claude-opus-4-8" 5000 3000 0 0

OUT_B=$(run_meter \
    CLAUDE_PROJECTS_DIR="$FIX_B" \
    CLAUDE_NOW_EPOCH="$NOW_EPOCH" \
    CLAUDE_FABLE_WEEKLY_TOKENS=500000)

assert_matches "$OUT_B" "[Ff]able" \
    "output contains a distinct 'fable'/'Fable' gauge token"
assert_matches "$OUT_B" "[Ff]able[^%]{0,40}[0-9]{1,3}%" \
    "the Fable gauge token is followed by a percentage value"

# ============================================================================
# GROUP C — regression guard: weekly % must match independently-computed math
# ============================================================================
echo ""
echo "--- Group C: weekly aggregate math regression guard ---"

FIX_C="$FIXTURES_ROOT/testC"
rm -rf "$FIX_C"
mkdir -p "$FIX_C"

# Three records, all inside the 7-day window. Numbers chosen so the expected
# weighted sum is a clean value the test can recompute independently using
# the SAME formula documented in luigis-meter.sh:
#   weighted = input + output + 1.25*cache_creation + 0.10*cache_read
# R1: 1000 + 2000 + 1.25*800  + 0.10*5000  = 3000 + 1000 + 500  = 4500
# R2: 500  + 500  + 1.25*0    + 0.10*10000 = 1000 + 0    + 1000 = 2000
# R3: 2000 + 3000 + 1.25*400  + 0.10*2000  = 5000 + 500  + 200  = 5700
# TOTAL WEIGHTED = 4500 + 2000 + 5700 = 12200
write_record "$FIX_C/session1.jsonl" "$(( NOW_EPOCH - 2 * 86400 ))" "claude-opus-4-8" 1000 2000 800 5000
write_record "$FIX_C/session1.jsonl" "$(( NOW_EPOCH - 1 * 86400 ))" "claude-opus-4-8" 500  500  0   10000
write_record "$FIX_C/session1.jsonl" "$(( NOW_EPOCH - 3 * 3600 ))"  "claude-opus-4-8" 2000 3000 400 2000

EXPECTED_SUM=12200
MAX_WEEKLY_C=100000

# Independent computation of the expected "week left %" using the exact
# formula from the docstring (mirrors the script's own truncating printf).
EXPECTED_PCT_USED=$(awk -v s="$EXPECTED_SUM" -v m="$MAX_WEEKLY_C" 'BEGIN { printf "%d", (s*100/m) }')
EXPECTED_PCT_LEFT=$(( 100 - EXPECTED_PCT_USED ))

OUT_C=$(run_meter \
    CLAUDE_PROJECTS_DIR="$FIX_C" \
    CLAUDE_NOW_EPOCH="$NOW_EPOCH" \
    CLAUDE_MAX_WEEKLY_TOKENS="$MAX_WEEKLY_C")

ACTUAL_PCT=$(printf '%s' "$OUT_C" | strip_ansi | grep -oE 'week left: [0-9]+%' | grep -oE '[0-9]+' | head -1)

assert_equal_approx "${ACTUAL_PCT:-}" "$EXPECTED_PCT_LEFT" 1 \
    "week-left% for controlled fixture matches independently-computed weighted formula"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=============================================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "=============================================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
