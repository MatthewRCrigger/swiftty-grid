"""Process ownership, handoff, and retirement through the real fixture supervisor."""

from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from owned_tool_leases import OwnedToolLeases, TOOL_LEASE

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/real-ssh-process.py"
SPEC = importlib.util.spec_from_file_location("real_ssh_process", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProcessOwnerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ssh-owner-", dir="/tmp")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()

    @contextmanager
    def owner(self, command=None, handoff=True, environment=None, role="host"):
        parent, child = socket.socketpair()
        with (self.root / "owner.log").open("wb") as log:
            process = subprocess.Popen(
                [sys.executable, "-I", str(SCRIPT), "serve", str(self.root), role,
                 str(child.fileno()), *(command or ["/bin/sleep", "30"])],
                pass_fds=(child.fileno(),), stdout=log, stderr=log, env=environment,
            )
        child.close()
        try:
            pid = MODULE.receive(parent)
            if handoff:
                MODULE.send(parent, "handoff")
                self.assertEqual(MODULE.receive(parent), "ready")
            yield process, pid, parent
        finally:
            parent.close()
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=MODULE.TIMEOUT + MODULE.TERMINATION_GRACE + 3)

    def assert_retired(self, process, pid):
        process.wait(timeout=3)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertFalse((self.root / "host.pid").exists())
        self.assertFalse((self.root / "host.owner").exists())

    def test_stop_reaps_child_and_closes_private_endpoint(self):
        with self.owner() as (process, pid, _):
            record = self.root / "host.owner"
            identity = json.loads(record.read_text())
            endpoint = Path(identity["socket"]).parent
            self.assertEqual(record.stat().st_mode & 0o777, 0o600)
            self.assertEqual(endpoint.stat().st_mode & 0o777, 0o700)
            MODULE.request_owner(self.root, "host", "stop")
            self.assert_retired(process, pid)
            self.assertFalse(endpoint.exists())
            # A repeated stop needs neither a PID probe nor a signal.
            MODULE.request_owner(self.root, "host", "stop")

    def test_abandoned_handoff_retires_child(self):
        with self.owner(handoff=False) as (process, pid, startup):
            startup.close()
            self.assert_retired(process, pid)

    def test_liveness_and_stop_use_ownership_even_without_pid_marker(self):
        with self.owner() as (process, pid, _):
            MODULE.request_owner(self.root, "host", "alive")
            (self.root / "host.pid").unlink()
            MODULE.request_owner(self.root, "host", "stop")
            self.assert_retired(process, pid)
            # Replacing an informational PID cannot resurrect a dead owner.
            (self.root / "host.pid").write_text(str(os.getpid()))
            with self.assertRaisesRegex(ValueError, "no process owner"):
                MODULE.request_owner(self.root, "host", "alive")

    def test_interrupted_supervisor_retires_child(self):
        with self.owner() as (process, pid, _):
            process.terminate()
            self.assert_retired(process, pid)

    def test_natural_exit_reaps_child_and_removes_records(self):
        release = self.root / "release"
        program = ("import time\nfrom pathlib import Path\n"
                   f"while not Path({str(release)!r}).exists(): time.sleep(0.01)\n")
        with self.owner([sys.executable, "-c", program]) as (process, pid, _):
            release.touch()
            self.assert_retired(process, pid)

    def test_build_status_tracks_running_exit_and_signal(self):
        for code in [0, 7, None]:
            with self.subTest(code=code):
                release = self.root / "release"
                release.unlink(missing_ok=True)
                (self.root / "xcodebuild.status").unlink(missing_ok=True)
                program = ("import sys,time\nfrom pathlib import Path\n"
                           f"while not Path({str(release)!r}).exists(): time.sleep(0.01)\n"
                           f"sys.exit({code!r})\n")
                with self.owner([sys.executable, "-c", program], role="xcodebuild") as (process, _, _):
                    self.assertEqual(MODULE.build_status(self.root), "running")
                    if code is None:
                        MODULE.request_owner(self.root, "xcodebuild", "stop")
                    else:
                        release.touch()
                    deadline = time.monotonic() + 3
                    while (status := MODULE.build_status(self.root)) == "running":
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    self.assertEqual(status, code if code is not None else 143)
                    process.wait(timeout=3)
                    self.assertFalse((self.root / "xcodebuild.owner").exists())
                    self.assertFalse((self.root / "xcodebuild.pid").exists())

    def test_build_status_fails_if_owner_is_lost_without_a_result(self):
        with self.assertRaises(OSError):
            MODULE.build_status(self.root)

    def test_wrong_token_or_fixture_cannot_stop_child(self):
        with self.owner() as (process, pid, _):
            identity = json.loads((self.root / "host.owner").read_text())
            for change in [{"token": "wrong"}, {"state": str(self.root / "other")},
                           {"role": "relay"}]:
                with self.subTest(change=change):
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                        connection.connect(identity["socket"])
                        MODULE.send(connection, {**identity, "action": "stop", **change})
                        self.assertIn("identity mismatch", MODULE.receive(connection)["error"])
                    self.assertIsNone(process.poll())
                    os.kill(pid, 0)
                    self.assertTrue((self.root / "host.pid").exists())
            MODULE.request_owner(self.root, "host", "stop")
            self.assert_retired(process, pid)

    def test_missing_endpoint_or_permission_failure_retains_records(self):
        identity = {"socket": str(self.root / "missing.sock"), "token": "saved",
                    "state": str(self.root), "role": "host"}
        owner = self.root / "host.owner"
        owner.write_text(json.dumps(identity))
        pid = self.root / "host.pid"
        pid.write_text(str(os.getpid()))
        for failure in [None, PermissionError("access denied")]:
            with self.subTest(failure=failure):
                if failure is None:
                    with self.assertRaises(FileNotFoundError):
                        MODULE.request_owner(self.root, "host", "stop")
                else:
                    with mock.patch.object(MODULE.socket.socket, "connect", side_effect=failure):
                        with self.assertRaises(PermissionError):
                            MODULE.request_owner(self.root, "host", "stop")
                self.assertEqual(json.loads(owner.read_text()), identity)
                self.assertEqual(pid.read_text(), str(os.getpid()))

    def test_malformed_oversized_symlink_and_fifo_records_are_refused(self):
        owner = self.root / "host.owner"
        for data in [b"{", b"[]", b"{}", b"\xff", b"x" * 4097]:
            with self.subTest(data=data[:5]):
                owner.write_bytes(data)
                with self.assertRaises(ValueError):
                    MODULE.request_owner(self.root, "host", "stop")
                self.assertEqual(owner.read_bytes(), data)
        owner.unlink()
        os.mkfifo(owner)
        with self.assertRaisesRegex(ValueError, "regular file"):
            MODULE.request_owner(self.root, "host", "stop")
        owner.unlink()
        owner.symlink_to(self.root / "missing")
        with self.assertRaises(OSError):
            MODULE.request_owner(self.root, "host", "stop")
        self.assertTrue(owner.is_symlink())

    def test_spawn_failure_removes_only_its_own_records(self):
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "start", str(self.root), "host",
             str(self.root / "missing-executable")], capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.root / "host.pid").exists())
        self.assertFalse((self.root / "host.owner").exists())

    def test_stop_allows_real_proxy_to_reap_its_term_ignoring_child(self):
        # The outer owner must allow the proxy's existing shutdown budget.
        # Killing the proxy too early would orphan its container-exec process.
        ready = self.root / "proxy.ready"
        child_ready = self.root / "container.ready"
        leases = OwnedToolLeases(self.root)
        self.addCleanup(leases.close)
        container = self.root / "container"
        container.write_text(
            "#!" + sys.executable + "\nimport json, os, signal, time\nfrom pathlib import Path\n"
            "name = 'container'\n" + TOOL_LEASE + "\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            f"Path({str(child_ready)!r}).write_text(str(os.getpid()))\n"
            "while True: time.sleep(0.05)\n"
        )
        container.chmod(0o755)
        command = [sys.executable, str(ROOT / "Scripts/real-ssh-proxy.py"), "relay",
                   "127.0.0.1", "0", "fixture", str(ready), "token"]
        environment = {**os.environ, **leases.environment,
                       "PATH": str(self.root) + os.pathsep + os.environ["PATH"]}
        with self.owner(command, environment=environment) as (process, pid, _):
            deadline = time.monotonic() + 5
            while not ready.exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            port = json.loads(ready.read_text())["port"]
            with socket.create_connection(("127.0.0.1", port), timeout=3):
                while not child_ready.exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                descendant = int(child_ready.read_text())
                MODULE.request_owner(self.root, "host", "stop")
                self.assert_retired(process, pid)
                with self.assertRaises(ProcessLookupError):
                    os.kill(descendant, 0)


if __name__ == "__main__":
    unittest.main()
