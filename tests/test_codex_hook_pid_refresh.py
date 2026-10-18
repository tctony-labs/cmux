#!/usr/bin/env python3
"""Exercise cached agent PID recovery through the bundled CLI and an isolated socket."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import FAKE_SURFACE_ID, FAKE_WORKSPACE_ID, FakeCmuxSocket


class HookSocket(FakeCmuxSocket):
    def _handle_conn(self, conn) -> None:
        try:
            super()._handle_conn(conn)
        except (BrokenPipeError, ConnectionResetError):
            # Feed telemetry deliberately closes without waiting for the acknowledgement.
            pass


class CodexHookPIDRefreshTests(unittest.TestCase):
    def setUp(self) -> None:
        self.cli = resolve_cmux_cli()
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-pid-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = self.root / "codex-hook-sessions.json"
        self.transcript = self.root / "rollout.jsonl"
        self.transcript.write_text(
            json.dumps(
                {
                    "type": "event_msg",
                    "payload": {"type": "task_complete", "last_agent_message": "finished"},
                }
            ) + "\n"
        )
        self.session = "resumed-codex-session"
        self.socket = HookSocket(self.root / "test.sock", None)
        self.socket.__enter__()
        self.addCleanup(self.socket.__exit__, None, None, None)
        self.env = {
            key: value for key, value in os.environ.items() if not key.startswith("CMUX_")
        }
        self.env.update(
            HOME=str(self.root),
            PWD=str(self.root),
            CODEX_HOME=str(self.root),
            CMUX_SOCKET_PATH=str(self.socket.path),
            CMUX_WORKSPACE_ID=FAKE_WORKSPACE_ID,
            CMUX_SURFACE_ID=FAKE_SURFACE_ID,
            CMUX_AGENT_HOOK_STATE_DIR=str(self.root),
            CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS="0",
            CMUX_CLI_SENTRY_DISABLED="1",
            CMUX_AGENT_LAUNCH_KIND="codex",
            CMUX_AGENT_LAUNCH_ARGV_B64=base64.b64encode(b'["codex"]').decode(),
        )
        helper = subprocess.Popen(["/usr/bin/true"])
        helper.wait(timeout=3)
        self.dead_pid = helper.pid
        self.seed(self.dead_pid)

    def seed(self, pid: int) -> None:
        now = time.time()
        self.store.write_text(
            json.dumps(
                {
                    "version": 1,
                    "sessions": {
                        self.session: {
                            "sessionId": self.session,
                            "workspaceId": FAKE_WORKSPACE_ID,
                            "surfaceId": FAKE_SURFACE_ID,
                            "pid": pid,
                            "startedAt": now,
                            "updatedAt": now,
                        }
                    },
                }
            )
        )

    def record(self) -> dict:
        return json.loads(self.store.read_text())["sessions"][self.session]

    def commands(self) -> list[str]:
        return [frame["raw"] for frame in self.socket.frames if "raw" in frame]

    def payload(self, event: str) -> str:
        return json.dumps(
            {
                "session_id": self.session,
                "hook_event_name": event,
                "transcript_path": str(self.transcript),
                "last_assistant_message": "finished",
                "message": "finished",
            }
        )

    def run_hook(self, action: str, event: str) -> None:
        result = subprocess.run(
            [self.cli, "hooks", "codex", action],
            input=self.payload(event),
            env=self.env,
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "{}\n")

    def assert_registered(self, pid: int) -> None:
        prefix = f"set_agent_pid codex.{self.session} {pid} "
        self.assertTrue(any(c.startswith(prefix) for c in self.commands()), self.commands())

    def test_prompt_and_stop_recover_live_pid_without_session_start(self) -> None:
        previous = subprocess.Popen(["/bin/sleep", "30"])
        try:
            self.seed(previous.pid)
        finally:
            previous.terminate()
            previous.wait(timeout=3)

        self.run_hook("prompt-submit", "UserPromptSubmit")
        self.assertEqual(self.record()["pid"], os.getpid())
        self.assert_registered(os.getpid())
        self.assertTrue(any(c.startswith("set_status codex Running ") for c in self.commands()))

        self.run_hook("stop", "Stop")
        self.assertEqual(self.record()["pid"], os.getpid())
        self.assertEqual(self.record()["agentLifecycle"], "idle")
        self.assertTrue(any(c.startswith("set_status codex Idle ") for c in self.commands()))
        self.assertTrue(any(c.startswith("notify_target_async ") for c in self.commands()))

    def test_new_session_does_not_reuse_previous_sessions_pid(self) -> None:
        previous_session = self.session
        self.session = "new-codex-session"
        self.run_hook("prompt-submit", "UserPromptSubmit")
        sessions = json.loads(self.store.read_text())["sessions"]
        self.assertEqual(sessions[previous_session]["pid"], self.dead_pid)
        self.assertEqual(self.record()["pid"], os.getpid())
        self.assert_registered(os.getpid())

    def test_other_events_refresh_dead_cached_pid(self) -> None:
        for action, event in [
            ("stop", "Stop"),
            ("approval-response", "PermissionRequest"),
            ("notification", "Notification"),
        ]:
            with self.subTest(action=action):
                self.seed(self.dead_pid)
                self.run_hook(action, event)
                self.assertEqual(self.record()["pid"], os.getpid())

    def test_live_cached_pid_is_preserved_for_hooks_from_child_processes(self) -> None:
        helper = subprocess.Popen(["/bin/sleep", "30"])
        try:
            self.seed(helper.pid)
            self.run_hook("prompt-submit", "UserPromptSubmit")
            self.assertEqual(self.record()["pid"], helper.pid)
            self.assert_registered(helper.pid)
        finally:
            helper.terminate()
            helper.wait(timeout=3)

    def test_session_start_registers_before_blocked_git_baseline(self) -> None:
        self.assert_registration_before_blocked_git("session-start", "SessionStart")

    def test_prompt_registers_before_blocked_git_baseline(self) -> None:
        self.assert_registration_before_blocked_git("prompt-submit", "UserPromptSubmit")

    def assert_registration_before_blocked_git(self, action: str, event: str) -> None:
        git = self.root / "git"
        started = self.root / "git-started"
        gate = self.root / "git-gate"
        os.mkfifo(gate)
        git.write_text(
            '#!/bin/sh\n: > "$CMUX_TEST_GIT_STARTED"\nexec /bin/cat "$CMUX_TEST_GIT_GATE"\n'
        )
        git.chmod(0o755)
        self.env.update(
            PATH=f"{self.root}:/usr/bin:/bin:/usr/sbin:/sbin",
            CMUX_TEST_GIT_STARTED=str(started),
            CMUX_TEST_GIT_GATE=str(gate),
        )
        payload = json.loads(self.payload(event))
        payload["cwd"] = str(self.root)
        process = subprocess.Popen(
            [self.cli, "hooks", "codex", action],
            env=self.env,
            cwd=self.root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            process.stdin.write(json.dumps(payload))
            process.stdin.close()
            process.stdin = None
            deadline = time.monotonic() + 3
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(started.exists(), f"{event} did not reach Git baseline capture")
            self.assertEqual(self.record()["pid"], os.getpid())
            self.assert_registered(os.getpid())
            if action == "prompt-submit":
                self.assertEqual(self.record()["agentLifecycle"], "running")
                self.assertTrue(
                    any(c.startswith("set_status codex Running ") for c in self.commands())
                )
        finally:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()
