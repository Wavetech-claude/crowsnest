# Changelog

All notable changes are recorded here. This project uses [semantic
versioning](https://semver.org): given `MAJOR.MINOR.PATCH`, breaking changes bump
MAJOR, new features bump MINOR, fixes bump PATCH.

## [Unreleased]

## [1.1.0] — 2026-10-28

A new look for the panel, built around one question: is anything waiting on me?

### Added
- **The Tiles panel.** Every session that needs you is now a full-width card at the top,
  in that state's colour, with its name in large type. The rest (Working, Idle) are
  smaller tiles, two to a row underneath. Urgency decides the order: an approval comes
  first, then your turns, wherever they are. The repo and branch are on each card rather
  than in group headers.
- **State icons.** Each state has its own icon in a filled disc (a raised hand for
  approval, a speech bubble for your turn, a bolt for working, a moon for idle), so the
  state reads by shape as well as colour.
- **Context gauge.** Each session shows how full its context window is as a bar and a
  percentage. The bar turns red at 85%, when the session is close to needing a fresh start.
- **Click to copy.** Clicking any card or tile copies its resume command
  (`cd '<dir>' && claude --resume <id>`), and the card confirms with "✓ Copied". The
  right-click menu stays, with Copy Path.
- **A contrast check.** `swift-tests/run.sh` now holds every text colour in the panel to
  4.5:1 against everything it sits on, in light, dark and both Increase Contrast
  appearances, and runs on every pull request. It caught one failure in this release
  before it shipped: grey text on the yellow card in dark mode.

### Fixed
- "Needs approval" and "Your turn" were unreadable in light mode (yellow text on white
  measured 1.41:1, orange 2.16:1, against the 4.5:1 small text needs). The words are
  now in the text colour, and the colour is on the icon and the card.
- The grey supporting text (age, model, branch) measured under 3:1 in both appearances.
  It now passes 4.5:1 everywhere.
- The refresh button was a 13 pt target with no name for VoiceOver. It is now 26 pt and
  announced as "Refresh". Each card is read out as one button: the name, the state, the
  repo and the age.

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

[1.0.0]: https://github.com/Shubhamgupta2612/crowsnest/releases/tag/v1.0.0
