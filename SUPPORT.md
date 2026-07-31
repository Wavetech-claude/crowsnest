# Support

Claude Fleet is a personal tool, published as-is. Please read this before opening
an issue — it will save us both time.

## What kind of support to expect

- **Bug reports:** welcome, and genuinely useful, but may go unanswered. I fix what
  breaks for me first.
- **Feature requests:** I'm unlikely to build features for setups I don't run myself.
  A PR is far more likely to land than a request.
- **"It doesn't work on my machine":** see [troubleshooting](docs/troubleshooting.md)
  first — most cases are the macOS Local Network prompt or an SSH host that isn't yet
  trusted, both covered there.

There is no SLA, no roadmap, and no promise of a fix. That's the deal in exchange
for it being free and MIT.

## The most useful thing you can attach

When Claude Fleet can't reach a machine, it does **not** show the error in the list
(by design). It writes it to disk instead:

```bash
cat ~/.claude-fleet/last-poll.log
```

and shows it in **Settings → Diagnostics**. That one line is usually the whole
diagnosis. Please paste it into any issue, along with:

- your macOS version (`sw_vers`)
- the remote OS, if any (Windows / Linux / macOS)
- your Claude Code version (`claude --version`) — the app reads Claude's on-disk
  format, so the version matters when the format has changed

## The failure mode to expect over time

This app reads Claude Code's session registry and transcripts, which are not a public
API. A Claude Code update can change that format and break state detection for
everyone at once. If sessions suddenly all read as one state, or stop appearing,
that's the likely cause — and `last-poll.log` plus your Claude version will confirm it.
