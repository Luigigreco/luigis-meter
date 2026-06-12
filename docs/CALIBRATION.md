# Calibration Guide

luigis-meter estimates Claude Code Max plan quota from local transcripts.
**It ships no guessed defaults**: until you set your own ceilings it shows
`calibrate` instead of a percentage, because Anthropic does not publish exact
Max-plan token limits and a made-up number would only look authoritative.

This guide shows how to find your real `CLAUDE_MAX_5H_TOKENS` and
`CLAUDE_MAX_WEEKLY_TOKENS` values from your own usage.

## Prerequisites

- luigis-meter installed and working
- `jq` available, and an active Claude Code session with recent usage

## Method A — Ceiling-capture (recommended)

The most robust calibration reads your real ceiling directly off your own data,
at the moment it matters most: when you're near the limit.

1. Use Claude Code normally until `/usage` shows the **session at or near 100%
   used** (the highest you'll see before reset).
2. At that moment, run the meter in debug mode:

   ```bash
   CLAUDE_METER_DEBUG=1 bash ~/.claude/scripts/luigis-meter.sh >/dev/null
   ```

   It prints to stderr, e.g.:

   ```
   luigis-meter[debug] deduped 5h=918432 week=8730000 (include_sidechains=1)
   ```

3. That `5h=` number **is** your real 5-hour ceiling (the deduped tokens you
   consumed to reach ~100%). Set it:

   ```bash
   export CLAUDE_MAX_5H_TOKENS=918432
   ```

4. Repeat when `/usage` **weekly** is near 100% to capture `week=` →
   `CLAUDE_MAX_WEEKLY_TOKENS`. (If you can't wait, a rough weekly placeholder is
   ~10× the 5h ceiling — but the captured number is the only accurate one.)

Calibrating at the top of the range avoids the divide-by-small-number noise that
makes the factor method (below) unreliable at low usage.

## Method B — Factor scaling (alternative)

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
⏱ sess left: B% (...) · week left: C% (...) · local est. (not /usage)
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
# Example values from the worked example above — NOT defaults. Use your own.
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
