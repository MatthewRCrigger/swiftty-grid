"""Exercise the real driver with isolated tools and an owned fake host."""

import importlib.util
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from owned_tool_leases import OwnedToolLeases, TOOL_LEASE


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("roaming_simulator",
                                            ROOT / "Scripts/roaming-simulator.py")
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)

# All commands run inside this test's directories; these tools never invoke
# Swift, Xcode, containers, SSH, or a simulator.
TOOL = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
directory = Path(os.environ["FIXTURE_DIRECTORY"])
name = Path(sys.argv[0]).name
with (directory / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name, sys.argv[1:]]) + "\n")
if name == "mise":
    if os.environ.get("FIXTURE_BUILD_MODE") == "hang":
        while True: time.sleep(0.05)
    if "--show-bin-path" in sys.argv:
        configuration = sys.argv[sys.argv.index("-c") + 1] if "-c" in sys.argv else "debug"
        print(directory / "bin" / configuration)
    else:
        sys.exit(int(os.environ.get("FIXTURE_BUILD_CODE", "0")))
elif name == "swiftmux-agent":
    (directory / "host.executable").write_text(sys.argv[0])
    (directory / "host.pid").write_text(str(os.getpid()))
    if os.environ.get("FIXTURE_HOST_MODE") == "dead":
        sys.exit(37)
    def stop(signum, frame):
        (directory / "host.stopped").write_text("terminated")
        sys.exit(0)
    signal.signal(signal.SIGTERM, signal.SIG_IGN
                  if os.environ.get("FIXTURE_HOST_MODE") == "ignore-term" else stop)
    if os.environ.get("FIXTURE_HOST_MODE") != "never":
        (directory / "host.ready").touch()
    while True: time.sleep(0.05)
elif name == "swifttyd":
    (directory / "probe.pid").write_text(str(os.getpid()))
    (directory / "probe.config").write_text(os.environ["SWIFTMUX_ROAMING_CONFIG"])
    if os.environ.get("FIXTURE_PROBE_MODE") == "hang":
        while True: time.sleep(0.05)
    sys.exit(0 if (directory / "host.ready").exists() else 3)
elif name == "xcodegen":
    if os.environ.get("FIXTURE_GENERATE_MODE") == "hang":
        while True: time.sleep(0.05)
    spec = Path(sys.argv[sys.argv.index("--spec") + 1])
    (directory / "project.json").write_bytes(spec.read_bytes())
    sys.exit(int(os.environ.get("FIXTURE_GENERATE_CODE", "0")))
elif name == "xcodebuild":
    if os.environ.get("FIXTURE_XCODE_IGNORE_TERM") == "1":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (directory / "test.socket").write_text(os.environ["TEST_RUNNER_RST_CONTROL_SOCKET"])
    (directory / "test.started").touch()
    if os.environ.get("FIXTURE_XCODE_MODE") == "hang":
        (directory / "xcode.pid").write_text(str(os.getpid()))
        while True: time.sleep(0.05)
    print("Test Case 'testRoamingSessionSurvivesBackgroundingInSimulatorRuntime' passed")
    sys.exit(int(os.environ.get("FIXTURE_XCODE_CODE", "0")))
elif name == "xcrun":
    default = {"result": "Passed", "totalTestCount": 1, "passedTests": 1,
               "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
    print(os.environ.get("FIXTURE_SUMMARY", json.dumps(default)))
'''


class SimulatorDriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="roaming-driver-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "repo with 'quotes'"
        scripts = self.root / "Scripts"
        scripts.mkdir(parents=True)
        for name in ["roaming-simulator.py", "test-roaming-simulator.sh", "real_ssh_commands.py"]:
            shutil.copyfile(ROOT / "Scripts" / name, scripts / name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name in ["mise", "swiftmux-agent", "swmux-launcher", "swifttyd",
                     "xcodegen", "xcodebuild", "xcrun"]:
            tool = self.bin / name
            body = TOOL.replace('name = Path(sys.argv[0]).name',
                                'name = Path(sys.argv[0]).name\n' + TOOL_LEASE, 1)
            tool.write_text(body.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
            tool.chmod(0o755)
        (self.bin / "python3").symlink_to(sys.executable)
        for configuration in ["debug", "release"]:
            selected = self.bin / configuration
            selected.mkdir()
            for product in ["swiftmux-agent", "swmux-launcher", "swifttyd"]:
                (selected / product).symlink_to(self.bin / product)
        self.environment = {**os.environ, "FIXTURE_DIRECTORY": str(self.directory),
                            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}
        self.workspaces = set()
        self.addCleanup(self.remove_workspaces)
        self.leases = OwnedToolLeases(self.directory)
        self.addCleanup(self.leases.close)
        self.environment.update(self.leases.environment)

    def remove_workspaces(self):
        for workspace in self.workspaces:
            shutil.rmtree(workspace, ignore_errors=True)

    def command(self, args=()):
        return ["/bin/sh", str(self.root / "Scripts/test-roaming-simulator.sh"),
                "fixture-device", *args]

    def calls(self):
        file = self.directory / "calls.jsonl"
        return [json.loads(line)[0] for line in file.read_text().splitlines()] if file.exists() else []

    def remember_workspace(self, stdout):
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        for line in stdout.splitlines():
            if line.startswith("Workspace (results and host log): "):
                self.workspaces.add(Path(line.split(": ", 1)[1]))

    def run_driver(self, args=(), timeout=15, **settings):
        for name in ["host.ready", "host.stopped", "host.pid", "probe.pid",
                     "test.started", "xcode.pid"]:
            (self.directory / name).unlink(missing_ok=True)
        with self.running_driver(args, **settings) as process:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                self.remember_workspace(error.stdout or "")
                raise
            self.remember_workspace(stdout)
            return subprocess.CompletedProcess(process.args, process.returncode,
                                               stdout, stderr)

    @contextmanager
    def running_driver(self, args=(), **settings):
        process = subprocess.Popen(self.command(args),
                                   env={**self.environment, **settings,
                                        **self.leases.begin_run()},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        failed = False
        try:
            yield process
        except BaseException:
            failed = True
            raise
        finally:
            try:
                self.retire_driver(process)
            except Exception as error:
                if not failed:
                    raise
                # unittest records this cleanup separately from the original
                # timeout/assertion, rather than replacing that primary error.
                def report_cleanup(error=error):
                    raise error
                self.addCleanup(report_cleanup)
            finally:
                process.stdout.close()
                process.stderr.close()

    def retire_driver(self, process):
        if process.poll() is None:
            try:
                process.terminate()
            except ProcessLookupError:
                pass
        try:
            try:
                stdout, _ = process.communicate(timeout=1)
            except subprocess.TimeoutExpired as error:
                self.remember_workspace(error.stdout or "")
                if process.poll() is None:
                    process.kill()
                # A fake tool may hold an inherited output pipe after the
                # driver dies. Stop owned tools before draining those pipes.
                try:
                    self.leases.stop_pending()
                finally:
                    stdout, _ = process.communicate(timeout=5)
            self.remember_workspace(stdout)
        finally:
            self.leases.stop_pending()

    def wait_for_marker(self, name, process):
        deadline = time.monotonic() + 5
        while not (self.directory / name).exists():
            self.assertLess(time.monotonic(), deadline)
            self.assertIsNone(process.poll())
            time.sleep(0.01)

    def test_outer_timeout_retires_separate_host_and_running_tool(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_driver(timeout=2, FIXTURE_XCODE_MODE="hang")
        self.assertTrue((self.directory / "xcode.pid").exists())
        self.assert_owned_tools_retired({"swiftmux-agent", "xcodebuild"})
        self.assertEqual(len(self.workspaces), 1)

    def test_failed_assertion_retires_separate_host_and_running_tool(self):
        with self.assertRaisesRegex(AssertionError, "deliberate fixture failure"):
            with self.running_driver(FIXTURE_XCODE_MODE="hang") as process:
                self.wait_for_marker("xcode.pid", process)
                raise AssertionError("deliberate fixture failure")
        self.assert_owned_tools_retired({"swiftmux-agent", "xcodebuild"})
        self.assertEqual(len(self.workspaces), 1)

    def assert_owned_tools_retired(self, expected):
        identities = self.leases.last_retired
        self.assertTrue(expected <= {item["tool"] for item in identities})
        # The positive lifetime connection identifies what we await. No
        # deletion or nonzero signal is based on a numeric PID observation.
        deadline = time.monotonic() + 5
        for item in identities:
            while True:
                try:
                    os.kill(item["pid"], 0)
                except ProcessLookupError:
                    break
                self.assertLess(time.monotonic(), deadline,
                                "owned tool has not been reaped")
                time.sleep(0.01)

    def test_outer_timeout_collects_tools_at_each_setup_phase(self):
        cases = [({"FIXTURE_BUILD_MODE": "hang"}, {"mise"}),
                 ({"FIXTURE_PROBE_MODE": "hang"},
                  {"swiftmux-agent", "swifttyd"}),
                 ({"FIXTURE_GENERATE_MODE": "hang"},
                  {"swiftmux-agent", "xcodegen"})]
        for settings, expected in cases:
            with self.subTest(settings=settings):
                with self.assertRaises(subprocess.TimeoutExpired):
                    self.run_driver(timeout=2, **settings)
                self.assert_owned_tools_retired(expected)
        self.assertEqual(len(self.workspaces), 3)

    def test_driver_ignoring_term_is_killed_without_stranding_tools(self):
        path = self.root / "Scripts/roaming-simulator.py"
        text = path.read_text()
        self.assertIn("signal.signal(signal.SIGTERM, interrupt)", text)
        path.write_text(text.replace("signal.signal(signal.SIGTERM, interrupt)",
                                     "signal.signal(signal.SIGTERM, signal.SIG_IGN)"))
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_driver(timeout=2, FIXTURE_XCODE_MODE="hang")
        self.assert_owned_tools_retired({"swiftmux-agent", "xcodebuild"})
        self.assertEqual(len(self.workspaces), 1)

    def test_pid_file_cannot_authorize_stopping_an_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            with self.assertRaisesRegex(AssertionError, "deliberate fixture failure"):
                with self.running_driver(FIXTURE_XCODE_MODE="hang") as process:
                    self.wait_for_marker("xcode.pid", process)
                    (self.directory / "host.pid").write_text(str(unrelated.pid))
                    (self.directory / "xcode.pid").write_text(str(unrelated.pid))
                    raise AssertionError("deliberate fixture failure")
            self.assertIsNone(unrelated.poll())
            self.assert_owned_tools_retired({"swiftmux-agent", "xcodebuild"})
        finally:
            if unrelated.poll() is None:
                unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_tools_ignoring_term_are_retired_by_their_lifetime_guard(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_driver(timeout=2, FIXTURE_XCODE_MODE="hang",
                            FIXTURE_XCODE_IGNORE_TERM="1",
                            FIXTURE_HOST_MODE="ignore-term")
        self.assert_owned_tools_retired({"swiftmux-agent", "xcodebuild"})

    def test_late_and_previous_run_tools_cannot_start_their_command_body(self):
        old_environment = dict(self.environment)
        self.leases.stop_pending()
        for fresh_run in [False, True]:
            with self.subTest(fresh_run=fresh_run):
                if fresh_run:
                    self.leases.begin_run()
                result = subprocess.run([str(self.bin / "swiftmux-agent")],
                                        env=old_environment, capture_output=True,
                                        text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("lifetime connection refused", result.stderr)
                self.assertEqual(self.calls(), [])
                self.assertFalse((self.directory / "host.pid").exists())

    def test_cleanup_error_is_reported_separately_from_the_body_failure(self):
        retire = self.retire_driver
        def failing_cleanup(process):
            retire(process)
            raise RuntimeError("injected cleanup failure")
        with mock.patch.object(self, "retire_driver", failing_cleanup):
            with mock.patch.object(self, "addCleanup") as report:
                with self.assertRaisesRegex(AssertionError, "deliberate fixture failure"):
                    with self.running_driver(FIXTURE_XCODE_MODE="hang") as process:
                        self.wait_for_marker("xcode.pid", process)
                        raise AssertionError("deliberate fixture failure")
                report.assert_called_once()
                with self.assertRaisesRegex(RuntimeError, "injected cleanup failure"):
                    report.call_args.args[0]()
        self.assert_owned_tools_retired({"swiftmux-agent", "xcodebuild"})

    def assert_stopped(self):
        self.assertTrue((self.directory / "host.stopped").exists())
        pid = int((self.directory / "host.pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_valid_platforms_generate_matching_projects_and_cleanup(self):
        for platform in ["iOS", "tvOS", "visionOS"]:
            with self.subTest(platform=platform):
                result = self.run_driver((platform,))
                self.assertEqual(result.returncode, 0, result.stderr)
                project = json.loads((self.directory / "project.json").read_text())
                self.assertEqual(project["targets"]["RoamingRuntimeTests"]["platform"], platform)
                sources = project["targets"]["RoamingRuntimeTests"]["sources"]
                self.assertEqual(len(sources), 4)
                self.assertTrue(all(source["path"].startswith(str(self.root.resolve())) for source in sources))
                self.assert_stopped()
                probe = Path((self.directory / "probe.config").read_text())
                self.assertEqual((self.directory / "test.socket").read_text(),
                                 str(probe.parent / "state/control.sock"))

    def test_invalid_platform_or_usage_starts_no_tools(self):
        for args in [("watchOS",), ("",), ("iOS", "extra")]:
            with self.subTest(args=args):
                self.assertEqual(self.run_driver(args).returncode, 2)
                self.assertEqual(self.calls(), [])
        for args in [[], [""], ["  "]]:
            result = subprocess.run(
                ["/bin/sh", str(self.root / "Scripts/test-roaming-simulator.sh"), *args],
                env=self.environment, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(self.calls(), [])

    def test_configuration_selects_matching_host_products_and_simulator(self):
        for option, configuration in [((), "debug"), (("--configuration", "debug"), "debug"),
                                      (("--configuration", "release"), "release")]:
            with self.subTest(configuration=configuration, option=option):
                (self.directory / "calls.jsonl").unlink(missing_ok=True)
                result = self.run_driver(("tvOS", *option))
                self.assertEqual(result.returncode, 0, result.stderr)
                if result.returncode:
                    continue
                calls = [json.loads(line) for line in
                         (self.directory / "calls.jsonl").read_text().splitlines()]
                swift = [args for name, args in calls if name == "mise"]
                prefix = ["exec", "--", "swift", "build", "-c", configuration]
                self.assertEqual(swift, [prefix + ["--product", p] for p in
                                        ["swiftmux-agent", "swmux-launcher", "swifttyd"]]
                                 + [prefix + ["--show-bin-path"]])
                self.assertEqual(Path((self.directory / "host.executable").read_text()),
                                 self.bin / configuration / "swiftmux-agent")
                xcode = next(args for name, args in calls if name == "xcodebuild")
                self.assertIn("-configuration", xcode)
                if "-configuration" in xcode:
                    self.assertEqual(xcode[xcode.index("-configuration") + 1],
                                     configuration.capitalize())
                self.assert_stopped()

    def test_invalid_configuration_starts_no_tools(self):
        for value in ["Release", "profile", ""]:
            with self.subTest(value=value):
                result = self.run_driver(("--configuration", value))
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.calls(), [])

    def test_dead_host_prevents_xcode_and_is_reaped(self):
        result = self.run_driver(FIXTURE_HOST_MODE="dead")
        self.assertEqual(result.returncode, 1)
        self.assertIn("host exited before readiness (37)", result.stderr)
        self.assertNotIn("xcodegen", self.calls())
        pid = int((self.directory / "host.pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_build_failure_starts_no_host(self):
        result = self.run_driver(FIXTURE_BUILD_CODE="61")
        self.assertEqual(result.returncode, 61)
        self.assertNotIn("swiftmux-agent", self.calls())

    def test_generator_failure_preserves_status_and_closes_host(self):
        result = self.run_driver(FIXTURE_GENERATE_CODE="62")
        self.assertEqual(result.returncode, 62)
        self.assertNotIn("xcodebuild", self.calls())
        self.assert_stopped()

    def test_xcode_failure_preserves_status_and_skips_result_claim(self):
        result = self.run_driver(FIXTURE_XCODE_CODE="73")
        self.assertEqual(result.returncode, 73)
        self.assertNotIn("xcrun", self.calls())
        self.assert_stopped()

    def test_exit_zero_without_an_actual_pass_is_refused(self):
        for report in [
            {"result": "Passed", "totalTestCount": 0, "passedTests": 0},
            {"result": "Skipped", "totalTestCount": 1, "passedTests": 0},
            {"result": "Failed", "totalTestCount": 1, "passedTests": 1},
            [], "not a summary",
        ]:
            with self.subTest(report=report):
                result = self.run_driver(FIXTURE_SUMMARY=json.dumps(report))
                self.assertEqual(result.returncode, 1)
                self.assert_stopped()

    def test_summary_counts_require_one_real_pass_and_no_failures(self):
        base = {"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
        for key, bad in [("totalTestCount", 2), ("passedTests", True),
                         ("failedTests", 1), ("skippedTests", 1),
                         ("expectedFailures", 1)]:
            with self.subTest(key=key):
                report = {**base, key: bad}
                result = self.run_driver(FIXTURE_SUMMARY=json.dumps(report))
                self.assertEqual(result.returncode, 1)
                self.assert_stopped()

    def test_hung_readiness_probe_has_overall_deadline_and_is_killed(self):
        with (self.directory / "host.log").open("w") as log:
            host = subprocess.Popen([str(self.bin / "swiftmux-agent")],
                                    env=self.environment, stdout=log, stderr=log)
            try:
                original = dict(os.environ)
                os.environ.update(self.environment)
                os.environ["FIXTURE_PROBE_MODE"] = "hang"
                try:
                    with self.assertRaisesRegex(DRIVER.FixtureError, "readiness timed out"):
                        DRIVER.wait_for_host(host, self.bin / "swifttyd",
                                             self.directory / "config.json", log, timeout=0.2)
                finally:
                    os.environ.clear()
                    os.environ.update(original)
            finally:
                DRIVER.stop_host(host)
        pid = int((self.directory / "probe.pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assert_stopped()

    def test_host_ignoring_term_is_killed_and_reaped(self):
        code = "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(30)"
        host = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE)
        try:
            self.assertEqual(host.stdout.readline(), b"ready\n")
            DRIVER.stop_host(host, grace=0.05)
            self.assertEqual(host.returncode, -signal.SIGKILL)
        finally:
            if host.poll() is None:
                host.kill()
                host.wait(timeout=5)
            host.stdout.close()

    def test_interrupt_after_host_spawn_reaps_child_before_propagating(self):
        spawn = subprocess.Popen
        for signum in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=signum):
                children = []

                def interrupt(signum, frame):
                    raise DRIVER.Interrupted(signum)

                def spawn_and_interrupt(*args, **kwargs):
                    child = spawn(*args, **kwargs)
                    # Keep a separate handle for cleanup of the broken baseline.
                    children.append(child)
                    os.kill(os.getpid(), signum)
                    return child

                previous = signal.signal(signum, interrupt)
                try:
                    with (self.directory / "spawn.log").open("w") as log:
                        with mock.patch.object(DRIVER.subprocess, "Popen", spawn_and_interrupt):
                            with self.assertRaises(DRIVER.Interrupted) as caught:
                                with DRIVER.managed_host(["/bin/sleep", "30"], log):
                                    self.fail("interrupted startup entered its body")
                    self.assertEqual(caught.exception.signum, signum)
                    self.assertEqual(len(children), 1)
                    self.assertIsNotNone(children[0].returncode,
                                         "interrupted host startup did not reap its child")
                finally:
                    signal.signal(signum, previous)
                    for child in children:
                        if child.poll() is None:
                            child.kill()
                        child.wait(timeout=3)

    def test_host_spawn_failure_preserves_original_error(self):
        with (self.directory / "spawn.log").open("w") as log:
            with self.assertRaises(FileNotFoundError):
                with DRIVER.managed_host([str(self.directory / "missing-host")], log):
                    self.fail("failed startup entered its body")

    def test_interrupt_closes_running_xcode_and_host(self):
        with self.running_driver(FIXTURE_XCODE_MODE="hang") as process:
            self.wait_for_marker("xcode.pid", process)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.remember_workspace(stdout)
            self.assertEqual(process.returncode, 143, stderr)
            self.assert_stopped()
            pid = int((self.directory / "xcode.pid").read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
