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
        "sessionId": session_id,
        "cwd": cwd,
        "startedAt": started_at if started_at is not None else now_ms - 60000,
        "version": "2.1.220",
        "kind": "interactive",
        "entrypoint": "cli",
    }
    if pid is not None:
        reg["pid"] = pid
        reg["name"] = "test-%s" % pid
    if updated_at is not None:
        reg["updatedAt"] = updated_at
    filename = "%d.json" % pid if pid is not None else "no-pid.json"
    with open(os.path.join(d, filename), "w") as fh:
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
