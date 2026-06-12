#!/bin/bash
#
# Plain-bash test harness for luigis-meter.sh (no bats dependency).
# Targets bash 3.2 (macOS system bash) — no associative arrays, no mapfile.
#
# Run:  bash tests/test_luigis_meter.sh
# Exit: 0 if all pass, 1 if any fail.
#
# Test seams used (must be supported by luigis-meter.sh):
#   CLAUDE_METER_PROJECTS_DIR  point at synthetic fixtures
#   CLAUDE_METER_CACHE_FILE    isolate cache per test (defeat 30s TTL)
#   CLAUDE_METER_NOW           pin the clock (epoch seconds)
#   CLAUDE_MAX_5H_TOKENS / _WEEKLY_TOKENS  calibrated limits (when set)
#   CLAUDE_METER_INCLUDE_SIDECHAINS        toggle sidechain inclusion
#

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../luigis-meter.sh"
WORK="${TMPDIR:-/tmp}/lm-test.$$"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------

# iso <epoch> -> ISO8601 UTC with .000Z (BSD or GNU date)
iso() {
    date -u -r "$1" "+%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
        || date -u -d "@$1" "+%Y-%m-%dT%H:%M:%S.000Z"
}

# emit_record <file> <epoch> <in> <out> <requestId> <isSidechain:true|false>
emit_record() {
    local file="$1" ep="$2" in="$3" out="$4" rid="$5" side="$6"
    jq -nc \
        --arg t "$(iso "$ep")" \
        --argjson in "$in" --argjson out "$out" \
        --arg rid "$rid" --argjson side "$side" \
        '{type:"assistant", requestId:$rid, isSidechain:$side,
          timestamp:$t,
          message:{usage:{input_tokens:$in, output_tokens:$out,
                          cache_read_input_tokens:99999}}}' >> "$file"
}

# run the meter with a pinned env; stdout captured in global RUN_OUT, status in RUN_ST
run_meter() {
    local proj="$1" now="$2"; shift 2
    local cache="$WORK/cache.$RANDOM"
    rm -f "$cache"
    RUN_OUT="$(env CLAUDE_METER_PROJECTS_DIR="$proj" \
                   CLAUDE_METER_CACHE_FILE="$cache" \
                   CLAUDE_METER_NOW="$now" \
                   "$@" bash "$SCRIPT" 2>"$WORK/err")"
    RUN_ST=$?
    RUN_CACHE="$cache"
    # ANSI/OSC-stripped copy for substring assertions on colored fields
    RUN_PLAIN=$(printf '%s' "$RUN_OUT" \
        | LC_ALL=C sed -e 's/'$'\x1b''\[[0-9;]*m//g' -e 's/'$'\x1b'']8;;[^'$'\x07'']*'$'\x07''//g')
}

ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
no()   { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "       %s\n" "$2"; }

# mins_left <output> -> total minutes parsed from "Xh Ym" (strips ≈/est. decoration)
mins_left() {
    echo "$1" | sed -nE 's/.*[^0-9]([0-9]+)h ([0-9]+)m.*/\1 \2/p' \
        | awk '{print $1*60+$2}'
}

# --- fixtures ----------------------------------------------------------------

mkdir -p "$WORK"
NOW=1718200800   # fixed clock for window tests; floor to 5h grid = 1718190000

# F1: one in-5h record (2h ago) 10000+5000, one in-week-only (3d ago) 12000+8000
F1="$WORK/f1"; mkdir -p "$F1/projA" "$F1/projB"
emit_record "$F1/projA/a.jsonl" $((NOW-7200))   10000 5000 req_a false
emit_record "$F1/projB/b.jsonl" $((NOW-259200)) 12000 8000 req_b false
# noise lines that must be ignored
printf '%s\n' '{"type":"user","message":{"content":"hi"}}'   >> "$F1/projA/a.jsonl"
printf '%s\n' '{"type":"assistant","message":{}}'            >> "$F1/projA/a.jsonl"

# F2: duplicate requestId, IDENTICAL usage (multi content-block) -> count once
F2="$WORK/f2"; mkdir -p "$F2/p"
emit_record "$F2/p/d.jsonl" $((NOW-3600)) 1000 0 req_dup false
emit_record "$F2/p/d.jsonl" $((NOW-3600)) 1000 0 req_dup false
emit_record "$F2/p/d.jsonl" $((NOW-3600)) 1000 0 req_dup false

# F3: duplicate requestId, DIFFERING usage across copies -> keep MAX (1500)
F3="$WORK/f3"; mkdir -p "$F3/p"
emit_record "$F3/p/e.jsonl" $((NOW-3600)) 500  0 req_x false
emit_record "$F3/p/e.jsonl" $((NOW-3600)) 1500 0 req_x false

# F4: one main (1000) + one sidechain (4000), distinct requestIds, both in 5h
F4="$WORK/f4"; mkdir -p "$F4/p"
emit_record "$F4/p/m.jsonl" $((NOW-3600)) 1000 0 req_main false
emit_record "$F4/p/s.jsonl" $((NOW-3600)) 4000 0 req_side true

# F5: jsonl inside a directory whose name contains a space
F5="$WORK/f5"; mkdir -p "$F5/weird dir"
emit_record "$F5/weird dir/c.jsonl" $((NOW-3600)) 2000 0 req_space false

# F6: empty projects dir
F6="$WORK/f6"; mkdir -p "$F6"

echo "luigis-meter test suite"
echo "======================="

# --- BUG #1: script runs, prints, caches ------------------------------------
echo "[#1] set -u / ITALIC — script must run and emit"
run_meter "$F1" "$NOW" CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
[ "$RUN_ST" -eq 0 ] && ok "exit 0" || no "exit 0" "got $RUN_ST; stderr: $(cat "$WORK/err")"
[ -n "$RUN_OUT" ] && ok "stdout non-empty" || no "stdout non-empty"
[ -s "$RUN_CACHE" ] && ok "cache written" || no "cache written"
echo "$RUN_OUT" | grep -q "Never let the /usage popup surprise you." \
    && ok "tagline present (ITALIC defined)" || no "tagline present"

# --- BUG #4: weekly reset shows fixed 14:00 ---------------------------------
echo "[#4] weekly reset time is fixed 14:00, not current clock"
run_meter "$F1" "$NOW" CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
echo "$RUN_OUT" | grep -q "Fri 14:00" \
    && ok "output contains 'Fri 14:00'" || no "output contains 'Fri 14:00'" "$RUN_OUT"

# --- BUG #7: 5h countdown is monotonic non-increasing -----------------------
echo "[#7] 5h time-left does not increase as clock advances within a block"
run_meter "$F1" 1718200800 CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
M1="$(mins_left "$RUN_OUT")"
run_meter "$F1" 1718204400 CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000  # +1h
M2="$(mins_left "$RUN_OUT")"
if [ -n "$M1" ] && [ -n "$M2" ] && [ "$M2" -le "$M1" ]; then
    ok "monotonic (${M1}m -> ${M2}m)"
else
    no "monotonic" "M1=$M1 M2=$M2 (expected M2<=M1)"
fi

# --- BUG #2: dedup identical duplicate -> counted once ----------------------
echo "[#2a] duplicate requestId (identical usage) counts once"
run_meter "$F2" "$NOW" CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
# 1000 counted once -> 1% used -> 99% left
echo "$RUN_PLAIN" | grep -q "sess left: 99%" \
    && ok "1000 tok counted once (99% left)" || no "dedup identical" "$RUN_OUT"

echo "[#2b] duplicate requestId (differing usage) keeps MAX"
run_meter "$F3" "$NOW" CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
# keep-max 1500 -> 1% used (1500/100000=1.5%->1 trunc) -> 99% left; keep-min(500) would also be 99%.
# Discriminate with a tighter cap: 1500/3000=50% used -> 50% left; 500/3000=83% left.
run_meter "$F3" "$NOW" CLAUDE_MAX_5H_TOKENS=3000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
echo "$RUN_PLAIN" | grep -q "sess left: 50%" \
    && ok "keep-max 1500 (50% left at cap 3000)" || no "keep-max" "$RUN_OUT"

# --- BUG #5: sidechain toggle ------------------------------------------------
echo "[#5] sidechain included by default, excluded when toggled off"
run_meter "$F4" "$NOW" CLAUDE_MAX_5H_TOKENS=10000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
# include: (1000+4000)=5000/10000=50% used -> 50% left
echo "$RUN_PLAIN" | grep -q "sess left: 50%" \
    && ok "include default (5000 -> 50% left)" || no "sidechain include" "$RUN_OUT"
run_meter "$F4" "$NOW" CLAUDE_MAX_5H_TOKENS=10000 CLAUDE_MAX_WEEKLY_TOKENS=1000000 CLAUDE_METER_INCLUDE_SIDECHAINS=0
# exclude: 1000/10000=10% used -> 90% left
echo "$RUN_PLAIN" | grep -q "sess left: 90%" \
    && ok "exclude toggle (1000 -> 90% left)" || no "sidechain exclude" "$RUN_OUT"

# --- BUG #8: filename-safe collection ---------------------------------------
echo "[#8] jsonl in a dir with spaces is still counted"
run_meter "$F5" "$NOW" CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
[ "$RUN_ST" -eq 0 ] && [ -n "$RUN_OUT" ] \
    && ok "runs with spaced path" || no "spaced path" "st=$RUN_ST err=$(cat "$WORK/err")"
echo "$RUN_PLAIN" | grep -q "sess left: 98%" \
    && ok "2000 tok counted (98% left)" || no "spaced path count" "$RUN_OUT"

# --- BUG #3: uncalibrated defaults show 'calibrate', not a guessed % --------
echo "[#3] uncalibrated (no env limits) shows 'calibrate' not a percentage"
# NOTE: must NOT pass CLAUDE_MAX_* so the script is in default/uncalibrated mode
run_meter "$F1" "$NOW"
echo "$RUN_OUT" | grep -q "calibrate" \
    && ok "shows 'calibrate' when uncalibrated" || no "calibrate sentinel" "$RUN_OUT"
echo "[#3b] calibrated (env limits set) shows a percentage"
run_meter "$F1" "$NOW" CLAUDE_MAX_5H_TOKENS=100000 CLAUDE_MAX_WEEKLY_TOKENS=1000000
echo "$RUN_PLAIN" | grep -qE "sess left: [0-9]+%" \
    && ok "shows % when calibrated" || no "calibrated %" "$RUN_OUT"

# --- summary -----------------------------------------------------------------
echo "======================="
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
