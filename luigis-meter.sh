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
# Output example:
#   "⏱ sess left: 89% (0h 47m left) · week left: 62% (reset Fri 18:07) · estimate"
#
# Environment variables (override defaults in ~/.zshrc if the numbers drift
# from Claude Code's /usage popup):
#   CLAUDE_MAX_5H_TOKENS     default 192000    (tokens per 5h block, Max 20x)
#   CLAUDE_MAX_WEEKLY_TOKENS default 3250000   (tokens per week,    Max 20x)
#
# Cache: $TMPDIR/luigis-meter.cache with 30s TTL.
# Dependencies: bash, jq, awk, find, date (GNU or BSD — fallbacks included).
#
# Project: https://github.com/Luigigreco/luigis-meter
# License: MIT
#

set -u

# --- Config ---
MAX_5H_TOKENS="${CLAUDE_MAX_5H_TOKENS:-192000}"
MAX_WEEKLY_TOKENS="${CLAUDE_MAX_WEEKLY_TOKENS:-3250000}"
PROJECTS_DIR="$HOME/.claude/projects"
CACHE_FILE="${TMPDIR:-/tmp}/luigis-meter.cache"
CACHE_TTL=30

# --- Cache check ---
if [ -f "$CACHE_FILE" ]; then
    CACHE_MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - CACHE_MTIME ))
    if [ "$AGE" -lt "$CACHE_TTL" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# --- Prerequisite checks ---
if ! command -v jq &>/dev/null; then
    exit 0
fi
if [ ! -d "$PROJECTS_DIR" ]; then
    exit 0
fi

# --- Time windows (epoch seconds) ---
NOW=$(date +%s)
BLOCK_START=$(( NOW - 5 * 3600 ))   # 5h ago
WEEK_START=$(( NOW - 7 * 86400 ))   # 7d ago

# --- Collect JSONL files modified in the last 7 days ---
# We only scan recent transcripts to avoid touching every historical file.
FILES=$(find "$PROJECTS_DIR" -name "*.jsonl" -mtime -7 2>/dev/null)

if [ -z "$FILES" ]; then
    SUM_5H=0
    SUM_WEEK=0
    FIRST_5H_TS=$NOW
else
    # jq streaming: for every assistant record with a usage field, emit
    # "<epoch>\t<tokens>" where tokens = input + output.
    # Cache tokens are NOT included — they skew percentages heavily because
    # Anthropic discounts cache reads in real billing.
    READ_DATA=$(echo "$FILES" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | jq -rc '
        select(.type == "assistant" and .message.usage != null) |
        [
            (.timestamp // "" | if . == "" then 0 else (. | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end),
            ((.message.usage.input_tokens // 0)
             + (.message.usage.output_tokens // 0))
        ] | @tsv
    ' 2>/dev/null)

    SUM_5H=0
    SUM_WEEK=0
    FIRST_5H_TS=$NOW
    if [ -n "$READ_DATA" ]; then
        AGG=$(echo "$READ_DATA" | awk -v block="$BLOCK_START" -v week="$WEEK_START" -v now="$NOW" '
        BEGIN { s5=0; sw=0; first=now }
        {
            ts=$1; tok=$2;
            if (ts >= week) sw += tok;
            if (ts >= block) {
                s5 += tok;
                if (ts < first) first = ts;
            }
        }
        END { printf "%d %d %d\n", s5, sw, first }
        ')
        SUM_5H=$(echo "$AGG" | awk '{print $1}')
        SUM_WEEK=$(echo "$AGG" | awk '{print $2}')
        FIRST_5H_TS=$(echo "$AGG" | awk '{print $3}')
    fi
fi

# --- Compute remaining percentages ---
PCT_5H_USED=$(awk -v s="$SUM_5H" -v m="$MAX_5H_TOKENS" 'BEGIN { printf "%d", (s*100/m) }')
PCT_WEEK_USED=$(awk -v s="$SUM_WEEK" -v m="$MAX_WEEKLY_TOKENS" 'BEGIN { printf "%d", (s*100/m) }')
PCT_5H=$(( 100 - PCT_5H_USED ))
if [ "$PCT_5H" -lt 0 ]; then PCT_5H=0; fi
PCT_WEEK=$(( 100 - PCT_WEEK_USED ))
if [ "$PCT_WEEK" -lt 0 ]; then PCT_WEEK=0; fi

# --- Reset time for 5h block ---
# The block starts at the first message after BLOCK_START. If there are
# none, assume no active block and show 5h fully available.
if [ "$FIRST_5H_TS" -lt "$NOW" ] && [ "$SUM_5H" -gt 0 ]; then
    RESET_5H_EPOCH=$(( FIRST_5H_TS + 5 * 3600 ))
    SECS_LEFT=$(( RESET_5H_EPOCH - NOW ))
    if [ "$SECS_LEFT" -lt 0 ]; then
        SECS_LEFT=0
    fi
    H_LEFT=$(( SECS_LEFT / 3600 ))
    M_LEFT=$(( (SECS_LEFT % 3600) / 60 ))
    RESET_5H_STR="${H_LEFT}h ${M_LEFT}m left"
else
    RESET_5H_STR="5h 0m left"
fi

# --- Reset weekly: next Friday 14:00 local ---
# Anthropic actually uses a rolling 7-day window, but the /usage popup
# displays "Resets Fri HH:MM" so we mirror that format.
DOW=$(date +%u)  # 1=Mon .. 7=Sun
if [ "$DOW" -lt 5 ]; then
    DAYS_TO_FRI=$(( 5 - DOW ))
elif [ "$DOW" -eq 5 ]; then
    CURR_HOUR=$(date +%H)
    if [ "$CURR_HOUR" -lt 14 ]; then
        DAYS_TO_FRI=0
    else
        DAYS_TO_FRI=7
    fi
else
    DAYS_TO_FRI=$(( 12 - DOW ))  # Sat=6 → 6, Sun=7 → 5
fi
RESET_WEEK_STR=$(date -v+${DAYS_TO_FRI}d "+Fri %H:%M" 2>/dev/null || \
                 date -d "+${DAYS_TO_FRI} days" "+Fri %H:%M" 2>/dev/null || \
                 echo "Fri 14:00")

# --- Color mapping (input is "remaining %") ---
RESET="\033[0m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"

color_for_pct() {
    local p=$1
    if [ "$p" -gt 50 ]; then echo "$GREEN"
    elif [ "$p" -gt 20 ]; then echo "$YELLOW"
    else echo "$RED"
    fi
}
C5H=$(color_for_pct "$PCT_5H")
CWK=$(color_for_pct "$PCT_WEEK")

# --- Build output ---
OUTPUT="${CYAN}⏱${RESET} sess left: ${C5H}${PCT_5H}%${RESET} ${DIM}(${RESET_5H_STR})${RESET} ${DIM}·${RESET} week left: ${CWK}${PCT_WEEK}%${RESET} ${DIM}(reset ${RESET_WEEK_STR}) · estimate${RESET}"

# --- Write cache and print ---
echo -e "$OUTPUT" > "$CACHE_FILE"
cat "$CACHE_FILE"
exit 0
