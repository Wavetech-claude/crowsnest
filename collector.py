#!/usr/bin/env python3
"""
crowsnest collector -- runs ON a host (local or remote), prints one JSON doc.

Designed to be executed with zero installation:

    ssh myhost 'python3 -' < collector.py

Stdlib only, Python 3.6+. Never reads a whole transcript: seeks to the end and
parses the last TAIL_BYTES backwards.
"""

import glob
import json
import os
import re
import socket
import subprocess
import sys
import time

TAIL_BYTES = 65536          # how much of a transcript tail we read
FRESH_SECS = 90             # mtime newer than this => actively moving
IDLE_SECS = 2 * 60 * 60     # older than this => idle, not just paused
ORPHAN_SECS = 30 * 60       # transcripts this recent count even with no registry entry
PID_TOLERANCE = 180         # seconds of slop when matching pid start time

CLAUDE_HOME = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
SESSIONS_DIR = os.path.join(CLAUDE_HOME, "sessions")
PROJECTS_DIR = os.path.join(CLAUDE_HOME, "projects")


# --------------------------------------------------------------------------
# process liveness
# --------------------------------------------------------------------------

def _parse_etime(raw):
    """ps etime -> seconds. Formats: SS, MM:SS, HH:MM:SS, DD-HH:MM:SS."""
    raw = raw.strip()
    if not raw:
        return None
    days = 0
    if "-" in raw:
        d, raw = raw.split("-", 1)
        days = int(d)
    parts = [int(p) for p in raw.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


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


def liveness_verdict(reg, pids, probe_ok, now):
    """'live' | 'dead' | 'unknown'.

    Only 'dead' may ever hide a session. Three rules keep the empty-list
    failure impossible:
      1. A failed probe yields 'unknown', never 'dead'.
      2. An empty table alongside registry files is also 'unknown' -- a
         machine running Claude always has at least one process, so zero
         processes means the probe lied about succeeding.
      3. An absent or null pid is missing information, not proof of death;
         it yields 'unknown'.
    """
    if not probe_ok or not pids:
        return "unknown"

    pid = reg.get("pid")
    if pid is None:
        return "unknown"
    if pid not in pids:
        return "dead"

    elapsed = pids[pid]
    if elapsed is None:
        # Windows: tasklist has no elapsed-time column, so there is no
        # pid-reuse guard here. But the pid IS present in a successfully
        # read process table -- that is positive evidence the process is
        # alive. updatedAt is stamped on status *transitions*, not on a
        # timer, so a session parked at a permission prompt stops updating
        # it; treating that staleness as death would hide an overnight
        # permission prompt, which is the worst failure this tool can have.
        # Pid reuse producing a false 'live' is far less harmful than a
        # false 'dead', because 'live' shows and 'dead' hides -- always
        # fail toward showing.
        return "live"

    started = reg.get("startedAt")
    if not started:
        return "live"
    # Compared as elapsed time so we never reconcile timezones.
    expected = now - (started / 1000.0)
    return "live" if abs(expected - elapsed) <= PID_TOLERANCE else "dead"


# --------------------------------------------------------------------------
# transcript tail
# --------------------------------------------------------------------------

def read_tail_records(path):
    """Parse the last TAIL_BYTES of a .jsonl into record dicts (oldest first)."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()          # discard the partial first line
            blob = fh.read()
    except OSError:
        return []

    records = []
    for line in blob.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except ValueError:
            continue
    return records


_REPO_CACHE = {}


def repo_root(cwd):
    """Enclosing git repo, so several sessions in different subdirectories of
    one repo group together instead of scattering into separate sections."""
    if not cwd:
        return None
    if cwd in _REPO_CACHE:
        return _REPO_CACHE[cwd]
    root = None
    try:
        proc = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
        )
        if proc.returncode == 0:
            root = proc.stdout.decode("utf-8", "replace").strip() or None
    except Exception:
        root = None
    _REPO_CACHE[cwd] = root
    return root


def find_transcript(session_id):
    hits = glob.glob(os.path.join(PROJECTS_DIR, "*", session_id + ".jsonl"))
    if not hits:
        return None
    return max(hits, key=lambda p: os.path.getmtime(p))


def _content_kinds(msg):
    content = msg.get("content")
    if isinstance(content, list):
        return [c.get("type") for c in content if isinstance(c, dict)]
    return ["text"] if isinstance(content, str) else []


def summarise_transcript(path, now):
    """Derive activity state, model and context size from the transcript tail."""
    info = {
        "transcript": path,
        "last_activity": None,
        "age_secs": None,
        "state": "unknown",
        "state_reason": "no transcript",
        "model": None,
        "context_tokens": None,
        "last_turn": None,
        "git_branch": None,
        "slug": None,
        "cwd_hint": None,
    }
    if not path or not os.path.exists(path):
        return info

    mtime = os.path.getmtime(path)
    age = now - mtime
    info["last_activity"] = mtime
    info["age_secs"] = round(age, 1)

    records = read_tail_records(path)

    # Newest assistant record carries model + a usage block. input + cache_read
    # is the live context size, which is what actually matters for compaction.
    for rec in reversed(records):
        if rec.get("type") == "assistant":
            msg = rec.get("message") or {}
            info["model"] = msg.get("model")
            usage = msg.get("usage") or {}
            try:
                info["context_tokens"] = (
                    int(usage.get("input_tokens") or 0)
                    + int(usage.get("cache_read_input_tokens") or 0)
                    + int(usage.get("cache_creation_input_tokens") or 0)
                )
            except (TypeError, ValueError):
                pass
            info["git_branch"] = rec.get("gitBranch")
            info["slug"] = rec.get("slug")
            # Records carry the real cwd. For orphans this beats reversing the
            # project-dir slug, which is lossy on any hyphenated directory.
            info["cwd_hint"] = rec.get("cwd")
            break

    # Newest *conversational* record decides the state. Everything else
    # (mode, ai-title, last-prompt, attachment, file-history-snapshot,
    # queue-operation, permission-mode) is bookkeeping, not a turn.
    turn = None
    for rec in reversed(records):
        if rec.get("type") in ("assistant", "user"):
            turn = rec
            break

    if turn is None:
        info["state"] = "idle" if age > IDLE_SECS else "unknown"
        info["state_reason"] = "no conversational records in tail"
        return info

    msg = turn.get("message") or {}
    kinds = _content_kinds(msg)
    fresh = age < FRESH_SECS

    if turn.get("type") == "assistant":
        stop = msg.get("stop_reason")
        info["last_turn"] = "assistant:" + str(stop)
        if stop == "end_turn":
            state, reason = "waiting", "Claude finished its turn -- awaiting your input"
        elif stop in ("max_tokens", "stop_sequence", "refusal"):
            state, reason = "waiting", "turn ended (%s)" % stop
        elif fresh:
            state, reason = "working", "tool call in flight"
        else:
            state, reason = "blocked", "tool call issued %s ago with no progress -- likely a permission prompt" % _human(age)
    else:
        info["last_turn"] = "user:" + (",".join(k for k in kinds if k) or "text")
        if "tool_result" in kinds:
            state, reason = ("working", "tool result returned, model thinking") if fresh \
                else ("blocked", "tool result sat unprocessed for %s" % _human(age))
        else:
            state, reason = ("working", "prompt submitted") if fresh \
                else ("blocked", "prompt submitted %s ago with no reply" % _human(age))

    # 'waiting' decays to idle after 2h (the owner walked away), but 'blocked'
    # never decays. A blocked session is genuinely stuck on a permission prompt,
    # and only a human can unstick it -- three hours later that is still true.
    # Abandonment is caught by the liveness verdict instead: if the terminal
    # closes, the process dies and the session becomes 'dead' and is hidden.
    if age > IDLE_SECS and state != "blocked":
        state, reason = "idle", "no activity for %s" % _human(age)

    info["state"] = state
    info["state_reason"] = reason
    return info


def _human(secs):
    secs = int(secs)
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 86400:
        return "%dh%dm" % (secs // 3600, (secs % 3600) // 60)
    return "%dd" % (secs // 86400)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

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


def collect():
    """Returns (sessions, hidden). `hidden` records every session removed from
    view and why, so filtering is auditable rather than silent."""
    now = time.time()
    pids, probe_ok = live_pids()
    sessions = []
    hidden = []
    seen_ids = set()

    # Pass 1: read every registry file and dedupe by sessionId, keeping the
    # newest startedAt. Two files can legitimately carry the same sessionId
    # -- a crashed run's stale <pid>.json alongside a live one, or --resume
    # beside the still-running original -- and without this they'd double
    # as two rows for one session downstream (badge double-count, duplicate
    # SwiftUI Identifiable id).
    regs_by_sid = {}
    for reg_path in sorted(glob.glob(os.path.join(SESSIONS_DIR, "*.json"))):
        try:
            with open(reg_path) as fh:
                reg = json.load(fh)
        except (OSError, ValueError):
            continue

        sid = reg.get("sessionId")
        if not sid:
            continue
        existing = regs_by_sid.get(sid)
        if existing is None or (reg.get("startedAt") or 0) > (existing.get("startedAt") or 0):
            regs_by_sid[sid] = reg

    # Pass 2: turn each surviving registry into a session or a hidden entry.
    # Everything past the JSON parse is guarded per-session -- one record
    # with a malformed field (e.g. a non-numeric updatedAt) must lose only
    # itself, never raise out of collect() and blank every other session on
    # the machine.
    for sid, reg in sorted(regs_by_sid.items()):
        seen_ids.add(sid)
        try:
            verdict = liveness_verdict(reg, pids, probe_ok, now)
            if verdict == "dead":
                pid = reg.get("pid")
                updated = reg.get("updatedAt")
                stale = _human(now - updated / 1000.0) if updated else "unknown"
                if pid in pids:
                    # Present in the table but its elapsed time doesn't match
                    # startedAt -- the pid was reused by an unrelated
                    # process, not proof our process is gone.
                    reason = ("pid %s present but its start time no longer "
                              "matches this session (likely reused; registry "
                              "stale %s)" % (pid, stale))
                else:
                    reason = "pid %s gone (registry stale %s)" % (pid, stale)
                hidden.append({"session_id": sid, "reason": reason})
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
        except Exception as exc:
            hidden.append({
                "session_id": sid,
                "reason": "%s: %s" % (type(exc).__name__, exc),
            })

    # Transcripts that moved recently but have no registry entry. Catches hosts
    # where the registry is not written or was cleaned up under a live session.
    for path in glob.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl")):
        sid = os.path.basename(path)[:-6]
        if sid in seen_ids:
            continue
        try:
            if now - os.path.getmtime(path) > ORPHAN_SECS:
                continue
        except OSError:
            continue
        entry = summarise_transcript(path, now)
        entry.update({
            "session_id": sid,
            "pid": None,
            "liveness": "unknown",
            "cwd": entry.get("cwd_hint") or _cwd_from_project_dir(path),
            "name": None,
            "version": None,
            "entrypoint": None,
            "kind": None,
            "started_at": None,
            "source": "orphan",
        })
        sessions.append(entry)
        seen_ids.add(sid)

    for sess in sessions:
        cwd = sess.get("cwd")
        root = repo_root(cwd)
        sess["repo_root"] = root or cwd
        sess["repo_name"] = os.path.basename(_norm(root or cwd)) or "~"
        # Path within the repo, so a session in repo/services/api still shows
        # where it is once the group header has taken the repo name.
        sess["rel_path"] = _rel_path(root, cwd)

    order = {"blocked": 0, "waiting": 1, "working": 2, "unknown": 3, "idle": 4}
    sessions.sort(key=lambda s: (order.get(s.get("state"), 9), -(s.get("last_activity") or 0)))
    return sessions, hidden


def _cwd_from_project_dir(path):
    """Best-effort reverse of the project-dir slug (/a/b -> -a-b)."""
    slug = os.path.basename(os.path.dirname(path))
    return "/" + slug.lstrip("-").replace("-", "/") if slug.startswith("-") else slug


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else socket.gethostname()
    doc = {
        "host": host,
        "hostname": socket.gethostname(),
        "collected_at": time.time(),
        "ok": True,
        "error": None,
        "claude_home": CLAUDE_HOME,
        "sessions": [],
        "hidden": [],
        "collected": 0,
    }
    try:
        doc["sessions"], doc["hidden"] = collect()
        doc["collected"] = len(doc["sessions"]) + len(doc["hidden"])
    except Exception as exc:                                  # never die silently
        doc["ok"] = False
        doc["error"] = "%s: %s" % (type(exc).__name__, exc)
    # Markers let the poller find our JSON even if the login shell prints a banner.
    sys.stdout.write("<<<CROWSNEST>>>" + json.dumps(doc) + "<<<END>>>\n")


if __name__ == "__main__":
    main()
