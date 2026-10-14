"""Exercise pane ownership and failure cleanup without launchd services."""

from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import agent_shutdown_fixture as fixture
import test_agent_shutdown as shutdown


class AgentShutdownFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shutdown-pane-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def pane(self, ignores_hup=True, descendant=False, natural_exit=False):
        pane = fixture.AgentPaneFixture(self.directory, ignores_hup, descendant, natural_exit)
        self.addCleanup(pane.close)
        return pane

    def start(self, pane):
        process = subprocess.Popen([sys.executable, *pane.arguments],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.retire, process)
        return process

    def retire(self, process):
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)

    def ready(self, pane, process):
        deadline = time.monotonic() + 3
        while not pane.pidfile.exists():
            self.assertIsNone(process.poll())
            self.assertLess(time.monotonic(), deadline, "pane did not publish readiness")
            time.sleep(0.01)

    def test_natural_leader_stays_alive_until_observation_gate_is_released(self):
        pane = self.pane(descendant=True, natural_exit=True)
        process = self.start(pane)
        self.ready(pane, process)
        time.sleep(0.15)
        self.assertIsNone(process.poll())
        self.assertFalse(pane.exited_at.exists())
        released_at = fixture.monotonic()
        pane.release_natural_exit()
        self.assertEqual(process.wait(timeout=3), 7)
        collected_at = fixture.monotonic()
        self.assertGreaterEqual(pane.natural_exit_time(), released_at)
        self.assertLessEqual(pane.natural_exit_time(), collected_at)
        pane.close()
        self.assertFalse(pane.leases.thread.is_alive())

    def test_cooperative_pane_exits_on_hangup(self):
        pane = self.pane(ignores_hup=False)
        process = self.start(pane)
        self.ready(pane, process)
        process.send_signal(signal.SIGHUP)
        self.assertEqual(process.wait(timeout=3), -signal.SIGHUP)

    def test_ignoring_pane_survives_hangup_then_owned_fallback_collects_it(self):
        pane = self.pane()
        process = self.start(pane)
        self.ready(pane, process)
        process.send_signal(signal.SIGHUP)
        with self.assertRaises(subprocess.TimeoutExpired):
            process.wait(timeout=0.15)
        pane.close()
        self.assertEqual(process.wait(timeout=3), -signal.SIGTERM)

    def test_generation_error_closes_listener_before_constructor_raises(self):
        leases = []
        real_leases = fixture.OwnedToolLeases
        def remember(directory):
            owner = real_leases(directory)
            leases.append(owner)
            return owner
        with mock.patch.object(fixture, "OwnedToolLeases", side_effect=remember):
            with mock.patch.object(Path, "write_text", side_effect=OSError("write failed")):
                with self.assertRaisesRegex(OSError, "write failed"):
                    fixture.AgentPaneFixture(self.directory, True)
        self.assertEqual(len(leases), 1)
        self.assertFalse(leases[0].thread.is_alive())
        self.assertFalse(leases[0].path.exists())

    def test_plist_error_occurs_before_owned_listener_is_created(self):
        case = shutdown.AgentShutdownTests()
        with mock.patch.object(shutdown.plistlib, "dumps", side_effect=OSError("plist failed")):
            with mock.patch.object(shutdown, "AgentPaneFixture") as factory:
                with self.assertRaisesRegex(OSError, "plist failed"):
                    case.check_fixture(self.directory, None, True, True, True)
        factory.assert_not_called()

    def failing_fixture(self, cleanup_fails=False, spoof_record=False):
        panes = []
        processes = []
        calls = []
        real_pane = fixture.AgentPaneFixture
        def remember(*args):
            pane = real_pane(*args)
            panes.append(pane)
            return pane
        sentinel = None
        if spoof_record:
            sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            self.addCleanup(self.retire, sentinel)

        class FailingBody(shutdown.AgentShutdownTests):
            __unittest_skip__ = False
            def runTest(case):
                case.check_fixture(self.directory, None, True, True, True)

            def command(case, arguments, env=None, allowed=(0,)):
                # These commands simulate a private job; only the generated
                # pane processes below actually run. No launchctl is invoked.
                calls.append(arguments)
                if arguments[0] == "/bin/launchctl":
                    if arguments[1] == "bootout" and cleanup_fails:
                        raise OSError("deliberate bootout cleanup failure")
                    code = 113 if arguments[1] == "print" else 0
                    case.assertIn(code, allowed)
                    return subprocess.CompletedProcess(arguments, code, "", "")
                if arguments[1] == "new":
                    pane = panes[-1]
                    process = self.start(pane)
                    processes.append(process)
                    self.ready(pane, process)
                    if sentinel is not None:
                        pane.pidfile.write_text(str(sentinel.pid))
                    raise AssertionError("deliberate command body failure")
                return subprocess.CompletedProcess(arguments, 0, "", "")

        case = FailingBody()
        result = unittest.TestResult()
        with mock.patch.object(shutdown, "AgentPaneFixture", side_effect=remember):
            case.run(result)
        self.assertEqual(result.testsRun, 1)
        self.assertEqual(len(result.failures), 1)
        self.assertIn("deliberate command body failure", result.failures[0][1])
        self.assertEqual(len(result.errors), int(cleanup_fails))
        if cleanup_fails:
            self.assertIn("deliberate bootout cleanup failure", result.errors[0][1])
        for process in processes:
            process.wait(timeout=3)
        self.assertEqual(len(panes), 1)
        pane = panes[0]
        self.assertFalse(pane.script.parent.exists())
        self.assertFalse(pane.leases.thread.is_alive())
        self.assertEqual(calls[-1][1], "print")
        self.assertTrue(pane.leases.last_retired)
        if sentinel is not None:
            self.assertIsNone(sentinel.poll())

    def test_failed_body_collects_panes_without_consulting_a_spoofed_pid_record(self):
        self.failing_fixture(spoof_record=True)

    def test_cleanup_error_is_separate_and_does_not_skip_owned_process_collection(self):
        self.failing_fixture(cleanup_fails=True)

    def test_observation_delay_cannot_count_toward_a_skipped_grace_period(self):
        panes = []
        processes = []
        stopped = threading.Event()
        workers = []
        worker_errors = []
        real_pane = fixture.AgentPaneFixture
        def remember(*args):
            pane = real_pane(*args)
            panes.append(pane)
            return pane

        def retire_after_exit(pane, process):
            try:
                deadline = time.monotonic() + 5
                while not pane.exited_at.exists():
                    if stopped.wait(0.01):
                        return
                    if time.monotonic() >= deadline:
                        raise RuntimeError("leader did not publish its exit event")
                # Emulate a service skipping its grace, through the private
                # channels. No numeric PID is used for a termination request.
                with pane.leases.lock:
                    connections = [connection for connection, _ in pane.leases.connections]
                for connection in connections:
                    try:
                        connection.sendall(b"!")
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                process.wait(timeout=3)
            except Exception as error:
                worker_errors.append(error)

        class SkippedGrace(shutdown.AgentShutdownTests):
            __unittest_skip__ = False
            def runTest(case):
                case.check_fixture(self.directory, None, True, True, True,
                                   observation_delay=2.1)

            def command(case, arguments, env=None, allowed=(0,)):
                if arguments[0] == "/bin/launchctl":
                    code = 113 if arguments[1] == "print" else 0
                    case.assertIn(code, allowed)
                    return subprocess.CompletedProcess(arguments, code, "", "")
                if arguments[0] == "/bin/ps":
                    return subprocess.CompletedProcess(arguments, 0, str(panes[-1].script), "")
                if arguments[1] == "new":
                    pane = panes[-1]
                    process = self.start(pane)
                    processes.append(process)
                    self.ready(pane, process)
                    worker = threading.Thread(target=retire_after_exit, args=(pane, process))
                    workers.append(worker)
                    worker.start()
                return subprocess.CompletedProcess(arguments, 0, "", "")

        result = unittest.TestResult()
        try:
            with mock.patch.object(shutdown, "AgentPaneFixture", side_effect=remember):
                SkippedGrace().run(result)
        finally:
            stopped.set()
            for worker in workers:
                worker.join(timeout=4)
        self.assertFalse(any(worker.is_alive() for worker in workers))
        self.assertEqual(worker_errors, [])
        self.assertEqual(len(result.failures), 1)
        self.assertIn("termination skipped the grace period", result.failures[0][1])
        self.assertEqual(result.errors, [])
        self.assertFalse(panes[0].script.parent.exists())
        self.assertFalse(panes[0].leases.thread.is_alive())


if __name__ == "__main__":
    unittest.main()
