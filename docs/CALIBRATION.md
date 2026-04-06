# Calibration Guide

luigis-meter estimates Claude Code Max plan quota from local transcripts.
The default limits are tuned for **Max 20x** but they are community
estimates, not official Anthropic numbers. Your actual limits may differ.

This guide shows how to tune `CLAUDE_MAX_5H_TOKENS` and
`CLAUDE_MAX_WEEKLY_TOKENS` until the meter matches Claude Code's built-in
`/usage` popup.

## Prerequisites

- luigis-meter installed and working
- An active Claude Code session with some recent usage (last 1-2 hours)

## Step 1 — Capture the ground truth

Open Claude Code, type `/usage`, and note both percentages **exactly as shown**:

```
Current session  →  X% used  ·  Resets in Yh Zm
Weekly (All)     →  A% used  ·  Resets Day HH:MM
```

Write down:

- `session_used_real` = X
- `weekly_used_real` = A

## Step 2 — Capture the meter output at the same moment

In another terminal (or via the statusline), read luigis-meter's output:

```
⏱ sess left: B% (...) · week left: C% (...) · estimate
```

Convert to "used":

- `session_used_meter` = 100 - B
- `weekly_used_meter` = 100 - C

## Step 3 — Compute the tuning factor

```
5h_factor   = session_used_meter / session_used_real
week_factor = weekly_used_meter / weekly_used_real
```

If the factor is >1, the meter is over-counting (raise the limit).
If the factor is <1, the meter is under-counting (lower the limit).

```
new_5h_limit   = current_5h_limit   × (session_used_meter / session_used_real)
new_week_limit = current_week_limit × (weekly_used_meter / weekly_used_real)
```

### Worked example

Suppose:

- `/usage` shows: session 14% used, weekly 54% used
- luigis-meter shows: `sess left 86%` (→ 14% used), `week left 38%` (→ 62% used)

Session is already aligned (14% ≈ 14%). Weekly is over-counting
(62% > 54%), so we scale up the weekly limit:

```
new_week_limit = 5_000_000 × (62 / 54) ≈ 5_740_740
```

## Step 4 — Apply the new limits

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
export CLAUDE_MAX_5H_TOKENS=500000
export CLAUDE_MAX_WEEKLY_TOKENS=5740740
```

Reload:

```bash
source ~/.zshrc
```

Clear the cache:

```bash
rm -f "${TMPDIR:-/tmp}/luigis-meter.cache"
```

Re-run `luigis-meter.sh` and compare again.

## Step 5 — Share your calibration

If your tuned values are stable over several days, **please share them**
by opening a [calibration issue](https://github.com/Luigigreco/luigis-meter/issues/new?template=calibration.yml)
with:

- Your plan tier (Max 5x / Max 20x / Pro)
- Final `CLAUDE_MAX_5H_TOKENS` value
- Final `CLAUDE_MAX_WEEKLY_TOKENS` value
- Optional: your typical workload (light refactor / heavy agentic / mixed)

The more data points we collect, the better the defaults get for everyone.

## Why can't luigis-meter just read the real numbers?

Anthropic's `/usage` popup fetches percentages from a server-side endpoint
that is not exposed to external tools. Claude Code itself passes a JSON
payload to statusline scripts via stdin, but that payload does NOT include
plan quota information — only `cost`, `context_window`, and model metadata.

Until Anthropic surfaces plan quotas in the statusline JSON, any external
tool has to estimate from local transcript data. luigis-meter is just the
simplest way to do that, not magic.
