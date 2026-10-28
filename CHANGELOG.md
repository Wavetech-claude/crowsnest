# Changelog

All notable changes are recorded here. This project uses [semantic
versioning](https://semver.org): given `MAJOR.MINOR.PATCH`, breaking changes bump
MAJOR, new features bump MINOR, fixes bump PATCH.

## [Unreleased]

### Changed
- **Renamed: Claude Fleet → Crow's Nest.** The old name collided head-on with two
  other projects called `claude-fleet` — both of which *orchestrate* Claude Code
  agents. This one only ever watched them, so the name was selling the wrong thing.
  The GitHub repo moved to `crowsnest`; the old URL redirects.
- Bundle identifier is now `com.atwavetech.crowsnest` (was `com.sleek.claude-fleet`).

### Breaking — local state only
Upgrading from 1.0.0 resets settings and orphans the old state directory. Nothing is
lost that isn't regenerated on the next poll, but the machine alias and refresh
interval must be re-entered in Settings.

- Preferences move: `~/Library/Preferences/com.sleek.claude-fleet.plist` →
  `com.atwavetech.crowsnest.plist`. **Settings reset to defaults.**
- State directory moves: `~/.claude-fleet/` → `~/.crowsnest/` (SSH control socket,
  `last-poll.log`, `local-network.log`).
- The app bundle is now `~/Applications/CrowsNest.app`. The old
  `ClaudeFleet.app` is not removed by `build.sh` — delete it by hand, and re-point
  your Login Item at the new bundle or it will keep launching the old one.
- The fixture environment variable is now `CROWSNEST_FIXTURE`.

To clean up after upgrading:

```bash
rm -rf ~/Applications/ClaudeFleet.app ~/.claude-fleet
defaults delete com.sleek.claude-fleet 2>/dev/null || true
```

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

[1.0.0]: https://github.com/Wavetech-claude/crowsnest/releases/tag/v1.0.0
