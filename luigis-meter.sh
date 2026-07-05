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
#   "lm ⏱ sess left: 85% (2h 13m left) · week left: 39% (reset Fri 18:07) · estimate"
#
# Token accounting is BILLING-WEIGHTED, mirroring Anthropic pricing ratios:
#   weighted = input + output + 1.25*cache_creation + 0.10*cache_read
# Counting cache reads at full weight saturates the gauge on heavy days
# (cache reads are routinely 99% of raw volume) while the real /usage
# popup still shows headroom.
#
# Environment variables (override defaults in ~/.zshrc if the numbers drift
# from Claude Code's /usage popup). Units are WEIGHTED tokens:
#   CLAUDE_MAX_5H_TOKENS     default 120000000   (weighted tokens per 5h block, Max 20x)
#   CLAUDE_MAX_WEEKLY_TOKENS default 1200000000  (weighted tokens per week,     Max 20x)
#
# Defaults tuned from real Max 20x user data. See docs/CALIBRATION.md
# for how to retune to your own plan and workload.
#
# Cache: $TMPDIR/luigis-meter.cache with 30s TTL.
# Dependencies: bash, jq, awk, find, date (GNU or BSD — fallbacks included).
#
# Project: https://github.com/Luigigreco/luigis-meter
# License: MIT
#

set -u

# --- Config ---
MAX_5H_TOKENS="${CLAUDE_MAX_5H_TOKENS:-120000000}"
MAX_WEEKLY_TOKENS="${CLAUDE_MAX_WEEKLY_TOKENS:-1200000000}"
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
WEEK_START=$(( NOW - 7 * 86400 ))   # 7d ago

# --- Collect JSONL files modified in the last 7 days ---
FILES=$(find "$PROJECTS_DIR" -name "*.jsonl" -mtime -7 2>/dev/null)

if [ -z "$FILES" ]; then
    SUM_5H=0
    SUM_WEEK=0
    BLOCK_START_TS=0
else
    # jq streaming: emit "<epoch>\t<weighted_tokens>" for every assistant
    # record with a usage field. Weighted like real billing so cache reads
    # (often 99% of raw volume) do not saturate the gauge:
    #   input + output + 1.25*cache_creation + 0.10*cache_read
    READ_DATA=$(echo "$FILES" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | jq -rc '
        select(.type == "assistant") | select(.message.usage | type == "object") |
        [
            (.timestamp // "" | if . == "" then 0 else (. | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end),
            (((.message.usage.input_tokens // 0)
              + (.message.usage.output_tokens // 0)
              + 1.25 * (.message.usage.cache_creation_input_tokens // 0)
              + 0.10 * (.message.usage.cache_read_input_tokens // 0)) | round)
        ] | @tsv
    ' 2>/dev/null)

    SUM_5H=0
    SUM_WEEK=0
    BLOCK_START_TS=0
    if [ -n "$READ_DATA" ]; then
        # Block segmentation, matching Anthropic semantics: a 5h block
        # starts at the FIRST message after the previous block expired
        # (floored to the top of the hour), NOT "5h ago". A rolling
        # lookback pins the countdown at "0h 0m left" under continuous
        # use — that was the original bug.
        AGG=$(echo "$READ_DATA" | sort -n | awk -v week="$WEEK_START" '
        BEGIN { sw=0; bstart=0; bsum=0 }
        $1 >= week {
            if (bstart == 0 || $1 >= bstart + 18000) {
                bstart = $1 - ($1 % 3600);  # floor to the hour
                bsum = 0;
            }
            sw += $2;
            bsum += $2;
        }
        END { printf "%.0f %.0f %d\n", bsum, sw, bstart }
        ')
        SUM_5H=$(echo "$AGG" | awk '{print $1}')
        SUM_WEEK=$(echo "$AGG" | awk '{print $2}')
        BLOCK_START_TS=$(echo "$AGG" | awk '{print $3}')
    fi
fi

# If the last block already expired (no messages since), the session
# gauge starts fresh: its tokens belong to a dead block.
if [ "$BLOCK_START_TS" -gt 0 ] && [ "$NOW" -ge "$(( BLOCK_START_TS + 5 * 3600 ))" ]; then
    SUM_5H=0
    BLOCK_START_TS=0
fi

# --- Compute remaining percentages ---
PCT_5H_USED=$(awk -v s="$SUM_5H" -v m="$MAX_5H_TOKENS" 'BEGIN { printf "%d", (s*100/m) }')
PCT_WEEK_USED=$(awk -v s="$SUM_WEEK" -v m="$MAX_WEEKLY_TOKENS" 'BEGIN { printf "%d", (s*100/m) }')
PCT_5H=$(( 100 - PCT_5H_USED ))
if [ "$PCT_5H" -lt 0 ]; then PCT_5H=0; fi
PCT_WEEK=$(( 100 - PCT_WEEK_USED ))
if [ "$PCT_WEEK" -lt 0 ]; then PCT_WEEK=0; fi

# --- Reset time for 5h block ---
# The block closes 5h after its start regardless of how much was used.
# If the current block already expired (no messages since), there is no
# active block: show a full fresh window.
if [ "$BLOCK_START_TS" -gt 0 ] && [ "$NOW" -lt "$(( BLOCK_START_TS + 5 * 3600 ))" ]; then
    RESET_5H_EPOCH=$(( BLOCK_START_TS + 5 * 3600 ))
    SECS_LEFT=$(( RESET_5H_EPOCH - NOW ))
    if [ "$SECS_LEFT" -lt 0 ]; then
        SECS_LEFT=0
    fi
    # When reset is imminent (<60s) and the block was barely used (>90% left),
    # show "resetting..." instead of "0h 0m left" to reduce confusion.
    if [ "$SECS_LEFT" -lt 60 ] && [ "$PCT_5H" -gt 90 ]; then
        RESET_5H_STR="resetting..."
    else
        H_LEFT=$(( SECS_LEFT / 3600 ))
        M_LEFT=$(( (SECS_LEFT % 3600) / 60 ))
        RESET_5H_STR="${H_LEFT}h ${M_LEFT}m left"
    fi
else
    RESET_5H_STR="5h 0m left"
fi

# --- Reset weekly: next Friday 14:00 local ---
# Anthropic uses a rolling 7-day window under the hood, but the /usage popup
# displays "Resets Fri HH:MM" so we mirror that format for familiarity.
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

# --- Colors (input is "remaining %") ---
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
MAGENTA="\033[35m"
WHITE="\033[37m"
UNDERLINE="\033[4m"
ITALIC="\033[3m"

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
# Brand prefix: "lm" = luigis-meter (short, low footprint, still visible)
# OSC 8 hyperlinks: clickable in iTerm2, Ghostty, Kitty, VSCode terminal, WezTerm.
# Falls back to plain text in terminals without OSC 8 (e.g. Apple Terminal.app).
REPO_LINK_START="\033]8;;https://github.com/Luigigreco/luigis-meter\a"
X_LINK_START="\033]8;;https://x.com/luigigreco\a"
LINK_END="\033]8;;\a"

# Brand is clickable → opens the repo (primary discovery hook)
BRAND="${REPO_LINK_START}${BOLD}${UNDERLINE}${MAGENTA}luigis-meter${RESET}${LINK_END}"
# Credit is clickable → opens the X profile (personal brand hook)
CREDIT="· ${GREEN}follow for updates: x.com/luigigreco${RESET}"

OUTPUT="${BRAND} ${CYAN}⏱${RESET} sess left: ${C5H}${PCT_5H}%${RESET} (${RESET_5H_STR}) · week left: ${CWK}${PCT_WEEK}%${RESET} (reset ${RESET_WEEK_STR}) · estimate ${CREDIT}"

# Tagline: second row under the metrics, italic dim.
# Passive marketing on every refresh without cluttering the data line.
TAGLINE="${ITALIC}${WHITE}Never let the /usage popup surprise you.${RESET}"

# --- Write cache and print ---
{
    echo -e "$OUTPUT"
    echo -e "$TAGLINE"
} > "$CACHE_FILE"
cat "$CACHE_FILE"
exit 0
