# luigis-meter

> The Claude Code Max quota meter, live in your statusline.
> Know when you're burning fuel before you run out.

**luigis-meter** is a terminal-native quota indicator for Claude Code Max
users. It reads your local transcripts, estimates how much of your 5-hour
session and weekly Max plan quota is still available, and surfaces it right
in your statusline. No more `/usage` popup hunting.

```
my-project  |  Opus 4.6 (1M context)  |  ctx left: [████████░░] 82%
⏱ sess left: 89% (0h 47m left) · week left: 62% (reset Fri 18:07) · estimate
                                ↑
                                └── added by luigis-meter
```

## Why

Claude Code's built-in `/usage` popup is great — but it's a popup. You have
to interrupt your flow, type a command, read numbers, close it. If you work
intensely enough to hit Max plan limits, you want that information **always
visible**, not one keystroke away.

luigis-meter puts the gauge where you already look: your statusline.

## Features

- ⏱ **Session 5h remaining** — with countdown to reset
- 📅 **Weekly remaining** — with reset day/time
- 🎨 **Color-coded** — green (safe), yellow (watch), red (danger)
- 🚀 **Fast** — 30s cache, <10ms on warm reads
- 📦 **Zero runtime deps** — bash, jq, awk, find, date. Already on macOS/Linux.
- 🔧 **Calibratable** — override defaults via environment variables

## Install

### One-liner

```bash
curl -sSL https://raw.githubusercontent.com/Luigigreco/luigis-meter/main/install.sh | bash
```

This downloads `luigis-meter.sh` into `~/.claude/scripts/` and prints the
snippet to paste into your existing `~/.claude/statusline.sh`. It never
overwrites files without asking.

### Manual

```bash
mkdir -p ~/.claude/scripts
curl -o ~/.claude/scripts/luigis-meter.sh \
  https://raw.githubusercontent.com/Luigigreco/luigis-meter/main/luigis-meter.sh
chmod +x ~/.claude/scripts/luigis-meter.sh
```

Then add the following to your `~/.claude/statusline.sh`, just before the
final `echo`:

```bash
METER_LINE=$(bash ~/.claude/scripts/luigis-meter.sh 2>/dev/null)
```

And after the final `echo`:

```bash
[ -n "$METER_LINE" ] && echo -e "$METER_LINE"
```

If you don't have a `statusline.sh` yet, see `examples/statusline.sh.example`
in this repo for a minimal starting point, or look at Claude Code's
[official statusline docs](https://docs.anthropic.com/en/docs/claude-code/statusline).

## Output format

```
⏱ sess left: 89% (0h 47m left) · week left: 62% (reset Fri 18:07) · estimate
```

| Part                | Meaning                                                    |
| ------------------- | ---------------------------------------------------------- |
| `sess left: N%`     | percent of the 5-hour session block remaining              |
| `(Nh Nm left)`      | time until the current 5-hour block resets                 |
| `week left: N%`     | percent of the weekly quota remaining                      |
| `(reset Fri HH:MM)` | next weekly reset                                          |
| `estimate`          | reminder that these are local estimates, not authoritative |

Colors follow "remaining" semantics: green >50%, yellow 20-50%, red <20%.

## Calibration

The default limits are tuned for Max 20x but **they are estimates**. To
align them with Claude Code's `/usage` popup:

1. Open Claude Code and run `/usage`. Note the "used" percentages —
   for example: `session 14% used`, `weekly 54% used`.
2. At the same moment, run `luigis-meter.sh` in another terminal.
   Note its "remaining" percentages — for example: `sess left 86%` (=14% used),
   `week left 46%` (=54% used).
3. If they match within ~5%, you're fine.
4. If they diverge, tune in `~/.zshrc`:

```bash
export CLAUDE_MAX_5H_TOKENS=500000       # default: 500K
export CLAUDE_MAX_WEEKLY_TOKENS=5000000  # default: 5M
```

Rule of thumb for tuning:
`NEW_LIMIT = OLD_LIMIT × (script_used_pct / real_used_pct)`

If your script says 10% used but the popup says 14% used, multiply the
limit by 10/14 ≈ 0.71 to shrink it until they match.

## How it works

luigis-meter scans `~/.claude/projects/**/*.jsonl` (Claude Code's local
transcript files), sums `input_tokens + output_tokens` from the last 5
hours and 7 days, and divides by the quota limits.

This is **not** a connection to Anthropic's servers. It's a local estimate
based on data Claude Code already writes to disk. Quality depends on
calibration.

### What is counted

- `.message.usage.input_tokens`
- `.message.usage.output_tokens`

### What is NOT counted

- `cache_read_input_tokens` (heavily discounted in real billing)
- `cache_creation_input_tokens` (one-off, distorts short windows)
- Tool call overhead and server tool tokens (not exposed in transcripts)

Including cache tokens inflates percentages 10-20x. If you really want
raw totals, fork and flip the jq filter — it's one line.

## Limitations

- **Not authoritative**: Anthropic's `/usage` popup uses server-side data.
  This tool uses local transcripts. They can diverge.
- **Weekly reset is approximated**: Anthropic uses a rolling 7-day window.
  luigis-meter displays "next Friday" for familiarity with the popup format.
- **Limits drift over time**: If Anthropic changes Max plan quotas, the
  hardcoded defaults will go stale. Recalibrate periodically.
- **Single-tier**: Sonnet and Opus tokens are summed together. If Anthropic
  ever publishes split limits, this tool will need an update.

## Roadmap

- [ ] Homebrew tap (`brew install luigigreco/meter/luigis-meter`)
- [ ] Community-contributed calibration dataset
- [ ] Alert mode (`notify-send` when `sess left < 10%`)
- [ ] Split Sonnet / Opus counters (if Anthropic publishes split limits)

## Contributing

Calibration data is gold. If your numbers diverge from `/usage`, open an
issue with:

- Your plan (Max 5x / Max 20x / Pro)
- Real "used" percentages from `/usage`
- luigis-meter percentages at the same moment
- The env var values you tuned (if any)

This helps the community converge on realistic defaults.

## License

MIT. Use it, fork it, rebrand it. If you build something cool on top, I'd
love to hear about it: [@luigigreco](https://github.com/Luigigreco).

## Credits

- Built by [Luigi Greco](https://github.com/Luigigreco) — because the
  `/usage` popup was never enough.
- Inspired by [ccusage](https://github.com/ryoppippi/ccusage), which solves
  a different slice of the same problem.

---

_A tool from Luigi — built in a terminal, for people who live in a terminal._
