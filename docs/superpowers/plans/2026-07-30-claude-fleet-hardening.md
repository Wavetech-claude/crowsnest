# Claude Fleet Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the menu bar badge correct without opening the panel, and make it structurally impossible for a failed process probe to blank the session list.

**Architecture:** Two independent layers. `collector.py` runs on each machine (piped over SSH stdin, stdlib-only) and owns all data derivation — liveness verdicts, path normalisation, state, and an auditable record of anything it hides. The Swift app owns lifecycle and presentation: an `NSApplicationDelegateAdaptor` starts polling at launch so it no longer depends on SwiftUI materialising a panel, and a `Notifier` fires once on transitions into states that want the owner.

**Tech Stack:** Swift 6 / SwiftUI (`MenuBarExtra`, `LSUIElement`), Python 3.6+ stdlib only, `unittest`, `swiftc` (no `.xcodeproj`), `codesign` + `ditto`.

## Global Constraints

- `collector.py` must remain **stdlib-only** and **Python 3.6-compatible** — it is piped to winbox over stdin and nothing may be installed there.
- `collector.py` must run under `py` on Windows and `python3` on macOS. Never assume `python3` exists on winbox: it is a Microsoft Store stub that exits **49** with empty stdout.
- Output must stay bracketed by `<<<CLAUDE_FLEET>>>` … `<<<END>>>`.
- Handle **both** path styles: Windows (`E:\foo\bar`, `C:\Users\you`) and POSIX.
- The main session list must never display a hostname, connection status, error text, or retry count. Diagnostics live only in Settings.
- When a machine is unreachable the list must be **empty and calm** — no warning, no error row.
- Swift target: `arm64-apple-macos14.0`. Signing identity: `Apple Development: you@example.com (TEAMID)`.
- Never assemble or sign the bundle inside `~/Desktop` (iCloud re-attaches `com.apple.FinderInfo`, which `codesign` rejects). `build.sh` already handles this — do not change it.
- Only a **positive `dead`** verdict may ever remove a session from view.

---

### Task 1: Test harness and the liveness regression

The defining regression: an unavailable process table must never be read as "everything died".

**Files:**
- Create: `tests/test_collector.py`
- Create: `tests/helpers.py`
- Modify: `collector.py` (`_live_pids_windows`, `live_pids`, `collect`)

**Interfaces:**
- Consumes: nothing.
- Produces: `live_pids() -> (dict, bool)` where the bool is `probe_ok`; `liveness_verdict(reg, pids, probe_ok, now) -> str` returning `"live" | "dead" | "unknown"`; `collect() -> (sessions, hidden)` where `hidden` is a list of `{"session_id": str, "reason": str}`.

- [ ] **Step 1: Write the test helpers**

Create `tests/helpers.py`:

```python
"""Builds synthetic ~/.claude trees so the collector can be tested offline."""

import importlib
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)


def load_collector(home):
    """Import collector.py bound to a synthetic CLAUDE_CONFIG_DIR."""
    os.environ["CLAUDE_CONFIG_DIR"] = home
    import collector
    importlib.reload(collector)
    return collector


def write_registry(home, pid, session_id, cwd, started_at=None, updated_at=None):
    d = os.path.join(home, "sessions")
    os.makedirs(d, exist_ok=True)
    now_ms = int(time.time() * 1000)
    reg = {
        "pid": pid,
        "sessionId": session_id,
        "cwd": cwd,
        "startedAt": started_at if started_at is not None else now_ms - 60000,
        "version": "2.1.220",
        "kind": "interactive",
        "entrypoint": "cli",
        "name": "test-%s" % pid,
    }
    if updated_at is not None:
        reg["updatedAt"] = updated_at
    with open(os.path.join(d, "%d.json" % pid), "w") as fh:
        json.dump(reg, fh)


def write_transcript(home, slug, session_id, records, age_secs=0):
    """Write a .jsonl transcript and backdate its mtime by age_secs."""
    d = os.path.join(home, "projects", slug)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "%s.jsonl" % session_id)
    with open(path, "w") as fh:
        for rec in records:
            fh.write(json.dumps(rec) + "\n")
    if age_secs:
        when = time.time() - age_secs
        os.utime(path, (when, when))
    return path


def assistant_end_turn(cwd="/tmp/repo", branch="main"):
    return {
        "type": "assistant",
        "cwd": cwd,
        "gitBranch": branch,
        "message": {
            "model": "claude-opus-5",
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 1000, "cache_read_input_tokens": 2000},
            "content": [{"type": "text"}],
        },
    }


def assistant_wants_tool(cwd="/tmp/repo", branch="main"):
    return {
        "type": "assistant",
        "cwd": cwd,
        "gitBranch": branch,
        "message": {
            "model": "claude-opus-5",
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 1000, "cache_read_input_tokens": 2000},
            "content": [{"type": "tool_use"}],
        },
    }
```

- [ ] **Step 2: Write the failing liveness tests**

Create `tests/test_collector.py`:

```python
import os
import shutil
import tempfile
import time
import unittest

from helpers import (assistant_end_turn, assistant_wants_tool, load_collector,
                     write_registry, write_transcript)


class LivenessTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.cwd = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)
        shutil.rmtree(self.cwd, ignore_errors=True)

    def _seed(self, pid=4242):
        sid = "aaaa-bbbb-cccc"
        write_registry(self.home, pid, sid, self.cwd,
                       updated_at=int(time.time() * 1000))
        write_transcript(self.home, "-tmp-repo", sid,
                         [assistant_end_turn(cwd=self.cwd)])
        return sid

    def test_failed_probe_never_hides_a_session(self):
        """The regression that blanked the list: an unavailable process table
        must read as 'unknown', never as 'everything died'."""
        col = load_collector(self.home)
        self._seed()
        col.live_pids = lambda: ({}, False)      # probe failed
        sessions, hidden = col.collect()
        self.assertEqual(len(sessions), 1)
        self.assertEqual(hidden, [])
        self.assertNotEqual(sessions[0]["state"], "ended")

    def test_empty_table_with_registry_present_is_unknown(self):
        """A machine running Claude always has >=1 process, so zero processes
        means the probe failed even if it claimed success."""
        col = load_collector(self.home)
        self._seed()
        col.live_pids = lambda: ({}, True)
        sessions, hidden = col.collect()
        self.assertEqual(len(sessions), 1)
        self.assertEqual(hidden, [])

    def test_confirmed_dead_pid_is_hidden_with_a_reason(self):
        col = load_collector(self.home)
        sid = self._seed(pid=4242)
        col.live_pids = lambda: ({9999: 100.0}, True)   # 4242 absent
        sessions, hidden = col.collect()
        self.assertEqual(sessions, [])
        self.assertEqual(len(hidden), 1)
        self.assertEqual(hidden[0]["session_id"], sid)
        self.assertIn("gone", hidden[0]["reason"])

    def test_windows_no_elapsed_falls_back_to_updated_at(self):
        """tasklist reports no elapsed time, so the pid-reuse guard is
        unavailable and the registry heartbeat decides."""
        col = load_collector(self.home)
        self._seed(pid=4242)
        col.live_pids = lambda: ({4242: None}, True)
        sessions, hidden = col.collect()
        self.assertEqual(len(sessions), 1)
        self.assertEqual(hidden, [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ~/Desktop/Projects/claude-fleet && python3 -m unittest discover -s tests -t tests -v`

Expected: FAIL. `collect()` currently returns a bare list, so unpacking raises
`ValueError: too many values to unpack`, and `live_pids()` returns a dict rather than a tuple.

- [ ] **Step 4: Change `live_pids` to report probe success**

In `collector.py`, replace the whole of `_live_pids_windows` and `live_pids` with:

```python
def _live_pids_windows():
    """({pid: None}, probe_ok). tasklist has no elapsed-time column, so the
    pid-reuse guard is unavailable here; `None` marks 'alive, age unknown'
    and the caller skips the start-time comparison."""
    for cmd in (["tasklist", "/NH", "/FO", "CSV"],
                ["tasklist.exe", "/NH", "/FO", "CSV"]):
        try:
            out = subprocess.run(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20,
            ).stdout.decode("utf-8", "replace")
        except Exception:
            continue
        found = {}
        for line in out.splitlines():
            parts = [p.strip('" ') for p in line.split('","')]
            if len(parts) < 2:
                continue
            try:
                found[int(parts[1])] = None
            except ValueError:
                continue
        if found:
            return found, True
    return {}, False


def live_pids():
    """({pid: elapsed_seconds_or_None}, probe_ok).

    probe_ok is False when the process table could not be read at all. That
    distinction is load-bearing: without it an unreadable table is
    indistinguishable from 'every process died', which blanks the whole list.
    """
    if os.name == "nt":
        return _live_pids_windows()
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid=,etime="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
        ).stdout.decode("utf-8", "replace")
    except Exception:
        return {}, False
    found = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        bits = line.split(None, 1)
        if len(bits) != 2:
            continue
        try:
            secs = _parse_etime(bits[1])
            if secs is not None:
                found[int(bits[0])] = secs
        except Exception:
            continue
    return found, bool(found)
```

- [ ] **Step 5: Add the three-valued verdict**

In `collector.py`, insert immediately after `live_pids`:

```python
def liveness_verdict(reg, pids, probe_ok, now):
    """'live' | 'dead' | 'unknown'.

    Only 'dead' may ever hide a session. Two rules keep the empty-list
    failure impossible:
      1. A failed probe yields 'unknown', never 'dead'.
      2. An empty table alongside registry files is also 'unknown' -- a
         machine running Claude always has at least one process, so zero
         processes means the probe lied about succeeding.
    """
    if not probe_ok or not pids:
        return "unknown"

    pid = reg.get("pid")
    if pid not in pids:
        return "dead"

    elapsed = pids[pid]
    if elapsed is None:
        # Windows: no elapsed time, so no pid-reuse guard. The registry's own
        # heartbeat is a better liveness signal than the pid anyway.
        updated = reg.get("updatedAt")
        if not updated:
            return "live"
        return "live" if (now - updated / 1000.0) < STALE_REGISTRY_SECS else "dead"

    started = reg.get("startedAt")
    if not started:
        return "live"
    # Compared as elapsed time so we never reconcile timezones.
    expected = now - (started / 1000.0)
    return "live" if abs(expected - elapsed) <= PID_TOLERANCE else "dead"
```

- [ ] **Step 6: Rewrite the registry loop in `collect()`**

In `collector.py`, replace lines from `def collect():` down to and including
`sessions.append(entry)` (the end of the registry `for` loop) with:

```python
def collect():
    """Returns (sessions, hidden). `hidden` records every session removed from
    view and why, so filtering is auditable rather than silent."""
    now = time.time()
    pids, probe_ok = live_pids()
    sessions = []
    hidden = []
    seen_ids = set()

    for reg_path in sorted(glob.glob(os.path.join(SESSIONS_DIR, "*.json"))):
        try:
            with open(reg_path) as fh:
                reg = json.load(fh)
        except (OSError, ValueError):
            continue

        sid = reg.get("sessionId")
        if not sid:
            continue
        seen_ids.add(sid)

        verdict = liveness_verdict(reg, pids, probe_ok, now)
        if verdict == "dead":
            updated = reg.get("updatedAt")
            stale = _human(now - updated / 1000.0) if updated else "unknown"
            hidden.append({
                "session_id": sid,
                "reason": "pid %s gone (registry stale %s)" % (reg.get("pid"), stale),
            })
            continue

        entry = summarise_transcript(find_transcript(sid), now)
        entry.update({
            "session_id": sid,
            "pid": reg.get("pid"),
            "liveness": verdict,
            "cwd": reg.get("cwd"),
            "name": reg.get("name"),
            "version": reg.get("version"),
            # entrypoint/kind are passed through opaquely -- the UI groups by
            # whatever values actually show up rather than a hardcoded list.
            "entrypoint": reg.get("entrypoint"),
            "kind": reg.get("kind"),
            "started_at": reg.get("startedAt"),
            "source": "registry",
        })
        sessions.append(entry)
```

- [ ] **Step 7: Update the orphan loop and return signature**

In `collector.py`, in the orphan `for` loop replace the line `"alive": None,` with
`"liveness": "unknown",`. Then replace the final two lines of `collect()`:

```python
    order = {"blocked": 0, "waiting": 1, "working": 2, "unknown": 3, "idle": 4}
    sessions.sort(key=lambda s: (order.get(s.get("state"), 9), -(s.get("last_activity") or 0)))
    return sessions, hidden
```

- [ ] **Step 8: Update `main()` to emit the diagnostics**

In `collector.py`, replace the body of `main()`'s `try` block:

```python
    try:
        doc["sessions"], doc["hidden"] = collect()
        doc["collected"] = len(doc["sessions"]) + len(doc["hidden"])
    except Exception as exc:                                  # never die silently
        doc["ok"] = False
        doc["error"] = "%s: %s" % (type(exc).__name__, exc)
```

And add `"hidden": []` and `"collected": 0` to the `doc` literal alongside `"sessions": []`.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `cd ~/Desktop/Projects/claude-fleet && python3 -m unittest discover -s tests -t tests -v`

Expected: PASS, 4 tests.

- [ ] **Step 10: Verify against the live machine**

Run: `cd ~/Desktop/Projects/claude-fleet && ssh winbox "py -" < collector.py | head -c 400`

Expected: framed JSON beginning `<<<CLAUDE_FLEET>>>{"host": "winbox"...` containing real
sessions with `"liveness": "live"` and `"hidden": []`.

- [ ] **Step 11: Commit**

```bash
git add tests/ collector.py
git commit -m "fix: a failed process probe can no longer blank the session list

live_pids() now reports whether the probe actually succeeded, and
liveness_verdict() returns live/dead/unknown. Only a positive 'dead'
verdict removes a session, and every removal is recorded in 'hidden'
with a reason."
```

---

### Task 2: Path normalisation

`rel_path` is always empty on winbox because git reports `E:/dev/acme-web` while the registry reports `E:\dev\acme-web`.

**Files:**
- Modify: `collector.py` (repo/rel_path block in `collect()`)
- Modify: `tests/test_collector.py`

**Interfaces:**
- Consumes: `collect() -> (sessions, hidden)` from Task 1.
- Produces: `_norm(path) -> str` normalising to forward slashes with an upper-cased drive letter and no trailing separator.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_collector.py`:

```python
class PathTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def test_windows_rel_path_survives_slash_mismatch(self):
        """git says E:/repo, the registry says E:\\repo\\sub. Compared raw
        these never match, so the subfolder silently disappears."""
        col = load_collector(self.home)
        self.assertEqual(col._norm("E:\\dev\\acme-web"),
                         "E:/dev/acme-web")
        self.assertEqual(col._norm("E:/dev/acme-web/"),
                         "E:/dev/acme-web")

    def test_sibling_directory_is_not_treated_as_a_child(self):
        """/foo/barbaz must not be read as living inside /foo/bar."""
        col = load_collector(self.home)
        self.assertEqual(col._rel_path("/foo/bar", "/foo/barbaz"), "")
        self.assertEqual(col._rel_path("/foo/bar", "/foo/bar/baz"), "baz")

    def test_windows_subfolder_resolves(self):
        col = load_collector(self.home)
        self.assertEqual(
            col._rel_path("E:/dev/acme-web",
                          "E:\\dev\\acme-web\\agents"),
            "agents")
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/Desktop/Projects/claude-fleet && python3 -m unittest discover -s tests -t tests -v`

Expected: FAIL with `AttributeError: module 'collector' has no attribute '_norm'`.

- [ ] **Step 3: Add the helpers**

In `collector.py`, insert immediately above `def collect():`:

```python
def _norm(path):
    """Normalise a path for comparison only.

    git reports POSIX-style paths even on Windows (E:/dev/x) while the
    session registry reports native ones (E:\\dev\\x), so a raw
    startswith() comparison never matches and rel_path always came out empty.
    The original path is kept for display and Copy Path.
    """
    if not path:
        return ""
    p = path.replace("\\", "/")
    if len(p) > 1 and p[1] == ":":
        p = p[0].upper() + p[1:]
    return p.rstrip("/") or "/"


def _rel_path(root, cwd):
    """Path of cwd within root, or '' when cwd is not inside root."""
    root_n, cwd_n = _norm(root), _norm(cwd)
    if not root_n or not cwd_n:
        return ""
    if cwd_n == root_n:
        return ""
    # The trailing separator matters: without it /foo/barbaz reads as a child
    # of /foo/bar.
    prefix = root_n if root_n.endswith("/") else root_n + "/"
    if cwd_n.startswith(prefix):
        return cwd_n[len(prefix):]
    return ""
```

- [ ] **Step 4: Use them in `collect()`**

In `collector.py`, replace the whole `for sess in sessions:` block that assigns
`repo_root` / `repo_name` / `rel_path` with:

```python
    for sess in sessions:
        cwd = sess.get("cwd")
        root = repo_root(cwd)
        sess["repo_root"] = root or cwd
        sess["repo_name"] = os.path.basename(_norm(root or cwd)) or "~"
        # Path within the repo, so a session in repo/services/api still shows
        # where it is once the group header has taken the repo name.
        sess["rel_path"] = _rel_path(root, cwd)
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd ~/Desktop/Projects/claude-fleet && python3 -m unittest discover -s tests -t tests -v`

Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add collector.py tests/test_collector.py
git commit -m "fix: resolve rel_path across the git/registry path-style mismatch

git reports E:/repo while the registry reports E:\\repo\\sub, so raw
comparison always failed and every Windows subfolder session showed a
blank path. Also stops /foo/barbaz being treated as a child of /foo/bar."
```

---

### Task 3: Idle decay

A session finished days ago stays bright yellow and keeps counting in the badge.

**Files:**
- Modify: `collector.py` (`summarise_transcript`)
- Modify: `tests/test_collector.py`

**Interfaces:**
- Consumes: `_norm`/`_rel_path` from Task 2.
- Produces: no new symbols; `summarise_transcript` now decays every state to `idle` past `IDLE_SECS`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_collector.py`:

```python
class IdleDecayTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def test_old_waiting_session_decays_to_idle(self):
        """An abandoned 'Your turn' must stop counting as needing attention,
        or the badge drifts toward counting work you walked away from."""
        col = load_collector(self.home)
        path = write_transcript(self.home, "-tmp-repo", "sid-1",
                                [assistant_end_turn()], age_secs=3 * 60 * 60)
        info = col.summarise_transcript(path, time.time())
        self.assertEqual(info["state"], "idle")

    def test_recent_waiting_session_stays_waiting(self):
        col = load_collector(self.home)
        path = write_transcript(self.home, "-tmp-repo", "sid-2",
                                [assistant_end_turn()], age_secs=30)
        info = col.summarise_transcript(path, time.time())
        self.assertEqual(info["state"], "waiting")

    def test_stalled_tool_call_is_blocked(self):
        """The permission-prompt case: a tool call with no progress since."""
        col = load_collector(self.home)
        path = write_transcript(self.home, "-tmp-repo", "sid-3",
                                [assistant_wants_tool()], age_secs=600)
        info = col.summarise_transcript(path, time.time())
        self.assertEqual(info["state"], "blocked")
```

- [ ] **Step 2: Run to verify the first test fails**

Run: `cd ~/Desktop/Projects/claude-fleet && python3 -m unittest discover -s tests -t tests -v`

Expected: `test_old_waiting_session_decays_to_idle` FAILS with `'waiting' != 'idle'`.
The other two pass already.

- [ ] **Step 3: Remove the waiting exemption**

In `collector.py`, in `summarise_transcript`, replace:

```python
    if age > IDLE_SECS and state != "waiting":
```

with:

```python
    # No exemption for 'waiting': a turn finished three days ago is not
    # something that needs you now, and leaving it yellow makes the menu bar
    # badge count abandoned work.
    if age > IDLE_SECS:
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd ~/Desktop/Projects/claude-fleet && python3 -m unittest discover -s tests -t tests -v`

Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add collector.py tests/test_collector.py
git commit -m "fix: decay abandoned 'Your turn' sessions to idle

The badge must mean 'needs me now'; without decay it counted sessions
finished days ago."
```

---

### Task 4: Background polling — the defect that actually broke this

With the panel closed the app spawns no collector at all, so the badge never updates.

**Files:**
- Modify: `Sources/ClaudeFleetApp.swift`
- Modify: `Sources/SessionStore.swift:36-71` (`init`, `restartTimer`, `refreshSoon`)

**Interfaces:**
- Consumes: nothing from earlier tasks (Swift side is independent of the collector changes).
- Produces: `AppDelegate` with a `store: SessionStore` property; `SessionStore.start()` which begins polling; `SessionStore` no longer polls from `init()`.

- [ ] **Step 1: Replace the App entry point**

Replace the whole of `Sources/ClaudeFleetApp.swift` above `private struct MenuBarLabel` with:

```swift
import SwiftUI
import AppKit

/// Polling is owned by the application delegate, not by a @StateObject on the
/// scene. SwiftUI does not construct a MenuBarExtra's state until it needs to
/// materialise the panel, so a @StateObject store only began polling once the
/// user clicked -- which is exactly when they no longer need the badge.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
    }
}

#if !PREVIEW
@main
#endif
struct ClaudeFleetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 2: Make `SessionStore` start explicitly and survive a hung poll**

In `Sources/SessionStore.swift`, replace `init()`, `restartTimer()` and `refreshSoon()` with:

```swift
    private var started = false
    private var taskStartedAt: Date?
    private var generation = 0

    init() {}

    /// Preloaded, no polling. Used by the offline preview renderer.
    init(preloaded groups: [RepoGroup]) {
        self.groups = groups
        self.lastUpdate = Date()
    }

    /// Begins polling. Called from applicationDidFinishLaunching so that
    /// lifecycle depends on the app running, not on a panel being drawn.
    func start() {
        guard !started else { return }
        started = true
        restartTimer()
        refreshSoon()
    }

    private func restartTimer() {
        timer?.invalidate()
        guard started else { return }
        let every = Double(max(5, intervalSeconds))
        // .common, not the implicit .default: a timer in default mode does not
        // fire while a menu or panel is being tracked.
        let scheduled = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSoon() }
        }
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    func refreshSoon() {
        if task != nil {
            // A hung poll must not wedge every future refresh. Abandon it once
            // it has overrun its budget and let the next one through.
            let budget = max(30, Double(intervalSeconds) * 2)
            guard let began = taskStartedAt,
                  Date().timeIntervalSince(began) > budget else { return }
            task?.cancel()
            task = nil
        }

        isRefreshing = true
        taskStartedAt = Date()
        generation &+= 1
        let mine = generation
        let host = self.host
        let includeLocal = self.includeThisMac

        task = Task { [weak self] in
            let result = await Collector.gather(host: host, includeLocal: includeLocal)
            await MainActor.run {
                guard let self, mine == self.generation else { return }
                self.groups = result.groups
                self.lastError = result.error
                self.lastUpdate = Date()
                self.isRefreshing = false
                self.task = nil
                self.taskStartedAt = nil
            }
        }
    }
```

- [ ] **Step 3: Build and install**

Run: `cd ~/Desktop/Projects/claude-fleet && ./build.sh`

Expected: `signature OK`, `installed signature OK`, `Installed /Users/you/Applications/ClaudeFleet.app`.

- [ ] **Step 4: Verify polling happens with the panel never opened**

This is the behavioural test that defines the task. Launch the app and **do not click it**:

```bash
pkill -f "ClaudeFleet.app/Contents/MacOS"; sleep 1
open ~/Applications/ClaudeFleet.app
for i in $(seq 1 8); do
  echo "t=$((i*5))s ssh=$(pgrep -f 'ssh .*winbox' | wc -l | tr -d ' ') sockets=$(ls ~/.claude-fleet/cm/ 2>/dev/null | wc -l | tr -d ' ')"
  sleep 5
done
```

Expected: `sockets=1` within the first 15 seconds and staying at 1 thereafter — proof a
collector ran without the panel being opened. Before this task the same command printed
`ssh=0 sockets=0` for its whole duration.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeFleetApp.swift Sources/SessionStore.swift
git commit -m "fix: poll in the background instead of only when the panel opens

SwiftUI does not construct a MenuBarExtra's @StateObject until it
materialises the panel, so the store -- and its timer -- only came alive
after a click. The badge, the entire at-a-glance premise, never updated.
Ownership moves to an NSApplicationDelegateAdaptor, the timer runs in
.common mode so panel tracking cannot stall it, and a hung poll now
costs one cycle instead of wedging every future refresh."
```

---

### Task 5: Surface the diagnostics the collector now produces

**Files:**
- Modify: `Sources/Session.swift:115-117` (`CollectorPayload`)
- Modify: `Sources/SessionStore.swift` (`Collector.Result`, `gather`, `decode`)
- Modify: `Sources/MenuPanel.swift:242-255` (`SettingsPanel` diagnostics block)

**Interfaces:**
- Consumes: `hidden` / `collected` from the collector JSON (Task 1).
- Produces: `HiddenSession { sessionId: String, reason: String }`; `Collector.Result` gains `collected: Int` and `hidden: [HiddenSession]`.

- [ ] **Step 1: Decode the new fields**

In `Sources/Session.swift`, replace `struct CollectorPayload` with:

```swift
struct HiddenSession: Decodable, Sendable, Equatable, Identifiable {
    var sessionId: String
    var reason: String

    var id: String { sessionId }
}

struct CollectorPayload: Decodable, Sendable {
    var sessions: [Session]
    var hidden: [HiddenSession]?
    var collected: Int?
}
```

- [ ] **Step 2: Carry them through the collector**

In `Sources/SessionStore.swift`, replace `struct Result` with:

```swift
    struct Result: Sendable {
        var groups: [RepoGroup]
        var error: String?
        var collected: Int = 0
        var hidden: [HiddenSession] = []
    }
```

Replace `decode(_:)` with a version that returns the whole payload:

```swift
    private static func decode(_ data: Data) -> CollectorPayload? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "<<<CLAUDE_FLEET>>>"),
              let end = text.range(of: "<<<END>>>", range: start.upperBound..<text.endIndex)
        else { return nil }

        let json = String(text[start.upperBound..<end.lowerBound])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(CollectorPayload.self, from: Data(json.utf8))
    }
```

In `gather`, replace every `decode(data)` call site so the local leg reads:

```swift
        if includeLocal {
            let out = await run("/usr/bin/env", ["python3", scriptURL?.path ?? ""], stdin: URL?.none)
            switch out {
            case .success(let data):
                if let payload = decode(data) {
                    sessions += payload.sessions
                    hidden += payload.hidden ?? []
                    collected += payload.collected ?? payload.sessions.count
                }
            case .failure(let why): problems.append("this Mac: \(why.message)")
            }
        }
```

and the remote leg's success case reads:

```swift
                case .success(let data):
                    if let payload = decode(data) {
                        rememberInterpreter(interpreter, for: trimmed)
                        sessions += payload.sessions
                        hidden += payload.hidden ?? []
                        collected += payload.collected ?? payload.sessions.count
                        failure = nil
                    } else {
                        failure = "\(trimmed): \(interpreter) produced no usable output"
                        continue    // wrong interpreter for this machine -- try the next
                    }
```

Declare the accumulators next to `problems`:

```swift
        var hidden: [HiddenSession] = []
        var collected = 0
```

and return them:

```swift
        return Result(groups: group(sessions),
                      error: problems.isEmpty ? nil : problems.joined(separator: "\n"),
                      collected: collected,
                      hidden: hidden)
```

Delete `looksFramed(_:)` — `decode` returning nil now carries that meaning. Then publish
the values on the store by adding, beside the other `@Published` properties:

```swift
    @Published private(set) var collected: Int = 0
    @Published private(set) var hidden: [HiddenSession] = []
```

and assigning them inside `refreshSoon`'s `MainActor.run` block:

```swift
                self.collected = result.collected
                self.hidden = result.hidden
```

Finally, in `group(_:)`, delete the `where session.state != .ended` clause — the collector
now owns all filtering, and double-filtering is what made a hidden session unaccountable:

```swift
        for session in sessions {
```

- [ ] **Step 3: Show them in Settings**

In `Sources/MenuPanel.swift`, replace the `if let error = store.lastError { … }` block with:

```swift
            // Diagnostics live here and nowhere else. The session list never
            // shows transport state, counts, or errors.
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("\(store.collected) collected · \(store.hidden.count) hidden")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                ForEach(store.hidden) { item in
                    Text("• \(item.reason)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
```

- [ ] **Step 4: Build and verify the panel still renders**

Run:

```bash
cd ~/Desktop/Projects/claude-fleet && \
swiftc -O -parse-as-library -DPREVIEW -target arm64-apple-macos14.0 \
    -o /tmp/cfpreview Sources/*.swift && /tmp/cfpreview fixture.json /tmp/panel.png dark
```

Expected: `groups: 2` and `wrote /tmp/panel.png`. The existing `fixture.json` has no
`hidden` key, which confirms the optional decoding degrades cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/Session.swift Sources/SessionStore.swift Sources/MenuPanel.swift
git commit -m "feat: account for every hidden session in Settings diagnostics

The collector owns filtering now, so the Swift .ended filter is gone --
double-filtering is what let sessions vanish unaccountably. Settings
shows 'N collected, M hidden' with a reason per hidden session."
```

---

### Task 6: Notifications on entering a state that wants you

**Files:**
- Create: `Sources/Notifier.swift`
- Modify: `Sources/SessionStore.swift` (`refreshSoon`, `start`)
- Modify: `build.sh:30-45` (Info.plist — add a bundle display name for the notification source)

**Interfaces:**
- Consumes: `Session.State.wantsAttention` (already in `Session.swift`), `SessionStore.groups`.
- Produces: `Notifier` with `requestAuthorization()` and `observe(_ sessions: [Session])`.

- [ ] **Step 1: Write the notifier**

Create `Sources/Notifier.swift`:

```swift
import Foundation
import UserNotifications

/// Fires once when a session *enters* a state that wants the owner.
///
/// Two rules, both from hard experience with notification spam:
///   - never re-notify while a session sits in the same state;
///   - never notify for a state that was already true at launch, or opening
///     the app with eight blocked sessions produces eight alerts at once.
@MainActor
final class Notifier {
    private var previous: [String: Session.State] = [:]
    private var seeded = false
    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    func observe(_ sessions: [Session]) {
        let current = Dictionary(sessions.map { ($0.sessionId, $0.state) },
                                 uniquingKeysWith: { first, _ in first })
        defer { previous = current }

        // The first poll only establishes a baseline.
        guard seeded else { seeded = true; return }
        guard authorized else { return }

        for session in sessions where session.state.wantsAttention {
            guard previous[session.sessionId] != session.state else { continue }
            post(session)
        }
    }

    private func post(_ session: Session) {
        let content = UNMutableNotificationContent()
        content.title = session.state.label
        content.body = [session.repoName, session.title]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        content.sound = session.state == .blocked ? .default : nil

        let request = UNNotificationRequest(
            identifier: "\(session.sessionId)-\(session.state.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 2: Wire it into the store**

In `Sources/SessionStore.swift`, add a property beside the other private state:

```swift
    private let notifier = Notifier()
```

In `start()`, request authorization once, immediately after `started = true`:

```swift
        notifier.requestAuthorization()
```

In `refreshSoon`'s `MainActor.run` block, after `self.groups = result.groups`, add:

```swift
                self.notifier.observe(result.groups.flatMap(\.sessions))
```

- [ ] **Step 3: Give the bundle a usage-facing identity**

In `build.sh`, inside the `Info.plist` heredoc, add below the `CFBundleDisplayName` line:

```xml
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
```

- [ ] **Step 4: Build, install and verify a real notification**

Run: `cd ~/Desktop/Projects/claude-fleet && ./build.sh && open ~/Applications/ClaudeFleet.app`

Expected: macOS prompts once for notification permission. Grant it. Then confirm no burst
appears at launch even with sessions already waiting — that is the seeding rule working.

To verify a real transition, start a session on winbox that stops at a permission prompt and
wait one poll interval; a single "Needs approval" notification should appear, and no
further ones while it sits there.

- [ ] **Step 5: Commit**

```bash
git add Sources/Notifier.swift Sources/SessionStore.swift build.sh
git commit -m "feat: notify once when a session starts needing you

Only on the transition into blocked/waiting, keyed by session id. The
first poll seeds the baseline without notifying, so launching with
sessions already blocked does not produce a burst."
```

---

### Task 7: End-to-end verification against the live machine

**Files:**
- Modify: `README.md`
- Create: `fixtures/blocked.json`

**Interfaces:**
- Consumes: everything above.
- Produces: no code; a verified install and corrected documentation.

- [ ] **Step 1: Capture a blocked-state fixture**

The two states that matter most should be renderable offline rather than waited for:

```bash
cd ~/Desktop/Projects/claude-fleet && mkdir -p fixtures && \
ssh winbox "py -" < collector.py > fixtures/blocked.json && \
python3 - <<'PY'
import json, re
raw = open("fixtures/blocked.json").read()
doc = json.loads(re.search(r"<<<CLAUDE_FLEET>>>(.*)<<<END>>>", raw, re.S).group(1))
for i, s in enumerate(doc["sessions"]):
    if i == 0:
        s["state"], s["state_reason"] = "blocked", "tool call issued 12m ago with no progress -- likely a permission prompt"
    s.setdefault("rel_path", "agents" if i == 1 else "")
open("fixtures/blocked.json", "w").write("<<<CLAUDE_FLEET>>>" + json.dumps(doc) + "<<<END>>>")
print("sessions:", len(doc["sessions"]))
PY
```

Expected: `sessions: 3` or however many are live.

- [ ] **Step 2: Render it and confirm blocked sorts to the top**

Run:

```bash
cd ~/Desktop/Projects/claude-fleet && \
swiftc -O -parse-as-library -DPREVIEW -target arm64-apple-macos14.0 \
    -o /tmp/cfpreview Sources/*.swift && \
/tmp/cfpreview fixtures/blocked.json /tmp/blocked.png dark
```

Expected: the printed group listing shows `worst=blocked` for the affected repo, and that
repo is listed **first**. Open `/tmp/blocked.png` and confirm an orange dot and "Needs
approval".

- [ ] **Step 3: Run the whole test suite**

Run: `cd ~/Desktop/Projects/claude-fleet && python3 -m unittest discover -s tests -t tests -v`

Expected: PASS, 10 tests.

- [ ] **Step 4: Confirm the acceptance criteria against the running app**

Install and run: `cd ~/Desktop/Projects/claude-fleet && ./build.sh && open ~/Applications/ClaudeFleet.app`

Then check each, without opening the panel first:

```bash
sleep 20
ls ~/.claude-fleet/cm/ | wc -l    # expect 1 -- background polling works
```

Open the panel and confirm: winbox's sessions present; sessions grouped under one repo
heading per repo; no hostname, connection status or error text anywhere in the list.

Then disconnect winbox (or set the machine field to a bogus alias) and confirm the list goes
**empty and calm** rather than showing an error.

- [ ] **Step 5: Remove the hardcoded developer path**

`Collector.scriptURL` falls back to one specific person's home directory, which makes the
source tree unshareable. In `Sources/SessionStore.swift`, replace `scriptURL` with:

```swift
    /// Path to collector.py. Resolved from the bundle so the app stays
    /// self-contained, with a source-tree fallback for development that is
    /// derived rather than hardcoded to one machine.
    static var scriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "collector", withExtension: "py") {
            return bundled
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // Sources/
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("collector.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
```

- [ ] **Step 6: Document setup for someone else's machine**

Background agents are visible and that is intentional, so say so. In `README.md`, add
below the Settings section:

```markdown
### Using this on your own machines

Nothing is installed on the remote host. The collector is piped over SSH stdin and uses
only the Python standard library, so the requirements there are:

- an entry in your `~/.ssh/config` (the app takes the **alias**, inheriting your user,
  port and key — use the same one VS Code Remote-SSH uses)
- key-based auth that works without an agent — test with
  `env -i ssh -o BatchMode=yes <alias> echo ok`
- any working Python. The interpreter is probed (`python3`, `py`, `python`) and the
  winner cached per host, so Windows hosts where `python3` is a Microsoft Store stub
  are handled automatically.

Build with your own signing identity:

    CLAUDE_FLEET_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh

**Background agents** (`claude --bg`) appear alongside interactive sessions. They are
tagged `kind: "bg"` in the registry and their name is the task text they were started
with. This is deliberate — a background agent stuck on a permission prompt is exactly as
invisible as an interactive one.
```

- [ ] **Step 7: Correct the README**

In `README.md`, replace the `## Known gap` section with:

```markdown
## Verified

Verified end-to-end against winbox (Windows 11, OpenSSH, `py` 3.11.9) on 2026-07-30:
sessions collected, states derived, repo grouping correct, and background polling
confirmed by observing the ControlMaster socket with the panel never opened.

Three Windows traps this handles, each measured rather than assumed:

- `python`/`python3` on winbox are Microsoft Store stubs that exit 49 with empty stdout.
  Only `py` runs Python. The interpreter is probed and cached per host.
- `tasklist` has no elapsed-time column, so the pid-reuse guard is unavailable there and
  liveness falls back to the registry's `updatedAt` heartbeat.
- git reports `E:/repo` while the session registry reports `E:\repo\sub`, so paths are
  normalised before comparison.

A process probe that fails is treated as *unknown*, never as "everything died" — only a
positive `dead` verdict removes a session from view, and every removal is reported with a
reason in Settings → Diagnostics.
```

Also fix the stale invocation line under "How it works": replace `python3 -` with
`<py|python3> -`.

- [ ] **Step 8: Commit**

```bash
git add README.md fixtures/ Sources/SessionStore.swift
git commit -m "docs: record verified behaviour and add a blocked-state fixture

Replaces the 'winbox was unreachable' known-gap section, which was the
assumption that produced the wrong postmortem in the first place."
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| §6.1 Idle decay | Task 3 |
| §7 Background polling | Task 4 |
| §8 Three-valued liveness | Task 1 |
| §8.3 Hidden accountability | Tasks 1 + 5 |
| §9 Path handling | Task 2 |
| §11 Notifications | Task 6 |
| §12 Build/packaging | unchanged by design; exercised in Tasks 4, 6, 7 |
| §13 Testing | Tasks 1–3 (unit), 4 (behavioural), 7 (end-to-end) |
| §14 Acceptance criteria | Task 7, Step 4 |

**Type consistency**

- `live_pids()` returns `(dict, bool)` in Task 1 and is called that way in `collect()`.
- `collect()` returns `(sessions, hidden)` in Task 1; `main()` unpacks it identically.
- `liveness_verdict` produces exactly `"live" | "dead" | "unknown"`; only `"dead"` filters.
- `_norm`/`_rel_path` are defined in Task 2 and used only after definition.
- `HiddenSession` uses `sessionId`/`reason`, matching the collector's `session_id`/`reason`
  under `.convertFromSnakeCase`.
- `SessionStore.start()` is defined in Task 4 and called from `AppDelegate` in the same task.
- `Notifier.observe(_:)` takes `[Session]`; the call site passes
  `result.groups.flatMap(\.sessions)`, which is `[Session]`.

**Note on ordering:** Task 5 removes the Swift `.ended` filter, which is only safe because
Task 1 made the collector stop emitting `ended`. Do not reorder 5 before 1.
