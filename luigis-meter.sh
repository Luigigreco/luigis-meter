#!/bin/bash
#
# luigis-meter.sh
#
# Local-estimate quota meter for Claude Code on Max plans.
# Reads Claude Code transcripts under ~/.claude/projects/**/*.jsonl and
# estimates how much of the 5-hour session block and the weekly quota is
# still available. NOT an authoritative source: Claude Code's built-in
# /usage popup remains the ground truth. This tool produces a calibratable
# local estimate so you can see "remaining" at a glance in your statusline.
#
# IMPORTANT: this is a LOCAL ESTIMATE, not Anthropic's real quota. Anthropic
# does not publish exact Max-plan token ceilings, so out of the box the meter
# shows "calibrate" instead of a guessed percentage. Set the env vars below to
# your own measured ceilings (see docs/CALIBRATION.md) to get percentages.
#
# Output example (calibrated):
#   "lm ⏱ sess left: 85% (≈2h 13m est.) · week left: 39% (reset Fri 14:00) · local est."
# Output example (uncalibrated):
#   "lm ⏱ sess: calibrate (≈2h 13m est.) · week: calibrate (reset Fri 14:00) · local est."
#
# Environment variables:
#   CLAUDE_MAX_5H_TOKENS      your real 5h ceiling   (unset => show "calibrate")
#   CLAUDE_MAX_WEEKLY_TOKENS  your real weekly ceiling (unset => show "calibrate")
#   CLAUDE_METER_INCLUDE_SIDECHAINS  1 (default) counts sub-agent/Task turns; 0 excludes
#   CLAUDE_METER_DEBUG        1 => print deduped raw token sums to stderr (for calibration)
#   CLAUDE_METER_PROJECTS_DIR override transcripts dir (default ~/.claude/projects)
#   CLAUDE_METER_CACHE_FILE   override cache path
#   CLAUDE_METER_NOW          override "now" epoch seconds (testing)
#
# To calibrate: when Claude Code's /usage shows ~100% used, run with
# CLAUDE_METER_DEBUG=1 and read the deduped raw sum — that IS your real ceiling.
#
# Cache: $TMPDIR/luigis-meter.cache with 30s TTL.
# Dependencies: bash, jq, awk, find, date (GNU or BSD — fallbacks included).
#
# Project: https://github.com/Luigigreco/luigis-meter
# License: MIT
#

set -u

# --- Config ---
# Calibration is OPT-IN: a value is "calibrated" only if the env var is set and
# non-empty. We deliberately do NOT ship a guessed default ceiling, because a
# guessed percentage in the statusline is indistinguishable from a real one.
CAL_5H=0; MAX_5H_TOKENS=0
if [ -n "${CLAUDE_MAX_5H_TOKENS:-}" ]; then CAL_5H=1; MAX_5H_TOKENS="$CLAUDE_MAX_5H_TOKENS"; fi
CAL_WK=0; MAX_WEEKLY_TOKENS=0
if [ -n "${CLAUDE_MAX_WEEKLY_TOKENS:-}" ]; then CAL_WK=1; MAX_WEEKLY_TOKENS="$CLAUDE_MAX_WEEKLY_TOKENS"; fi

INCLUDE_SIDECHAINS="${CLAUDE_METER_INCLUDE_SIDECHAINS:-1}"
PROJECTS_DIR="${CLAUDE_METER_PROJECTS_DIR:-$HOME/.claude/projects}"
CACHE_FILE="${CLAUDE_METER_CACHE_FILE:-${TMPDIR:-/tmp}/luigis-meter.cache}"
CACHE_TTL=30

# epoch_fmt <epoch> <date-format> — portable strftime of a given epoch (BSD||GNU)
epoch_fmt() { date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2"; }

# --- Now (seamable for tests) ---
NOW="${CLAUDE_METER_NOW:-$(date +%s)}"

# --- Cache check ---
# Skip the cache entirely when the clock is pinned (tests) to stay deterministic.
if [ -z "${CLAUDE_METER_NOW:-}" ] && [ -f "$CACHE_FILE" ]; then
    CACHE_MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    AGE=$(( NOW - CACHE_MTIME ))
    if [ "$AGE" -lt "$CACHE_TTL" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# --- Prerequisite checks ---
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi
if [ ! -d "$PROJECTS_DIR" ]; then
    exit 0
fi

# --- Time windows (epoch seconds) ---
BLOCK_START=$(( NOW - 5 * 3600 ))   # 5h ago
WEEK_START=$(( NOW - 7 * 86400 ))   # 7d ago

# --- Collect JSONL files modified in the last 7 days (filename-safe) ---
FILES=()
while IFS= read -r -d '' f; do
    FILES+=("$f")
done < <(find "$PROJECTS_DIR" -name "*.jsonl" -mtime -7 -print0 2>/dev/null)

SUM_5H=0
SUM_WEEK=0
if [ "${#FILES[@]}" -gt 0 ]; then
    # jq: emit "<epoch>\t<tokens>\t<dedup-key>\t<isSidechain>" per assistant
    # record with a usage field. Cache tokens are NOT counted (Anthropic discounts
    # cache reads in billing). The dedup key collapses the multiple jsonl lines
    # Claude Code writes per turn (one per content block: thinking/text/tool_use),
    # which all carry the SAME requestId and usage payload.
    READ_DATA=$(cat "${FILES[@]}" 2>/dev/null | jq -rc '
        select(.type == "assistant" and .message.usage != null) |
        [
            (.timestamp // "" | if . == "" then 0 else (. | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end),
            ((.message.usage.input_tokens // 0) + (.message.usage.output_tokens // 0)),
            ( if (.requestId // "") != "" then .requestId
              elif (.uuid // "") != "" then .uuid
              else "line:\(input_line_number)" end ),
            (.isSidechain // false)
        ] | @tsv
    ' 2>/dev/null)

    if [ -n "$READ_DATA" ]; then
        # awk: dedup by key keeping the MAX token sum seen for that key (10% of
        # duplicate requestIds carry differing counts where the largest is the
        # authoritative cumulative total). Then sum the per-key max into windows.
        AGG=$(printf '%s\n' "$READ_DATA" | awk -F'\t' \
              -v block="$BLOCK_START" -v week="$WEEK_START" -v incl="$INCLUDE_SIDECHAINS" '
        {
            ts=$1; tok=$2+0; key=$3; side=$4;
            if (!(key in seen)) { seen[key]=1; tsv[key]=ts; sidev[key]=side; maxv[key]=tok }
            else if (tok > maxv[key]) { maxv[key]=tok }
        }
        END {
            s5=0; sw=0;
            for (k in seen) {
                if (incl == 0 && sidev[k] == "true") continue;
                t=tsv[k]; m=maxv[k];
                if (t >= week)  sw += m;
                if (t >= block) s5 += m;
            }
            printf "%d %d\n", s5, sw;
        }')
        SUM_5H=$(printf '%s' "$AGG" | awk '{print $1}')
        SUM_WEEK=$(printf '%s' "$AGG" | awk '{print $2}')
    fi
fi

# Debug aid for calibration: emit the deduped raw sums (never cached).
if [ "${CLAUDE_METER_DEBUG:-0}" = "1" ]; then
    printf 'luigis-meter[debug] deduped 5h=%s week=%s (include_sidechains=%s)\n' \
        "$SUM_5H" "$SUM_WEEK" "$INCLUDE_SIDECHAINS" >&2
fi

# --- Compute remaining percentages (only when calibrated) ---
if [ "$CAL_5H" -eq 1 ] && [ "$MAX_5H_TOKENS" -gt 0 ]; then
    PCT_5H_USED=$(awk -v s="$SUM_5H" -v m="$MAX_5H_TOKENS" 'BEGIN { printf "%d", (s*100/m) }')
    PCT_5H=$(( 100 - PCT_5H_USED ))
    if [ "$PCT_5H" -lt 0 ]; then PCT_5H=0; fi
fi
if [ "$CAL_WK" -eq 1 ] && [ "$MAX_WEEKLY_TOKENS" -gt 0 ]; then
    PCT_WEEK_USED=$(awk -v s="$SUM_WEEK" -v m="$MAX_WEEKLY_TOKENS" 'BEGIN { printf "%d", (s*100/m) }')
    PCT_WEEK=$(( 100 - PCT_WEEK_USED ))
    if [ "$PCT_WEEK" -lt 0 ]; then PCT_WEEK=0; fi
fi

# --- Reset time for 5h block (stable, stateless anchor) ---
# Anchor the block to a FIXED 5h grid on the epoch (18000s) instead of the
# earliest in-window message. The rolling window's earliest message slides
# forward as old messages age out, which made "time left" jump UP between
# refreshes. Flooring to a fixed boundary makes the countdown monotonic.
# Tradeoff: the boundary is a UTC grid, NOT your real first-message start, so
# it can differ from Anthropic's actual block by up to ~5h — hence "est.".
BLOCK_LEN=$(( 5 * 3600 ))
BLOCK_ANCHOR=$(( (NOW / BLOCK_LEN) * BLOCK_LEN ))
RESET_5H_EPOCH=$(( BLOCK_ANCHOR + BLOCK_LEN ))
SECS_LEFT=$(( RESET_5H_EPOCH - NOW ))
if [ "$SECS_LEFT" -lt 0 ]; then SECS_LEFT=0; fi
if [ "$SECS_LEFT" -lt 60 ]; then
    RESET_5H_STR="resetting..."
else
    H_LEFT=$(( SECS_LEFT / 3600 ))
    M_LEFT=$(( (SECS_LEFT % 3600) / 60 ))
    RESET_5H_STR="≈${H_LEFT}h ${M_LEFT}m est."
fi

# --- Reset weekly: next Friday 14:00 local ---
# Mirrors the /usage popup's "Resets Fri HH:MM" format. The time is FIXED at
# 14:00 (BUG: -v+Nd shifts only the day, so hour/min must be pinned explicitly).
DOW=$(epoch_fmt "$NOW" "+%u")  # 1=Mon .. 7=Sun
if [ "$DOW" -lt 5 ]; then
    DAYS_TO_FRI=$(( 5 - DOW ))
elif [ "$DOW" -eq 5 ]; then
    CURR_HOUR=$(epoch_fmt "$NOW" "+%H")
    if [ "$CURR_HOUR" -lt 14 ]; then
        DAYS_TO_FRI=0
    else
        DAYS_TO_FRI=7
    fi
else
    DAYS_TO_FRI=$(( 12 - DOW ))  # Sat=6 → 6, Sun=7 → 5
fi
RESET_WEEK_STR=$(date -r "$NOW" -v+${DAYS_TO_FRI}d -v14H -v0M -v0S "+Fri %H:%M" 2>/dev/null || \
                 date -d "+${DAYS_TO_FRI} days 14:00:00" "+Fri %H:%M" 2>/dev/null || \
                 echo "Fri 14:00")

# --- Colors ---
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
ITALIC="\033[3m"
UNDERLINE="\033[4m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
MAGENTA="\033[35m"
WHITE="\033[37m"

color_for_pct() {
    local p=$1
    if [ "$p" -gt 50 ]; then echo "$GREEN"
    elif [ "$p" -gt 20 ]; then echo "$YELLOW"
    else echo "$RED"
    fi
}

# Per-metric display: a percentage when calibrated, else a "calibrate" hint.
if [ "$CAL_5H" -eq 1 ]; then
    C5H=$(color_for_pct "$PCT_5H")
    SESS_FIELD="sess left: ${C5H}${PCT_5H}%${RESET}"
else
    SESS_FIELD="${DIM}sess: ${YELLOW}calibrate${RESET}"
fi
if [ "$CAL_WK" -eq 1 ]; then
    CWK=$(color_for_pct "$PCT_WEEK")
    WEEK_FIELD="week left: ${CWK}${PCT_WEEK}%${RESET}"
else
    WEEK_FIELD="${DIM}week: ${YELLOW}calibrate${RESET}"
fi

# --- Build output ---
# OSC 8 hyperlinks: clickable in iTerm2, Ghostty, Kitty, VSCode terminal, WezTerm.
# Falls back to plain text in terminals without OSC 8 (e.g. Apple Terminal.app).
REPO_LINK_START="\033]8;;https://github.com/Luigigreco/luigis-meter\a"
LINK_END="\033]8;;\a"

BRAND="${REPO_LINK_START}${BOLD}${UNDERLINE}${MAGENTA}luigis-meter${RESET}${LINK_END}"
CREDIT="· ${GREEN}follow for updates: x.com/luigigreco${RESET}"

OUTPUT="${BRAND} ${CYAN}⏱${RESET} ${SESS_FIELD} (${RESET_5H_STR}) · ${WEEK_FIELD} (reset ${RESET_WEEK_STR}) · ${DIM}local est. (not /usage)${RESET} ${CREDIT}"

TAGLINE="${ITALIC}${WHITE}Never let the /usage popup surprise you.${RESET}"

# --- Write cache and print ---
{
    echo -e "$OUTPUT"
    echo -e "$TAGLINE"
} > "$CACHE_FILE"
cat "$CACHE_FILE"
exit 0
