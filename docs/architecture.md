# Architecture

Two layers with a clean seam between them: a **collector** that turns files on a
machine into one JSON document, and an **app** that renders those documents in the
menu bar. The seam is a framed JSON blob, so either side can be understood and tested
without the other.

```
ClaudeFleet.app (Swift / SwiftUI, menu bar only)
  └─ AppDelegate                 starts polling at launch
       ├─ LocalNetworkPermission primes the macOS LAN grant once
       └─ SessionStore           poll loop (timer), publishes [RepoGroup]
            └─ Collector          spawns the transports, hides all failure
                 ├─ local:   python3 collector.py
                 └─ remote:  ssh <host> '<interp> - <host>'  < collector.py
                                    JSON, framed  ──▶  Session / RepoGroup  ──▶  UI
```

## The collector (`collector.py`)

Stdlib-only Python, **3.6-compatible**, because it is piped over SSH stdin to whatever
machine — often Windows — and nothing may be installed there. It reads two things
Claude Code writes locally:

| Source | Path | Provides |
|---|---|---|
| Registry | `~/.claude/sessions/<pid>.json` | `sessionId`, `cwd`, `pid`, `startedAt`, `updatedAt`, `name`, `version` |
| Transcript | `~/.claude/projects/<slug>/<sessionId>.jsonl` | state, model, context tokens, git branch, real cwd |

and prints one document, bracketed so a login banner can't corrupt the parse:

```
<<<CLAUDE_FLEET>>>{"sessions": [...], "hidden": [...], "collected": N, "ok": true}<<<END>>>
```

**Transcripts are never read whole.** They run to tens of megabytes; the collector
seeks to the last 64 KB and parses backwards. This matters most over the wire.

### State derivation

The last *conversational* record (assistant or user turn — everything else is
bookkeeping) plus the transcript's mtime decides the state:

| Last record | File fresh (<90s)? | State |
|---|---|---|
| assistant, `stop_reason: end_turn` | — | **waiting** (your turn) |
| assistant, wanted a tool | yes | **working** |
| assistant, wanted a tool | no | **blocked** ← the permission prompt |
| user, `tool_result` present | yes / no | **working** / **blocked** |

Past two hours a **waiting** session decays to **idle**; **blocked never decays** — a
session stuck at a prompt still needs you three hours later, and an abandoned one is
already hidden by liveness (below). That asymmetry is deliberate.

### Liveness — three-valued, never guessing

Whether a session is still running is a verdict, not a boolean:

| Verdict | Condition | Effect |
|---|---|---|
| `live` | pid is present in a **successfully read** process table | shown |
| `dead` | table read **successfully**, pid **absent** | hidden, with a reason |
| `unknown` | table couldn't be read, or was empty | **shown** (fall back to registry heartbeat) |

**Only a positive `dead` verdict may hide a session.** A failed process probe returns
nothing, which is indistinguishable from "everything died" unless you track probe
success separately — so a failed or empty probe is `unknown`, and the session stays
visible. Everything hidden is recorded in `hidden` with a reason, surfaced in Settings →
Diagnostics, so filtering is auditable rather than silent. On Windows there is no
elapsed-time column to guard against pid reuse, so a pid that's present is simply trusted
as `live` — failing toward showing, never toward hiding.

## The app (`Sources/`)

| File | Responsibility |
|---|---|
| `ClaudeFleetApp.swift` | The `MenuBarExtra` scene + `AppDelegate`; starts polling at launch |
| `SessionStore.swift` | The poll loop, the two SSH/local transports, JSON decode, diagnostics |
| `Session.swift` | The decoded model, input sanitisation, and `Shell.quote` |
| `MenuPanel.swift` | The panel: repo sections, rows, settings, right-click actions |
| `Notifier.swift` | Fires once when a session *enters* a state that wants you |
| `LocalNetworkPermission.swift` | Holds an `NWConnection` open at launch to trigger the macOS LAN prompt |
| `PreviewRender.swift` | Offline renderer (`-DPREVIEW`) that rasterises the real panel to PNG |

### Polling lifecycle

Polling is owned by the **app delegate**, not by a `@StateObject` on the scene.
SwiftUI doesn't construct a `MenuBarExtra`'s state until it draws the panel, so a
scene-owned store would only start polling once you clicked it — exactly when the badge
is no longer useful. The delegate starts it at launch; the scene shares the same
instance so the panel observes it. The timer runs in `.common` run-loop mode so it keeps
firing while the panel is open, and a poll that overruns its budget is abandoned so one
stalled `ssh` can't wedge every future refresh.

### Grouping and sorting

Repo root comes from `git rev-parse --show-toplevel`, falling back to the working
directory for non-repo folders. Sessions sort by state (blocked < waiting < working <
idle) then recency; repos sort by their worst session, so a repo with a blocked session
floats to the top. Paths are normalised (`\`→`/`, drive-letter case) before comparison
so a Windows subfolder resolves against its git root.

## Security model

The remote machine is **semi-trusted**: everything the collector returns — `cwd`,
`repoName`, `sessionId`, branch names, `name` — is attacker-influenceable data crossing
a machine boundary into your Mac. Two consequences shape the code:

1. **Nothing from the remote becomes a shell command unquoted.** The "Copy Resume
   Command" / "Copy Path" actions build a string you paste into a terminal, so every
   interpolated value is shell-quoted (`Shell.quote`), and `sessionId` is validated
   against a plausible-id pattern at decode — a row that fails is dropped, not
   sanitised. Control characters are stripped from every free-text field on the way in,
   since they also reach tooltips and notification bodies.
2. **The SSH host key is not auto-trusted.** The app does not pass
   `StrictHostKeyChecking=accept-new`; your own `~/.ssh` config governs, so an unknown
   host fails closed rather than letting anyone on the network answer for the remote. A
   `--` separator stops a host value beginning with `-` from being read as an ssh option.

## Where state lives

- `~/.claude-fleet/cm/` — the shared SSH control socket
- `~/.claude-fleet/last-poll.log` — the last poll's diagnostics (why it failed, if it did)
- `~/.claude-fleet/local-network.log` — the LAN-permission probe's outcome
- `~/Library/Preferences/com.sleek.claude-fleet.plist` — Settings + per-host interpreter cache

No daemon, no server, no root. One process, running as you, only while you're logged in.
