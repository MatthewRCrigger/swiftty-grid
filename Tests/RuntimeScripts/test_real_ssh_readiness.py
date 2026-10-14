"""Owned-process startup evidence, bounded probes, and listener bind behavior."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/real-ssh-readiness.py"
SPEC = importlib.util.spec_from_file_location("real_ssh_readiness", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ssh-readiness-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.ready = self.root / "ready"

    def helper(self, body):
        path = self.root / "status"
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def test_successful_status_receives_isolated_configuration(self):
        config = self.root / "config.json"
        observed = self.root / "observed"
        helper = self.helper("import os\nfrom pathlib import Path\n"
                             f"Path({str(observed)!r}).write_text(os.environ['SWIFTMUX_ROAMING_CONFIG'])\n")
        MODULE.wait_host(os.getpid(), helper, config, timeout=1)
        self.assertEqual(observed.read_text(), str(config))

    def test_hung_status_is_killed_and_reaped_at_overall_deadline(self):
        record = self.root / "probe.pid"
        helper = self.root / "status"
        helper.write_text("#!/bin/sh\nprintf '%s' \"$$\" > " + shlex.quote(str(record))
                          + "\nexec /bin/sleep 10\n")
        helper.chmod(0o755)
        created = []
        original_popen = subprocess.Popen
        def spawn(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            created.append(process)
            return process
        started = time.monotonic()
        with mock.patch.object(MODULE.subprocess, "Popen", side_effect=spawn):
            with self.assertRaisesRegex(MODULE.ReadinessError, "timed out"):
                MODULE.wait_host(os.getpid(), helper, self.root / "config", timeout=0.3)
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(created)
        for process in created:
            self.assertIsNotNone(process.returncode)
            with self.assertRaises(ProcessLookupError):
                os.kill(process.pid, 0)

    def test_late_success_and_invalid_timing_are_rejected(self):
        def late(remaining):
            time.sleep(0.08)
            return True
        with self.assertRaisesRegex(MODULE.ReadinessError, "timed out"):
            MODULE.wait_ready(os.getpid(), late, timeout=0.02)
        for timeout in [0, -1, float("inf"), float("nan")]:
            with self.subTest(timeout=timeout), self.assertRaises(MODULE.ReadinessError):
                MODULE.wait_ready(os.getpid(), lambda remaining: True, timeout=timeout)

    def test_acknowledgment_requires_live_pid_and_current_token(self):
        self.ready.write_text(json.dumps({"pid": os.getpid(), "token": "new"}))
        MODULE.wait_listener(os.getpid(), self.ready, "new", timeout=0.1)
        for value in [{"pid": os.getpid(), "token": "old"},
                      {"pid": True, "token": "new"},
                      {"pid": os.getpid() + 1, "token": "new"}, [], {}]:
            self.ready.write_text(json.dumps(value))
            with self.subTest(value=value), self.assertRaises(MODULE.ReadinessError):
                MODULE.wait_listener(os.getpid(), self.ready, "new", timeout=0.1)
        with subprocess.Popen([sys.executable, "-c", "pass"]) as child:
            child.wait(timeout=3)
            self.ready.write_text(json.dumps({"pid": child.pid, "token": "new"}))
            with self.assertRaisesRegex(MODULE.ReadinessError, "exited"):
                MODULE.wait_listener(child.pid, self.ready, "new", timeout=0.1)

    def test_missing_malformed_oversize_fifo_and_symlink_acknowledgments_fail(self):
        with self.assertRaisesRegex(MODULE.ReadinessError, "timed out"):
            MODULE.wait_listener(os.getpid(), self.ready, "new", timeout=0.05)
        for data in [b"{", b"\xff", b"x" * 4097]:
            self.ready.write_bytes(data)
            with self.subTest(data=data[:5]), self.assertRaises(MODULE.ReadinessError):
                MODULE.wait_listener(os.getpid(), self.ready, "new", timeout=0.1)
        self.ready.unlink()
        os.mkfifo(self.ready)
        with self.assertRaisesRegex(MODULE.ReadinessError, "regular file"):
            MODULE.wait_listener(os.getpid(), self.ready, "new", timeout=0.1)
        self.ready.unlink()
        self.ready.symlink_to(self.root / "absent")
        with self.assertRaises(OSError):
            MODULE.wait_listener(os.getpid(), self.ready, "new", timeout=0.1)

    def test_interrupt_reaps_active_status_probe(self):
        record = self.root / "probe.pid"
        helper = self.helper("import os,time\nfrom pathlib import Path\n"
                             f"Path({str(record)!r}).write_text(str(os.getpid()))\n"
                             "time.sleep(10)\n")
        with subprocess.Popen([sys.executable, str(SCRIPT), "host", str(os.getpid()),
                               str(helper), str(self.root / "config")]) as driver:
            try:
                deadline = time.monotonic() + 3
                while not record.exists():
                    self.assertIsNone(driver.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                driver.send_signal(signal.SIGTERM)
                self.assertEqual(driver.wait(timeout=3), 143)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(record.read_text()), 0)
            finally:
                if driver.poll() is None:
                    driver.kill()
                    driver.wait(timeout=3)

    def test_pid_arguments_reject_process_group_and_overflow_values(self):
        for value in ["0", "1", "-1", "0002", "2147483648", "abc", "１２"]:
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                MODULE.positive_pid(value)
        self.assertEqual(MODULE.positive_pid("2"), 2)

    def container_tool(self, inspect, check="exit 0"):
        tool = self.root / "container"
        tool.write_text("#!/bin/sh\ncase \"$1\" in\ninspect)\n" + inspect
                        + ";;\nexec)\n" + check + ";;\nesac\n")
        tool.chmod(0o755)
        return {"PATH": str(self.root) + os.pathsep + os.environ["PATH"]}

    def test_container_ready_requires_successful_inspect_and_file_check(self):
        valid = '[{"status":{"networks":[{"ipv4Address":"127.0.0.2/24"}]}}]'
        environment = self.container_tool("printf '%s' " + shlex.quote(valid) + "\nexit 0\n")
        with mock.patch.dict(os.environ, environment):
            self.assertEqual(MODULE.wait_container(os.getpid(), "fixture", timeout=1), "127.0.0.2")
        for inspect, check in [("printf '%s' " + shlex.quote(valid) + "\nexit 73\n", "exit 0"),
                               ("printf '%s' " + shlex.quote(valid) + "\n", "exit 74")]:
            environment = self.container_tool(inspect, check)
            with self.subTest(check=check), mock.patch.dict(os.environ, environment):
                with self.assertRaisesRegex(MODULE.ReadinessError, "timed out"):
                    MODULE.wait_container(os.getpid(), "fixture", timeout=0.5)

    def test_container_invalid_schema_and_address_are_not_accepted(self):
        for value in [None, {}, [], [{}], [{"status": {"networks": []}}],
                      [{"status": {"networks": [{"ipv4Address": "not-an-ip"}]}}],
                      [{"status": {"networks": [{"ipv4Address": 5}]}}],
                      [{"status": {"networks": [{"ipv4Address": "127.0.0.2/24"}]}}] * 2]:
            with self.subTest(value=value):
                self.assertIsNone(MODULE.container_address(json.dumps(value).encode()))
        for data in [b"{", b"\xff"]:
            self.assertIsNone(MODULE.container_address(data))
        valid = b'[{"status":{"networks":[{"ipv4Address":"127.0.0.2/24"}]}}]'
        self.assertEqual(MODULE.container_address(valid), "127.0.0.2")

    def test_hung_inspect_or_file_check_is_killed_and_reaped(self):
        valid = '[{"status":{"networks":[{"ipv4Address":"127.0.0.2/24"}]}}]'
        record = self.root / "probe.pid"
        hang = "printf '%s' \"$$\" > " + shlex.quote(str(record)) + "\nexec /bin/sleep 10\n"
        for inspect, check in [(hang, "exit 0"),
                               ("printf '%s' " + shlex.quote(valid) + "\n", hang)]:
            record.unlink(missing_ok=True)
            environment = self.container_tool(inspect, check)
            with self.subTest(check=check), mock.patch.dict(os.environ, environment):
                started = time.monotonic()
                with self.assertRaisesRegex(MODULE.ReadinessError, "timed out"):
                    MODULE.wait_container(os.getpid(), "fixture", timeout=1.5)
                self.assertLess(time.monotonic() - started, 3)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(record.read_text()), 0)

    def test_probe_flood_is_capped_and_reaped(self):
        record = self.root / "probe.pid"
        tool = self.root / "flood"
        tool.write_text("#!/bin/sh\nprintf '%s' \"$$\" > " + shlex.quote(str(record))
                        + "\nexec /usr/bin/yes x\n")
        tool.chmod(0o755)
        with self.assertRaisesRegex(MODULE.ReadinessError, "exceeds limit"):
            MODULE.capture_probe([str(tool)], 1, limit=128)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(record.read_text()), 0)

    def test_probe_exit_and_eof_both_required_before_deadline(self):
        tool = self.root / "probe"
        for body in ["exec 1>&-\nexec /bin/sleep 10\n",
                     "printf valid\nexit 77\n"]:
            tool.write_text("#!/bin/sh\n" + body)
            tool.chmod(0o755)
            with self.subTest(body=body):
                self.assertIsNone(MODULE.capture_probe([str(tool)], 0.5))
        for timeout in [0, -1, float("inf"), float("nan")]:
            with self.assertRaises(MODULE.ReadinessError):
                MODULE.capture_probe([str(tool)], timeout)

    def test_interrupt_during_container_probe_reaps_child(self):
        record = self.root / "probe.pid"
        environment = self.container_tool("printf '%s' \"$$\" > " + shlex.quote(str(record))
                                          + "\nexec /bin/sleep 10\n")
        with subprocess.Popen([sys.executable, str(SCRIPT), "container", str(os.getpid()), "fixture"],
                              env={**os.environ, **environment}) as driver:
            try:
                deadline = time.monotonic() + 3
                while not record.exists():
                    self.assertIsNone(driver.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                driver.send_signal(signal.SIGTERM)
                self.assertEqual(driver.wait(timeout=3), 143)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(record.read_text()), 0)
            finally:
                if driver.poll() is None:
                    driver.kill()
                    driver.wait(timeout=3)

    def test_actual_proxy_listeners_acknowledge_only_after_successful_bind(self):
        proxy = ROOT / "Scripts/real-ssh-proxy.py"
        for mode in ["bridge", "relay"]:
            with self.subTest(listener=mode):
                self.ready.unlink(missing_ok=True)
                with socket.socket() as occupied:
                    occupied.bind(("127.0.0.1", 0))
                    occupied.listen()
                    port = occupied.getsockname()[1]
                    with subprocess.Popen([sys.executable, str(proxy), mode,
                                           "127.0.0.1", str(port), "fake-target",
                                           str(self.ready), "new"],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
                        stdout, stderr = child.communicate(timeout=3)
                        self.assertNotEqual(child.returncode, 0)
                        self.assertIn(b"Address already in use", stderr)
                        self.assertFalse(self.ready.exists())
                # Port zero gets a real kernel-selected port without racing a reservation.
                with subprocess.Popen([sys.executable, str(proxy), mode, "127.0.0.1",
                                       "0", "fake-target", str(self.ready), "new"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as child:
                    try:
                        MODULE.wait_listener(child.pid, self.ready, "new", timeout=2)
                    finally:
                        child.terminate()
                        child.wait(timeout=3)
                        child.stderr.close()


if __name__ == "__main__":
    unittest.main()
