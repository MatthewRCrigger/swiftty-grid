"""Verify the real-SSH harness retires only its owned fake processes."""

import subprocess
import sys
import unittest
from unittest import mock

import real_ssh_test_fixture as fixture
from real_ssh_test_fixture import RealSSHFixture


class RealSSHCleanupTests(RealSSHFixture, unittest.TestCase):
    def registered_pids(self):
        with self.leases.lock:
            return [identity["pid"] for _, identity in self.leases.connections]

    def assert_collected(self, pids):
        self.leases.wait_stopped(timeout=0.5)
        self.assert_dead(pids)

    def test_fallback_collects_tools_ignoring_term(self):
        result = self.invoke(FIXTURE_IGNORE_TERM="host,bridge,relay")
        self.assertEqual(result.returncode, 0, result.stderr)
        pids = self.registered_pids()
        self.assertEqual(len(pids), 3)
        self.cleanup_children()
        self.assert_collected(pids)

    def test_fallback_awaits_delayed_exit(self):
        result = self.invoke(FIXTURE_TERM_DELAY="0.15")
        self.assertEqual(result.returncode, 0, result.stderr)
        pids = self.registered_pids()
        self.cleanup_children()
        self.leases.wait_stopped(timeout=0.02)
        self.assert_dead(pids)

    def test_removed_records_do_not_strand_owned_tools(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        pids = self.registered_pids()
        for directory, pattern in [(self.directory, "*.started"), (self.state, "*.pid")]:
            for record in directory.glob(pattern):
                record.unlink()
        self.cleanup_children()
        self.assert_collected(pids)

    def test_a_matching_path_and_pid_record_cannot_authorize_another_process(self):
        script = self.bin / "unrelated.py"
        script.write_text("import time; time.sleep(30)\n")
        unrelated = subprocess.Popen([sys.executable, str(script)])
        try:
            result = self.invoke()
            self.assertEqual(result.returncode, 0, result.stderr)
            pids = self.registered_pids()
            (self.directory / "host.started").write_text(str(unrelated.pid))
            self.cleanup_children()
            try:
                unrelated.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                pass
            self.assertIsNone(unrelated.poll())
            self.assert_collected(pids)
        finally:
            # This handle owns the sentinel; no fixture PID file is consulted.
            if unrelated.poll() is None:
                unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_failed_body_keeps_its_error_and_collects_tools_before_removing_paths(self):
        snapshots = {}
        class FailingBody(RealSSHFixture, unittest.TestCase):
            def runTest(case):
                result = case.invoke(FIXTURE_IGNORE_TERM="host,bridge,relay")
                case.assertEqual(result.returncode, 0, result.stderr)
                with case.leases.lock:
                    snapshots["pids"] = [row["pid"] for _, row in case.leases.connections]
                (case.directory / "host.started").write_text("not a PID")
                raise AssertionError("deliberate body failure")
        case = FailingBody()
        result = unittest.TestResult()
        case.run(result)
        self.assertEqual(result.testsRun, 1)
        self.assertEqual(len(result.failures), 1)
        self.assertIn("deliberate body failure", result.failures[0][1])
        self.assertEqual(result.errors, [])
        self.assert_dead(snapshots["pids"])
        self.assertFalse(case.directory.exists())
        self.assertFalse(case.leases.thread.is_alive())

    def test_setup_error_closes_the_registered_listener_before_removing_paths(self):
        class FailingSetup(RealSSHFixture, unittest.TestCase):
            def runTest(case):
                case.fail("body must not run")
        case = FailingSetup()
        result = unittest.TestResult()
        with mock.patch.object(fixture.shutil, "copyfile",
                               side_effect=OSError("deliberate copy failure")):
            case.run(result)
        self.assertEqual(len(result.errors), 1)
        self.assertIn("deliberate copy failure", result.errors[0][1])
        self.assertEqual(result.failures, [])
        self.assertFalse(case.directory.exists())
        self.assertFalse(case.leases.thread.is_alive())

    def test_outer_timeout_keeps_its_error_and_collects_the_idle_tools(self):
        snapshots = {}
        class TimedOutBody(RealSSHFixture, unittest.TestCase):
            def runTest(case):
                result = case.invoke(FIXTURE_IGNORE_TERM="host,bridge,relay")
                case.assertEqual(result.returncode, 0, result.stderr)
                with case.leases.lock:
                    snapshots["pids"] = [row["pid"] for _, row in case.leases.connections]
                # Time out only after startup has completed. This invocation
                # owns one sleep while the earlier host/proxies remain alive.
                case.script.write_text("#!/bin/sh\nexec /bin/sleep 30\n")
                case.invoke(timeout=0.2)
                case.fail("expected the copied wrapper to time out")
        case = TimedOutBody()
        result = unittest.TestResult()
        case.run(result)
        self.assertEqual(len(result.errors), 1)
        self.assertIn("TimeoutExpired", result.errors[0][1])
        self.assertEqual(result.failures, [])
        self.assertEqual(len(snapshots["pids"]), 3)
        self.assert_dead(snapshots["pids"])
        self.assertFalse(case.directory.exists())


if __name__ == "__main__":
    unittest.main()
