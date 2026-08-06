# Crow's Nest — hardening design

> Date: 2026-07-30
> Status: approved, ready for implementation planning
> Supersedes: the untested-Windows narrative in `README.md` and `HANDOFF.md`

## 1. What this is

A menu-bar-only macOS app that shows every Claude Code session running on **winbox**
(a Windows 11 machine reached over SSH) and optionally on this Mac, grouped by git repo.

Its single reason to exist: **surface the session that is blocked on an unanswered
permission prompt.** A permission prompt inside a VS Code window the owner is not looking
at is invisible until they happen to switch to it. Everything else is secondary.

## 2. Why this document exists — the corrected postmortem

`HANDOFF.md` attributes v1's failure to Windows: a process check that returned nothing on
winbox, marking every session ended and filtering them all out. **That diagnosis is wrong.**

Measured on 2026-07-30 against the live machine and the installed app:

- v1's `collector.py`, run on winbox with `py`, returns **all three live sessions
  correctly** — states, models, context sizes, git branches, repo grouping.
- `tasklist` works and is fast (403 processes, ~0.35–0.55 s).
- The installed app, **with its panel open, shows sessions.**
- The installed app, **with its panel closed, spawned zero `ssh` processes in 100+
  seconds** and wrote no preferences. Its ControlMaster socket directory stayed empty.

The real defect is therefore **§7: the app does not poll unless its panel is open.** The
menu bar badge — the whole at-a-glance premise — never updates on its own. The app only
becomes correct *after* the owner has already clicked it, which is exactly when they no
longer need it.

The Windows traps are real and must be respected, but they are not what broke this.

### 2.1 Empirically established facts

Each measured on 2026-07-30, not assumed:

| Fact | Evidence |
|---|---|
| `py` is the only working interpreter on winbox | `py -V` → `Python 3.11.9`, at `C:\Windows\py.exe` |
| `python3` is a Microsoft Store stub | exits **49**, **empty stdout**, message on stderr |
| winbox is reachable | ping 9 ms; TCP 22 open; `ver` → `Windows [Version 10.0.26200.8973]` |
| `tasklist` works and is fast | 403 processes, ~0.35–0.55 s over a shared SSH connection |
| git and the registry disagree on path style | git → `E:/dev/acme-web`; cwd → `E:\dev\acme-web\agents` |
| Registry carries liveness fields | `status`, `updatedAt`, `statusUpdatedAt` present in Claude 2.1.220 |
| SSH needs no agent | `env -i ssh -o BatchMode=yes winbox` succeeds — GUI launch context is fine |
| App never polls while closed | 0 `ssh` procs / 0 control sockets over 100 s; no prefs written |
| Plan usage % has no local source | `~/.claude.json` holds only `organizationRateLimitTier`; no consumption data |

The `python3` failure shape matters: **empty stdout with a non-zero exit** is what lets the
Swift interpreter probe fall through to `py` cleanly. Had the stub written its message to
stdout, the probe would have mistaken it for real output.

## 3. Goals

1. Show which session is blocked on a permission prompt, first in the list.
2. Keep the menu bar badge correct **without the panel being opened**.
3. Group by git repo, so sessions in subfolders of one repo share a heading.
4. Never show hostnames, connection status, or error text in the main list.
5. When winbox is unreachable, show a calm empty list — no warning, no error row.
6. Look like a native Apple app.

## 4. Non-goals

- **Plan usage / quota percentage.** Researched and rejected: no `claude usage` subcommand
  or JSON mode exists; nothing writes plan consumption to disk in any documented, stable
  format; the Analytics API that exposes it is Enterprise-only and unavailable to a Max
  subscriber. Building against the undocumented internal endpoint `/usage` calls was
  explicitly declined — it is unversioned and would break silently, which is precisely the
  failure mode this project exists to eliminate. Per-session **context-window** percentage
  is real transcript data and stays.
- Monitoring additional machines beyond the one remote. One machine matters.
- Surfacing sessions on any external dashboard or kiosk.
- Any main window, Dock icon, or app-switcher entry.

## 5. Architecture

```
CrowsNest.app
  └── AppDelegate              owns the store; starts polling at launch
        ├── LocalNetworkPermission   primes the macOS LAN grant (§5.0)
        └── SessionStore             poll loop, publishes [RepoGroup]
              └── Collector          transport; hides all failure from the UI
                    ├── local:   /usr/bin/env <interp> collector.py
                    └── remote:  ssh winbox '<interp> - winbox'  < collector.py
                                   ControlMaster shared across polls
```

### 5.0 The macOS Local Network permission deadlock

Since macOS Sequoia, an app must hold a **Local Network** grant to contact devices
on the LAN. Terminal already holds one, so anything run from a shell works; the
app did not, and every `ssh` it spawned died with
`connect to host 192.0.2.10 port 22: No route to host`.

The trap is *why no prompt ever appeared*. macOS only shows the grant dialog when
the process performing the local-network operation is **long-lived**. The app's
`ssh` child was refused and exited in milliseconds — far too short. That is a
closed loop: no prompt, so no permission, so every connection fails, forever.
(Apple's developer forums document this directly.)

**Fix:** `Sources/LocalNetworkPermission.swift` opens an `NWConnection` to the
host **from the app process itself** and holds it open for several seconds at
launch — long enough for macOS to offer the dialog. Granted once, every
subsequent `ssh` succeeds. `NSLocalNetworkUsageDescription` is required in the
Info.plist for the prompt to be permitted at all.

Note the probe qualifies the host as `<host>.local`: `NWConnection`'s resolver
cannot see SSH-config-only aliases, so a bare `winbox` sits in `.waiting` forever
and never touches a LAN device. This affects the probe only — `ssh` continues to
use the alias and its own config.

#### What this cost, and the lesson

Four wrong root causes were pursued first — a stale TCC entry, `LSUIElement`
suppressing the dialog, `ProcessType: Background`, and the agent's label sharing
the app's bundle-ID prefix. Each was tested and disproved. An entire LaunchAgent
architecture was built and then reverted on the false premise that user agents
were exempt; they are not (only **root** daemons are), and being short-lived an
agent can never trigger the prompt either — it only ever worked by borrowing a
`ControlMaster` socket another process had opened.

**That borrowed socket is the whole lesson.** `ControlPersist=300` meant any test
run within five minutes of a manual `ssh` silently succeeded, which read exactly
like intermittent networking and sent the investigation chasing ghosts. Any test
of a *new* connection must first run `ssh -O exit <host>` and clear the control
path, or it proves nothing.

| Context | Cold connection to winbox |
|---|---|
| Interactive shell | ✅ (Terminal holds the grant) |
| App bundle, before the grant | ❌ refused, no prompt possible |
| App bundle, after the grant | ✅ 6 sessions across 3 repos, `error: none` |
| User LaunchAgent | ❌ (borrowed sockets only) |

`collector.py` is stdlib-only, bundled in `Contents/Resources`, and **piped to winbox over
stdin**. Nothing is installed on winbox and nothing needs to be kept in sync there.

Output is bracketed with `<<<CROWSNEST>>> … <<<END>>>` so a login banner cannot corrupt
the parse. This framing also distinguishes *"ran fine, no sessions"* from *"wrong
interpreter"* — the distinction the interpreter probe depends on.

### 5.1 Data sources, per machine

| Source | Path | Provides |
|---|---|---|
| Registry | `~/.claude/sessions/<pid>.json` | `sessionId`, `cwd`, `pid`, `startedAt`, `version`, `name`, `status`, `updatedAt` |
| Transcript | `~/.claude/projects/<slug>/<sessionId>.jsonl` | state, model, context tokens, git branch, real cwd |

Transcripts are **never read whole** — they run to tens of megabytes. The collector seeks
to `size - 65536`, discards the partial first line, and parses forward. This matters most
on the remote machine.

## 6. State derivation

The last **conversational** record decides state. Records of type `mode`, `ai-title`,
`last-prompt`, `attachment`, `file-history-snapshot`, `queue-operation` and
`permission-mode` are bookkeeping and are ignored. Only `assistant` and `user` count.

State combines that record with transcript mtime (`fresh` = modified < 90 s ago):

| Last record | Fresh? | State |
|---|---|---|
| assistant, `stop_reason: end_turn` | — | **waiting** (Your turn) |
| assistant, `stop_reason` in max_tokens/stop_sequence/refusal | — | **waiting** |
| assistant, wanted a tool | yes | **working** |
| assistant, wanted a tool | no | **blocked** ← the permission prompt |
| user, contains `tool_result` | yes | **working** |
| user, contains `tool_result` | no | **blocked** |
| user, plain prompt | yes | **working** |
| user, plain prompt | no | **blocked** |

### 6.1 Idle decay — changed from v1

v1 exempted `waiting` from decay (`if age > IDLE_SECS and state != "waiting"`), so a
session finished three days ago stayed bright yellow **and kept counting in the badge**.
With ~10 sessions across ~5 repos the badge would drift toward counting abandoned work.

**Decision: `waiting` decays, `blocked` never does.** Past `IDLE_SECS` (2 h) a `waiting`
session becomes `idle`, grey and de-emphasised. The badge counts only `blocked` +
`waiting`, so it means *"needs me now"*.

`blocked` is deliberately exempt, and the asymmetry is the point. *"Your turn"* genuinely
goes stale — the owner finished and walked away. *"Needs approval"* does not: the session
is stuck at an unanswered permission prompt and only the owner can unstick it. Three hours
later that is still true, so fading it grey and dropping it from the badge would hide the
single thing this app exists to surface.

This is safe because **abandonment is already handled by liveness** (§8): if the terminal
is closed the process dies, the verdict is `dead`, and the session is hidden outright. So a
session still displaying `blocked` has a live process genuinely waiting on a human.

Caught during implementation, 2026-07-31: the first cut decayed every state at 2 h, so a
prompt left over lunch went grey, left the badge, and sorted to the bottom.

## 7. Background polling — the defect that actually broke this

### 7.1 The bug

`SessionStore` is a `@StateObject` on the `App` struct, and its polling timer is created in
`init()`. With a `MenuBarExtra`-only scene, SwiftUI does not construct that object until it
needs to materialise the scene's content — so **polling begins when the panel is first
opened and stalls while it is closed.**

Consequences, all fatal to the stated purpose:

- The badge does not update in the background; it is stale or absent until clicked.
- Notifications (§11) could never fire, since nothing polls to observe a transition.
- The app appears empty or wrong precisely when it is being glanced at.

A second, related hazard: `Timer.scheduledTimer` installs in the run loop's `.default`
mode, which does **not** fire while a menu or panel is being tracked. Even once polling
starts it can silently stall during interaction.

### 7.2 The fix

- Own the store from an **`NSApplicationDelegateAdaptor`**, and start polling in
  `applicationDidFinishLaunching`. Lifecycle then depends on the *application*, not on
  whether SwiftUI has drawn a panel.
- Schedule the timer explicitly in **`.common`** run-loop mode so panel interaction cannot
  stall it.
- Make the in-flight guard **self-healing**: v1's `guard task == nil else { return }` means
  one hung poll wedges every future poll forever. Bound each poll at `max(30 s, 2 ×
  interval)`, after which the task is abandoned and the guard cleared, so a stuck transport
  costs one cycle rather than the rest of the session. SSH already carries
  `ConnectTimeout=6`; this covers the case where the connection succeeds and then stalls.

**Acceptance for this section is behavioural, not visual:** with the panel never opened,
the app must spawn a collector process on schedule. Verified by observing `ssh` processes
or the ControlMaster socket over several intervals — the exact measurement that exposed the
bug.

## 8. Liveness — a latent second failure

### 8.1 The bug

v1's `collect()` does:

```python
alive = False
if pid in pids:          # pids == {} when the probe fails
    ...
if not alive:
    entry["state"] = "ended"
```

and the Swift `group()` drops every `.ended` session. So **an unavailable process table is
indistinguishable from "every process died"** → every session ended → every session
filtered → empty list, no error anywhere.

`tasklist` works reliably today, so this is latent rather than firing. It is exactly the
failure `HANDOFF.md` describes, and it must be made structurally impossible regardless.

### 8.2 The fix — three-valued liveness

| Verdict | Condition | Consequence |
|---|---|---|
| `live` | pid in a **successfully read** table (POSIX: elapsed also matches `startedAt` within 180 s) | show |
| `dead` | table read **successfully** and pid absent | may be hidden |
| `unknown` | table unavailable, timed out, or empty | **show**; fall back to `updatedAt` |

Two rules make the failure impossible:

1. **Only a positive `dead` verdict may hide a session.** `unknown` never hides anything.
2. **An empty process table alongside existing registry files is `unknown`, not all-dead.**
   A machine running Claude always has at least one process, so "zero processes" means the
   probe failed.

The POSIX pid-reuse guard compares *elapsed* time against `startedAt` rather than absolute
timestamps, so no timezone reconciliation is needed. Windows `tasklist` reports no elapsed
time, so the guard is unavailable there and the verdict falls back to registry `updatedAt`
staleness — a better liveness signal than the pid anyway.

### 8.3 Accountability for anything hidden

The brief requires: *"If you filter anything out of the view, make sure you can prove why
each thing was filtered."*

The collector emits, alongside `sessions`, a `hidden` list of `{session_id, reason}` and a
`collected` count. Settings → Diagnostics renders:

```
12 collected · 2 hidden
  • pid 16064 gone (registry stale 4h)
  • pid 28356 gone (registry stale 1d)
```

Filtering becomes auditable rather than aspirational. This never appears in the main list.

## 9. Path handling

git returns POSIX-style paths even on Windows (`E:/dev/acme-web`); the registry
records native ones (`E:\dev\acme-web\agents`). v1 compares them raw:

```python
if root and cwd and cwd.startswith(root):   # always False on Windows
```

so `rel_path` is **always empty on winbox**, silently defeating "show the path within the
repo" for every subfolder session.

Grouping itself survives — git normalises a repo root and its subfolders to the same
string, so they land in one bucket — but the row cannot say which subfolder it is in.

**Fix:** normalise before comparing — backslashes to forward slashes, casefold the drive
letter, strip trailing separators. Compare normalised; keep the original native path for
display and Copy Path.

## 10. Grouping, sorting and interface

- Repo root from `git -C <cwd> rev-parse --show-toplevel`, falling back to `cwd`; cached
  per cwd within a run.
- Sessions sort by state rank (`blocked` < `waiting` < `working` < `unknown` < `idle`),
  then recency. Repos sort by their worst session, so a blocked repo floats to the top.

Menu bar: an SF Symbol reflecting the worst state, plus a count of `blocked` + `waiting`.

Each row: a 7 pt state dot, session name, age, state label, and quiet secondary metadata
(`model · context · branch`). Hover reveals a subtle background; the tooltip carries the
state reason. Right-click offers **Copy Resume Command** and **Copy Path**.

Empty state: `moon.zzz`, "No active sessions". Calm, no diagnostics, no explanation.

The main list contains **no hostname, no connection status, no error text** under any
condition. Transport failure lands in `lastError`, which only Settings reads.

Settings: machine alias (default `winbox`), "Include this Mac" toggle, refresh interval
(5 s / 15 s / 30 s / 1 min, default 15 s), and the Diagnostics block from §8.3.

## 11. Notifications

Fire only on the **transition into** `blocked` or `waiting`, keyed by `sessionId`.

The first poll after launch seeds the previous-state map **without notifying** — otherwise
launching with eight blocked sessions produces eight notifications at once, explicitly
unwanted. A session sitting in `blocked` never re-notifies; it must leave and re-enter.

Requested via `UNUserNotificationCenter`, authorization requested once on first launch.

This feature is **dependent on §7** — without background polling it can never fire.

## 12. Build and packaging

`build.sh` is already correct and is not being changed:

- `swiftc` compiles `Sources/*.swift`; no `.xcodeproj`.
- The bundle is assembled in `mktemp -d`, **outside** the iCloud-synced Desktop tree,
  because the file provider re-attaches `com.apple.FinderInfo` between `xattr -cr` and
  `codesign`, which codesign then rejects. Building outside the synced tree removes the
  race rather than fighting it.
- Signed with `Apple Development: you@example.com (TEAMID)`, installed to
  `~/Applications` with `ditto`, which preserves the signature where `cp -R` does not.
- `LSUIElement: true` — menu bar only.

Login-at-start is **documented, not silently configured**:
System Settings → General → Login Items → **+** → `~/Applications/CrowsNest.app`.

## 13. Testing

v1 has **no version control** — that is the real gap, now closed by `git init`.

(`fixture.json` is *not* broken: `wc -l` reports 0 only because it is a single line with no
trailing newline. It is a valid 1,618-byte framed snapshot of real winbox and Mac sessions.)

The offline preview harness works and is the UI verification surface:

```bash
swiftc -O -parse-as-library -DPREVIEW -target arm64-apple-macos14.0 \
    -o /tmp/cfpreview Sources/*.swift && /tmp/cfpreview fixture.json /tmp/panel.png dark
```

Verified 2026-07-30: renders a 680×522 PNG, two repo groups, correct states and metadata.

- Extend the fixture set with a **blocked** session and a **subfolder** session, so the two
  states that matter most are rendered offline rather than waited for.
- Headless collector tests over synthetic `.claude` trees covering:
  1. Windows-style paths → `rel_path` resolves correctly.
  2. Empty/failing process table → sessions **shown**, never `ended`.
  3. Session in a repo subfolder → grouped with its root, subfolder path displayed.
  4. Stale registry `updatedAt` → correctly classified without a process table.
- Behavioural test for §7: panel never opened, collector still runs on schedule.

Tests 2 and the §7 behavioural test are the regressions that define this project. Both must
fail against v1's logic.

## 14. Acceptance criteria

- [ ] Menu bar badge shows sessions needing attention **and updates without opening the panel**.
- [ ] Opening the panel shows sessions grouped by repo, with winbox's sessions present.
- [ ] Sessions in different subfolders of one repo appear under a single repo heading,
      each showing its subfolder path.
- [ ] A session at a permission prompt shows **Needs approval** and sorts to the top.
- [ ] No hostname, connection status, or error text anywhere in the main list.
- [ ] With winbox unreachable, the list is simply empty and calm.
- [ ] Anything hidden is accounted for, with a reason, in Settings → Diagnostics.
- [ ] A session entering *needs approval* notifies once; no burst at launch.
- [ ] Looks like a native Apple app in light and dark mode.
