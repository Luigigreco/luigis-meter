# Launch Announcement Draft

Copy/paste-ready content for X/Twitter, LinkedIn, and community channels.

---

## X/Twitter thread

### Tweet 1 (hook)

```
Built a tiny thing: luigis-meter — a bash script that shows your
Claude Code Max plan quota directly in the statusline.

No more hunting the /usage popup mid-flow.

lm ⏱ sess left: 85% (2h 13m left) · week left: 39% (reset Fri 14:00)

https://github.com/Luigigreco/luigis-meter
```

### Tweet 2 (reply — how it works)

```
How it works: scans ~/.claude/projects/**/*.jsonl, sums input+output
tokens from the last 5h and 7d, compares to Max 20x limits.

Zero runtime deps beyond jq. Defaults tuned from real Max 20x usage.
Calibratable via env vars for your own workload.
```

### Tweet 3 (reply — tagging the community)

```
cc @ClaudeCodeLog @tom_doerr @bcherny

If you try it and the numbers drift from /usage, please open a
calibration issue. Community data improves the defaults for everyone.

https://github.com/Luigigreco/luigis-meter/issues/new?template=calibration.yml
```

### Tweet 4 (optional reply — why this matters)

```
Why I built it: the /usage popup in Claude Code is great, but it's a
popup. If you work intensely enough to hit Max plan limits, you want
that info always visible, not one keystroke away.

A terminal-native quota gauge should just exist. Now it does.
```

---

## LinkedIn post (longer form)

```
I just shipped a small open-source tool for Claude Code power users:
luigis-meter.

The problem: Claude Code's Max plan has two quota meters — a 5-hour
session block and a weekly limit. You can check them via the /usage
popup, but only if you interrupt your flow to run the command.

The fix: a 200-line bash script that reads your local Claude Code
transcripts (~/.claude/projects/**/*.jsonl), estimates how much of each
quota is still available, and surfaces it live in your statusline.

lm ⏱ sess left: 85% (2h 13m left) · week left: 39% (reset Fri 14:00)

Key design decisions:
• Zero runtime dependencies beyond jq (already installed on most systems)
• Defaults calibrated from real Max 20x usage (5h=192K tokens, weekly=3.25M)
• Calibratable via env vars so each user can tune to their own workload
• MIT license, minimal surface area, easy to fork and customize

Limitations I'm upfront about:
• These are estimates. Anthropic's /usage popup remains the ground truth.
• Weekly reset is approximated (Anthropic uses a rolling 7-day window).
• Default limits may drift if Anthropic changes the plan.

If you use Claude Code Max and want your quota visible at all times,
give it a try:

https://github.com/Luigigreco/luigis-meter

If the numbers diverge from your /usage popup, open a calibration issue —
community data makes the defaults better for everyone.

#ClaudeCode #Anthropic #DeveloperTools #OpenSource
```

---

## Reddit post (r/ClaudeAI or r/commandline)

**Title**: `[Tool] luigis-meter — Claude Code Max quota in your statusline`

**Body**:

```
I got tired of opening the /usage popup in Claude Code to check my
remaining quota, so I built a small bash script that shows it live in
the statusline.

It parses ~/.claude/projects/**/*.jsonl (Claude Code's local transcripts),
sums input+output tokens from the last 5h and 7d, and compares them to
Max 20x plan limits. Output looks like this:

    lm ⏱ sess left: 85% (2h 13m left) · week left: 39% (reset Fri 14:00)

Green/yellow/red color coding, 30s cache, zero runtime deps beyond jq.
Defaults are tuned from real Max 20x usage data, and they're overridable
via env vars if your workload differs.

Repo: https://github.com/Luigigreco/luigis-meter

MIT license. Install is a one-liner. Works on macOS and Linux.

It's a local estimate, not authoritative — the /usage popup is still the
ground truth — but it gets within 2% on my setup. If you try it and the
numbers drift, there's a calibration issue template to share your tuned
values.

Feedback welcome.
```

---

## Dev.to / Medium tagline suggestions

- "Never hunt the /usage popup again — a 200-line bash script for Claude Code power users"
- "luigis-meter: a terminal-native quota gauge for Claude Code Max"
- "I built a statusline gauge for Claude Code because the /usage popup was never enough"

---

## Hacker News (if you go there, keep it restrained)

**Title**: `Show HN: luigis-meter – Claude Code Max quota in your statusline`

**First comment**:

```
Author here. Quick context:

I use Claude Code on the Max 20x plan and the built-in /usage popup was
the only way to know how much of my 5h session / weekly quota I had left.
That meant interrupting my flow every time I wanted to check.

luigis-meter is a 200-line bash script that reads the local JSONL
transcripts Claude Code writes to ~/.claude/projects/, sums input+output
tokens for the 5h and 7d windows, and compares them to hardcoded Max 20x
limits I calibrated from real usage.

It's explicitly a local estimate — the /usage popup uses server-side data
this tool can't access. But it gets within 2% on my setup, and it's
trivially calibratable via env vars.

Zero deps beyond jq. MIT. Happy to discuss trade-offs or alternatives.
```

---

## Notes for Luigi

- All drafts above assume `@bcherny` is Boris Cherny's X handle. **Please verify before tagging.** If it's different, search/replace.
- The thread order matters on X: tweet 1 must contain the repo URL to be shareable; tweets 2-4 are optional.
- LinkedIn version is longer because the platform rewards thoughtful long-form. Keep it to 1 post, not a series.
- Reddit: post on r/ClaudeAI first (smaller, more niche), wait for feedback, then r/commandline (larger, more critical).
- HN: optional, only if you're ready for critical comments. The community there will dissect the approach.
- Post timing: **Tuesday or Wednesday morning EU time** (09:00-11:00 CET) for best reach on X / LinkedIn. Avoid weekends.
