# Changelog

All notable changes are recorded here. This project uses [semantic
versioning](https://semver.org): given `MAJOR.MINOR.PATCH`, breaking changes bump
MAJOR, new features bump MINOR, fixes bump PATCH.

## [1.0.0] — 2026-07-31

First public release.

### Added
- Menu-bar app showing Claude Code sessions from this Mac and a remote machine over
  SSH, grouped by git repo.
- **Needs approval** state — surfaces a session sitting at an unanswered permission
  prompt, sorted to the top. This is the reason the app exists.
- Background polling that keeps the menu bar badge correct without opening the panel.
- Three-valued liveness so a failed process probe can never blank the list; anything
  hidden is accounted for, with a reason, in Settings → Diagnostics.
- Notifications on the transition into *needs approval* / *your turn*, with no burst at
  launch and no repeats while a session waits.
- macOS Local Network permission priming, so the remote is reachable on first launch.
- Windows-remote support: probes for a working Python (`py` where `python3` is a Store
  stub), normalises Windows/POSIX path styles, handles the missing `tasklist` elapsed
  time.
- Offline preview renderer and two test suites (collector logic; notifier + input
  sanitisation).

### Security
- All remote-authored strings are treated as untrusted: clipboard commands are
  shell-quoted, session ids are validated at decode, control characters are stripped
  from every field. The SSH host key is not auto-trusted (`accept-new` is deliberately
  not set). See [docs/architecture.md](docs/architecture.md#security-model).

[1.0.0]: https://github.com/Shubhamgupta2612/claude-fleet/releases/tag/v1.0.0
