import os
import shutil
import subprocess
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
        unavailable and pid presence alone decides."""
        col = load_collector(self.home)
        self._seed(pid=4242)
        col.live_pids = lambda: ({4242: None}, True)
        sessions, hidden = col.collect()
        self.assertEqual(len(sessions), 1)
        self.assertEqual(hidden, [])

    def test_windows_no_elapsed_and_stale_updated_at_is_still_live(self):
        """Spec Sec13 test 4. On Windows 'elapsed is None' but the pid IS in a
        successfully read process table -- positive evidence of life. Before
        the fix, a stale updatedAt (heartbeat only moves on status
        transitions, so a session parked at a permission prompt stops
        updating it) made this verdict 'dead' after 6 hours, hiding a
        blocked session overnight. Must FAIL against pre-fix code: pre-fix
        this session is hidden and sessions is empty."""
        col = load_collector(self.home)
        sid = "windows-stale-heartbeat"
        pid = 4242
        stale_updated_at = int((time.time() - 8 * 3600) * 1000)  # 8h stale
        write_registry(self.home, pid, sid, self.cwd,
                       updated_at=stale_updated_at)
        write_transcript(self.home, "-tmp-repo", sid,
                         [assistant_end_turn(cwd=self.cwd)])
        col.live_pids = lambda: ({pid: None}, True)  # Windows shape
        sessions, hidden = col.collect()
        self.assertEqual(len(sessions), 1)
        self.assertEqual(hidden, [])
        self.assertEqual(sessions[0]["session_id"], sid)
        self.assertEqual(sessions[0]["liveness"], "live")

    def test_pid_reuse_mismatch_reason_describes_what_was_observed(self):
        """A pid that IS present in the table but whose elapsed time doesn't
        match startedAt is a reused pid, not a vanished process -- the
        hidden reason must say so rather than falsely claiming it is 'gone'.
        Must FAIL against pre-fix code: the reason was unconditionally
        'pid %s gone ...' for every dead verdict."""
        col = load_collector(self.home)
        sid = self._seed(pid=4242)  # startedAt ~= now - 60s
        # Same pid now reports a wildly different elapsed time: reused by an
        # unrelated process, not our session.
        col.live_pids = lambda: ({4242: 99999.0}, True)
        sessions, hidden = col.collect()
        self.assertEqual(sessions, [])
        self.assertEqual(len(hidden), 1)
        self.assertEqual(hidden[0]["session_id"], sid)
        self.assertNotIn("gone", hidden[0]["reason"])
        self.assertIn("4242", hidden[0]["reason"])

    def test_malformed_registry_field_does_not_blank_other_sessions(self):
        """collect() previously guarded only the JSON parse; everything past
        it (e.g. dividing a non-numeric updatedAt) was unguarded and raised
        out of collect(), taking every other session on the machine down
        with it. One bad record must lose only itself. Must FAIL against
        pre-fix code: collect() raises TypeError instead of returning."""
        col = load_collector(self.home)
        good_sid = self._seed(pid=4242)

        bad_sid = "malformed-registry-session"
        bad_pid = 9001
        write_registry(self.home, bad_pid, bad_sid, self.cwd,
                       updated_at="not-a-real-timestamp")
        write_transcript(self.home, "-tmp-repo", bad_sid,
                         [assistant_end_turn(cwd=self.cwd)])

        # bad_pid absent from the live table -> verdict 'dead' -> formatting
        # the hidden reason divides the malformed updatedAt by 1000.0.
        col.live_pids = lambda: ({4242: 100.0}, True)
        sessions, hidden = col.collect()

        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["session_id"], good_sid)
        self.assertEqual(len(hidden), 1)
        self.assertEqual(hidden[0]["session_id"], bad_sid)
        self.assertTrue(hidden[0]["reason"])

    def test_duplicate_session_id_across_registry_files_dedupes_to_newest(self):
        """A crashed run's stale <pid>.json alongside a live one (or
        --resume beside the still-running original) must not double-count
        one session as two rows. Keep the entry with the newest startedAt.
        Must FAIL against pre-fix code: sessions would contain 2 entries."""
        col = load_collector(self.home)
        sid = "dup-session"
        old_pid, new_pid = 1111, 2222
        now_ms = int(time.time() * 1000)
        write_registry(self.home, old_pid, sid, self.cwd,
                       started_at=now_ms - 3600 * 1000,
                       updated_at=now_ms - 3600 * 1000)
        write_registry(self.home, new_pid, sid, self.cwd,
                       started_at=now_ms - 60 * 1000,
                       updated_at=now_ms)
        write_transcript(self.home, "-tmp-repo", sid,
                         [assistant_end_turn(cwd=self.cwd)])
        col.live_pids = lambda: ({old_pid: 3600.0, new_pid: 60.0}, True)
        sessions, hidden = col.collect()
        self.assertEqual(len(sessions), 1)
        self.assertEqual(hidden, [])
        self.assertEqual(sessions[0]["pid"], new_pid)

    def test_absent_pid_is_unknown_never_dead(self):
        """An absent pid in the registry is missing information, not proof of
        death. It must yield 'unknown' and keep the session visible."""
        col = load_collector(self.home)
        sid = "missing-pid-session"
        # Seed a registry with no pid field (pid=None to omit it).
        write_registry(self.home, None, sid, self.cwd,
                       updated_at=int(time.time() * 1000))
        write_transcript(self.home, "-tmp-repo", sid,
                         [assistant_end_turn(cwd=self.cwd)])
        # Provide a successful probe with some live pids.
        col.live_pids = lambda: ({9999: 100.0}, True)
        sessions, hidden = col.collect()
        # Session must still be visible; it must not be hidden.
        self.assertEqual(len(sessions), 1)
        self.assertEqual(hidden, [])
        self.assertEqual(sessions[0]["session_id"], sid)
        self.assertEqual(sessions[0]["liveness"], "unknown")


class PathTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def test_norm_canonicalises_windows_paths(self):
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

    def test_rel_path_end_to_end_with_git_repo(self):
        """End-to-end: collect() returns correct rel_path for a session in a repo subfolder."""
        # Create a real git repo in a temp directory
        repo_temp = tempfile.mkdtemp()
        try:
            # Initialize git repo (suppress output to avoid interactive prompts)
            subprocess.run(["git", "init"], cwd=repo_temp,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=True)

            # Get the actual repo root as git sees it (handles /private/var/... on macOS).
            # Use this path for the session cwd to ensure consistency across platforms.
            proc = subprocess.run(
                ["git", "-C", repo_temp, "rev-parse", "--show-toplevel"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                check=True, text=True)
            git_root = proc.stdout.strip()

            # Create a subdirectory in the repo using the git_root path
            # (git_root handles /private/var resolution on macOS)
            subdir_name = "agents"
            subdir_path = os.path.join(git_root, subdir_name)
            os.makedirs(subdir_path)

            # Seed a session with cwd pointing to the subdirectory
            col = load_collector(self.home)
            sid = "end-to-end-session"
            pid = 5555
            write_registry(self.home, pid, sid, subdir_path,
                           updated_at=int(time.time() * 1000))
            write_transcript(self.home, "-end-to-end-test", sid,
                             [assistant_end_turn(cwd=subdir_path)])

            # Mock liveness so the session reads as live
            col.live_pids = lambda: ({pid: 100.0}, True)

            # Collect
            sessions, hidden = col.collect()

            # Verify
            self.assertEqual(len(sessions), 1, "Expected exactly one session")
            sess = sessions[0]

            # rel_path should be the subdirectory name
            self.assertEqual(sess["rel_path"], subdir_name,
                             f"Expected rel_path={subdir_name}, got {sess['rel_path']}")

            # repo_name should be the repo directory name
            git_root_basename = os.path.basename(git_root)
            self.assertEqual(sess["repo_name"], git_root_basename,
                             f"Expected repo_name={git_root_basename}, got {sess['repo_name']}")

        finally:
            shutil.rmtree(repo_temp, ignore_errors=True)


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

    def test_old_blocked_session_stays_blocked_past_idle_threshold(self):
        """A blocked session older than IDLE_SECS is still stuck and must
        remain visible. Abandonment is caught by the liveness verdict instead."""
        col = load_collector(self.home)
        path = write_transcript(self.home, "-tmp-repo", "sid-4",
                                [assistant_wants_tool()], age_secs=3 * 60 * 60)
        info = col.summarise_transcript(path, time.time())
        self.assertEqual(info["state"], "blocked")

    def test_very_old_blocked_session_stays_blocked(self):
        """A blocked session 26 hours old is still stuck, never transitions
        to idle. The stuck state persists regardless of age."""
        col = load_collector(self.home)
        path = write_transcript(self.home, "-tmp-repo", "sid-5",
                                [assistant_wants_tool()], age_secs=26 * 60 * 60)
        info = col.summarise_transcript(path, time.time())
        self.assertEqual(info["state"], "blocked")


if __name__ == "__main__":
    unittest.main()
