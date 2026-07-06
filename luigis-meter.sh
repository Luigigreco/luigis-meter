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
#   CLAUDE_MAX_5H_TOKENS       default 120000000   (weighted tokens per 5h block, Max 20x)
#   CLAUDE_MAX_WEEKLY_TOKENS   default 1200000000  (weighted tokens per week,     Max 20x)
#   CLAUDE_FABLE_WEEKLY_TOKENS default 289000000   (weighted tokens/week for claude-fable-5 only;
#                                                    calibrated 2026-07-06, ~50% used at 144M observed)
#
# Testability / configuration seams:
#   CLAUDE_PROJECTS_DIR      override the transcripts root (default ~/.claude/projects)
#   CLAUDE_NOW_EPOCH         override "now" (epoch seconds) for deterministic runs/tests
#   CLAUDE_WEEKLY_RESET_DOW  weekly reset weekday, 1=Mon..7=Sun (default 7 = Sunday)
#   CLAUDE_WEEKLY_RESET_HHMM weekly reset time HH:MM local (default "14:59")
#
# Defaults tuned from real Max 20x user data. See docs/CALIBRATION.md
# for how to retune to your own plan and workload.
#
# KNOWN LIMITATION: the session (5h) estimate is reconstructed purely from
# local ~/.claude/projects transcripts. Anthropic meters quota account-wide,
# including cross-surface usage that writes NO local transcript (cloud-
# scheduled agents/routines, claude.ai web, mobile, Desktop app). This gauge
# can therefore diverge from the official /usage popup, which remains ground
# truth — this tool is a local estimate, not an authoritative source.
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
FABLE_WEEKLY_TOKENS="${CLAUDE_FABLE_WEEKLY_TOKENS:-289000000}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
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
# Injectable clock: lets tests pin "now" for deterministic output. All
# time-of-day / weekday logic (weekly reset included) derives from $NOW,
# never from independent live `date` calls.
NOW="${CLAUDE_NOW_EPOCH:-$(date +%s)}"
WEEK_START=$(( NOW - 7 * 86400 ))   # 7d ago

# --- Collect JSONL files modified in the last 7 days ---
FILES=$(find "$PROJECTS_DIR" -name "*.jsonl" -mtime -7 2>/dev/null)

if [ -z "$FILES" ]; then
    SUM_5H=0
    SUM_WEEK=0
    BLOCK_START_TS=0
    SUM_FABLE_WEEK=0
else
    # jq streaming: emit "<epoch>\t<weighted_tokens>\t<model>" for every
    # assistant record with a usage field. Weighted like real billing so
    # cache reads (often 99% of raw volume) do not saturate the gauge:
    #   input + output + 1.25*cache_creation + 0.10*cache_read
    # The model column feeds the separate Fable gauge (FIX B) without a
    # second file scan.
    READ_DATA=$(echo "$FILES" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | jq -rc '
        select(.type == "assistant") | select(.message.usage | type == "object") |
        [
            (.timestamp // "" | if . == "" then 0 else (. | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end),
            (((.message.usage.input_tokens // 0)
              + (.message.usage.output_tokens // 0)
              + 1.25 * (.message.usage.cache_creation_input_tokens // 0)
              + 0.10 * (.message.usage.cache_read_input_tokens // 0)) | round),
            (.message.model // "")
        ] | @tsv
    ' 2>/dev/null)

    SUM_5H=0
    SUM_WEEK=0
    BLOCK_START_TS=0
    SUM_FABLE_WEEK=0
    if [ -n "$READ_DATA" ]; then
        # Block segmentation, matching Anthropic semantics: a 5h block
        # starts at the FIRST message after the previous block expired,
        # anchored at that message's EXACT epoch (not floored to the top
        # of the hour). Flooring re-anchored on every 5h rollover, which
        # could chain-drift the effective block start by >4h and silently
        # discard early-block usage into an "expired" block — undercounting
        # the current block's real usage by as much as ~4.9x. A rolling
        # lookback (using "5h ago" as the anchor) has the opposite failure:
        # it pins the countdown at "0h 0m left" under continuous use — that
        # was the ORIGINAL bug this segmentation was built to fix. Anchoring
        # on the exact epoch of the first message in the block avoids both.
        AGG=$(echo "$READ_DATA" | sort -n | awk -v week="$WEEK_START" '
        BEGIN { sw=0; bstart=0; bsum=0; swf=0 }
        $1 >= week {
            if (bstart == 0 || $1 >= bstart + 18000) {
                bstart = $1;  # anchor = exact epoch, no flooring
                bsum = 0;
            }
            sw += $2;
            bsum += $2;
            if ($3 == "claude-fable-5") { swf += $2; }
        }
        END { printf "%.0f %.0f %d %.0f\n", bsum, sw, bstart, swf }
        ')
        SUM_5H=$(echo "$AGG" | awk '{print $1}')
        SUM_WEEK=$(echo "$AGG" | awk '{print $2}')
        BLOCK_START_TS=$(echo "$AGG" | awk '{print $3}')
        SUM_FABLE_WEEK=$(echo "$AGG" | awk '{print $4}')
    fi
fi

# If the last block already expired (no messages since), the session
# gauge starts fresh: its tokens belong to a dead block.
if [ "$BLOCK_START_TS" -gt 0 ] && [ "$NOW" -ge "$(( BLOCK_START_TS + 5 * 3600 ))" ]; then
    SUM_5H=0
    BLOCK_START_TS=0
fi

# --- Compute remaining percentages ---
PCT_5H_USED=$(awk -v s="$SUM_5H" -v m="$MAX_5H_TOKENS" 'BEGIN { printf "%d", (m > 0 ? s*100/m : 100) }')
PCT_WEEK_USED=$(awk -v s="$SUM_WEEK" -v m="$MAX_WEEKLY_TOKENS" 'BEGIN { printf "%d", (m > 0 ? s*100/m : 100) }')
PCT_5H=$(( 100 - PCT_5H_USED ))
if [ "$PCT_5H" -lt 0 ]; then PCT_5H=0; fi
PCT_WEEK=$(( 100 - PCT_WEEK_USED ))
if [ "$PCT_WEEK" -lt 0 ]; then PCT_WEEK=0; fi

# Fable-5 gauge: separate weekly cap, same billing-weighted formula,
# restricted to records where .message.model == "claude-fable-5".
PCT_FABLE_USED=$(awk -v s="$SUM_FABLE_WEEK" -v m="$FABLE_WEEKLY_TOKENS" 'BEGIN { printf "%d", (m > 0 ? s*100/m : 100) }')
PCT_FABLE=$(( 100 - PCT_FABLE_USED ))
if [ "$PCT_FABLE" -lt 0 ]; then PCT_FABLE=0; fi
if [ "$PCT_FABLE" -gt 100 ]; then PCT_FABLE=100; fi

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

# --- Reset weekly: configurable weekday + HH:MM, derived from $NOW ---
# Anthropic uses a rolling 7-day window under the hood, but the /usage popup
# displays "Resets <Day> HH:MM" so we mirror that format for familiarity.
# CLAUDE_WEEKLY_RESET_DOW/HHMM let this be retargeted (e.g. a plan whose
# quota actually resets on a different day/time than the default).
#
# Cross-platform epoch formatting/parsing: BSD `date -r`/`-j -f` (macOS)
# with GNU `date -d` fallback. Everything below derives from $NOW, never
# from a fresh independent `date` call, so CLAUDE_NOW_EPOCH fully controls
# the result.
fmt_epoch() {
    # fmt_epoch <epoch> <date-format>
    date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null
}
parse_datetime() {
    # parse_datetime "YYYY-MM-DD HH:MM:SS" -> epoch
    date -j -f "%Y-%m-%d %H:%M:%S" "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null
}

WEEKLY_RESET_DOW="${CLAUDE_WEEKLY_RESET_DOW:-7}"      # 1=Mon .. 7=Sun, default Sun
WEEKLY_RESET_HHMM="${CLAUDE_WEEKLY_RESET_HHMM:-14:59}"

CURR_DOW=$(fmt_epoch "$NOW" "+%u")                    # 1=Mon .. 7=Sun
TODAY_STR=$(fmt_epoch "$NOW" "+%Y-%m-%d")
TARGET_TODAY_EPOCH=$(parse_datetime "${TODAY_STR} ${WEEKLY_RESET_HHMM}:00")

DAYS_TO_TARGET=$(( (WEEKLY_RESET_DOW - CURR_DOW + 7) % 7 ))
if [ "$DAYS_TO_TARGET" -eq 0 ] && [ "$NOW" -ge "$TARGET_TODAY_EPOCH" ]; then
    DAYS_TO_TARGET=7  # today IS the target weekday but the reset time already passed
fi
RESET_WEEK_EPOCH=$(( TARGET_TODAY_EPOCH + DAYS_TO_TARGET * 86400 ))

RESET_WEEK_LABEL=$(LC_ALL=C fmt_epoch "$RESET_WEEK_EPOCH" "+%a")
if [ -z "$RESET_WEEK_LABEL" ]; then
    RESET_WEEK_LABEL="Sun"
fi
RESET_WEEK_STR="${RESET_WEEK_LABEL} ${WEEKLY_RESET_HHMM}"

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
CFAB=$(color_for_pct "$PCT_FABLE")

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

OUTPUT="${BRAND} ${CYAN}⏱${RESET} sess left: ${C5H}${PCT_5H}%${RESET} (${RESET_5H_STR}) · week left: ${CWK}${PCT_WEEK}%${RESET} (reset ${RESET_WEEK_STR}) · fable: ${CFAB}${PCT_FABLE}%${RESET} · estimate ${CREDIT}"

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
