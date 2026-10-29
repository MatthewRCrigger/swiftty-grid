"""Execute the UI wrapper with private fake tools; no Xcode or SSH resources."""

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

from owned_tool_leases import OwnedToolLeases, TOOL_LEASE

ROOT = Path(__file__).resolve().parents[2]

TOOL = r'''#!/PYTHON
import json, os, signal, subprocess, sys, time
from pathlib import Path
directory = Path(os.environ["FIXTURE_DIRECTORY"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (directory / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps({"name": name, "args": args, "cwd": os.getcwd()}) + "\n")
if name == "real-ssh-env.sh":
    workspace = directory / "workspace with 'quotes'"
    if args == ["start"]:
        workspace.mkdir()
        (workspace / "container.name").write_text("owned-fake-container\n")
        (workspace / "env").write_text("""export RST_REAL_SSH_HOST=127.0.0.1
export RST_REAL_SSH_PORT=1234
export RST_REAL_SSH_USER=fixture
export RST_REAL_SSH_PASSWORD=fixture
export RST_REAL_SSH_FINGERPRINT=SHA256:fixture
if [ "${FIXTURE_FAIL_STAGE:-}" = source ]; then return 33; fi
if [ "${FIXTURE_SIGNAL_STAGE:-}" = source ]; then
    kill -"$FIXTURE_SIGNAL" "$$"
    printf 'resumed after signal\\n' > "$FIXTURE_DIRECTORY/source.resumed"
fi
""")
        print(workspace / "env")
    else:
        assert args == ["stop", str(workspace)], args
        count_file = directory / "stop.count"
        count = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(count))
        # Run the real process-retirement path, without a real VM marker.
        (workspace / "container.name").unlink(missing_ok=True)
        stopped = subprocess.run(["/bin/sh", str(Path(__file__).with_name("owned-ssh-env.sh")),
                                  "stop", str(workspace)])
        if stopped.returncode: sys.exit(stopped.returncode)
        if os.environ.get("FIXTURE_XCODE_HANG") and not os.environ.get("FIXTURE_XCODE_IGNORE_TERM"):
            assert (directory / "xcodebuild.stopped").exists(), "build survived fixture stop"
        if count == 1 and os.environ.get("FIXTURE_SIGNAL_STAGE") == "cleanup":
            # This is the immediate parent created by the test wrapper.
            os.kill(os.getppid(), getattr(signal, "SIG" + os.environ["FIXTURE_SIGNAL"]))
        sys.exit(int(os.environ.get("FIXTURE_STOP_CODE", "0")))
elif name == "container":
    assert args[:2] == ["exec", "owned-fake-container"], args
    if os.environ.get("FIXTURE_FAIL_STAGE") == "container": sys.exit(31)
    if os.environ.get("FIXTURE_SIGNAL_STAGE") == "container":
        os.kill(os.getppid(), getattr(signal, "SIG" + os.environ["FIXTURE_SIGNAL"]))
elif name == "xcodegen":
    (directory / "generated.yml").write_bytes(Path("project.yml").read_bytes())
    if os.environ.get("FIXTURE_FAIL_STAGE") == "xcodegen": sys.exit(32)
elif name == "xcodebuild":
    if os.environ.get("FIXTURE_XCODE_HANG"):
        exec(TOOL_LEASE_SOURCE)
        def stop(signum, frame):
            (directory / "xcodebuild.stopped").touch()
            raise SystemExit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN
                      if os.environ.get("FIXTURE_XCODE_IGNORE_TERM") else stop)
        (directory / "xcodebuild.ready").touch()
        while True: time.sleep(0.01)
    if os.environ.get("RST_UI_ADVERTISE"):
        deadline = time.monotonic() + 3
        while not (directory / "advertise.ready").exists():
            if time.monotonic() >= deadline: raise RuntimeError("advertiser did not start")
            time.sleep(0.01)
    print("TEST SUCCEEDED" if os.environ.get("FIXTURE_UI_CODE", "0") == "0" else "TEST FAILED")
    sys.exit(int(os.environ.get("FIXTURE_UI_CODE", "0")))
else:
    raise AssertionError(name)
'''

ADVERTISER = ('''#!/PYTHON
import json, os, signal, time
from pathlib import Path
name = "dns-sd"
''' + TOOL_LEASE + r'''
directory = Path(os.environ["FIXTURE_DIRECTORY"])
def stop(signum, frame):
    (directory / "advertise.stopped").touch()
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN
              if os.environ.get("FIXTURE_ADVERTISE_IGNORE_TERM") else stop)
(directory / "advertise.ready").write_text(str(os.getpid()))
while True: time.sleep(0.01)
''')


class AppUICleanupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="app-ui-cleanup-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        scripts = self.directory / "repo with 'quotes'" / "Scripts"
        scripts.mkdir(parents=True)
        self.script = scripts / "test-app-ui.sh"
        shutil.copyfile(ROOT / "Scripts/test-app-ui.sh", self.script)
        shutil.copyfile(ROOT / "Scripts/real-ssh-env.sh", scripts / "owned-ssh-env.sh")
        shutil.copyfile(ROOT / "Scripts/real-ssh-process.py", scripts / "real-ssh-process.py")
        binary_directory = self.directory / "bin"
        binary_directory.mkdir()
        for file in [scripts / "real-ssh-env.sh", *[
            binary_directory / name for name in ["container", "xcodegen", "xcodebuild"]
        ]]:
            file.write_text(TOOL.replace("#!/PYTHON", "#!" + sys.executable, 1)
                            .replace("TOOL_LEASE_SOURCE", repr(TOOL_LEASE)))
            file.chmod(0o755)
        advertiser = binary_directory / "dns-sd"
        advertiser.write_text(ADVERTISER.replace("#!/PYTHON", "#!" + sys.executable, 1))
        advertiser.chmod(0o755)
        (binary_directory / "python3").symlink_to(sys.executable)
        self.environment = {**os.environ, "FIXTURE_DIRECTORY": str(self.directory),
                            "PATH": str(binary_directory) + os.pathsep + "/usr/bin:/bin"}
        self.environment.pop("RST_PUBLIC_HOST", None)
        self.environment.pop("RST_UI_ADVERTISE", None)
        for name in list(self.environment):
            if name.startswith("FIXTURE_") and name != "FIXTURE_DIRECTORY":
                self.environment.pop(name)
        self.leases = OwnedToolLeases(self.directory)
        self.addCleanup(self.leases.close)

    def prepare(self, destination="platform=macOS,variant=Mac Catalyst", arguments=()):
        self.leases.stop_pending()
        for name in ["calls.jsonl", "stop.count", "source.resumed", "generated.yml",
                     "advertise.ready", "advertise.stopped", "xcodebuild.ready",
                     "xcodebuild.stopped"]:
            (self.directory / name).unlink(missing_ok=True)
        workspace = self.directory / "workspace with 'quotes'"
        if workspace.exists():
            shutil.rmtree(workspace)
        argv = [] if destination is None else [destination, *arguments]
        return ["/bin/sh", str(self.script), *argv]

    def invoke(self, destination="platform=macOS,variant=Mac Catalyst", arguments=(), **settings):
        return subprocess.run(self.prepare(destination, arguments),
                              env={**self.environment, **settings, **self.leases.begin_run()},
                              capture_output=True, text=True, timeout=15)

    def test_interrupt_retires_active_build_before_stopping_fixture(self):
        for signum, status in [(signal.SIGINT, 130), (signal.SIGTERM, 143)]:
            for ignore_term in ["", "1"]:
                with self.subTest(signal=signum, ignore_term=ignore_term):
                    command = self.prepare()
                    process = subprocess.Popen(
                        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                        env={**self.environment, **self.leases.begin_run(),
                             "RST_UI_ADVERTISE": "Private fixture", "FIXTURE_XCODE_HANG": "1",
                             "FIXTURE_XCODE_IGNORE_TERM": ignore_term,
                             "FIXTURE_STOP_CODE": "9" if ignore_term else "0"})
                    try:
                        deadline = time.monotonic() + 5
                        while not all((self.directory / name).exists()
                                      for name in ["xcodebuild.ready", "advertise.ready"]):
                            self.assertIsNone(process.poll(), "wrapper exited before build started")
                            self.assertLess(time.monotonic(), deadline, "build did not start")
                            time.sleep(0.01)
                        process.send_signal(signum)
                        _, error = process.communicate(timeout=10)
                        self.assertEqual(process.returncode, status, error)
                        self.leases.wait_stopped(timeout=1)
                        self.assert_cleaned_once()
                        workspace = self.directory / "workspace with 'quotes'"
                        self.assertEqual((workspace / "xcodebuild.status").read_text(),
                                         "-9" if ignore_term else "0")
                        for role in ["xcodebuild", "advertiser"]:
                            for suffix in ["pid", "owner"]:
                                self.assertFalse((workspace / f"{role}.{suffix}").exists())
                        self.assertTrue((self.directory / "advertise.stopped").exists())
                        if not ignore_term:
                            self.assertTrue((self.directory / "xcodebuild.stopped").exists())
                    finally:
                        # Independent lifetime guards retire fake tools even on a
                        # broken wrapper; only this direct Popen handle is signaled.
                        self.leases.stop_pending()
                        try:
                            process.communicate(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.communicate(timeout=3)

    def calls(self, name=None):
        path = self.directory / "calls.jsonl"
        result = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call for call in result if name is None or call["name"] == name]

    def assert_cleaned_once(self):
        calls = self.calls("real-ssh-env.sh")
        self.assertEqual([call["args"][0] for call in calls], ["start", "stop"])
        self.assertEqual((self.directory / "stop.count").read_text(), "1")

    def test_completed_ui_run_preserves_primary_status_and_reports_cleanup_failure(self):
        for ui_code in [0, 7]:
            for stop_code in [0, 9]:
                with self.subTest(ui=ui_code, stop=stop_code):
                    result = self.invoke(FIXTURE_UI_CODE=str(ui_code), FIXTURE_STOP_CODE=str(stop_code))
                    if ui_code:
                        self.assertEqual(result.returncode, ui_code, result.stderr)
                    elif stop_code:
                        self.assertNotEqual(result.returncode, 0, result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                    self.assert_cleaned_once()
                    self.assertEqual(len(self.calls("xcodebuild")), 1)
                    if stop_code:
                        self.assertIn("fixture cleanup incomplete:", result.stderr)

    def test_setup_failures_preserve_status_and_do_not_run_ui_tests(self):
        for stage, code in [("source", 33), ("container", 31), ("xcodegen", 32)]:
            for stop_code in [0, 9]:
                with self.subTest(stage=stage, stop=stop_code):
                    result = self.invoke(FIXTURE_FAIL_STAGE=stage, FIXTURE_STOP_CODE=str(stop_code))
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assert_cleaned_once()
                    self.assertFalse(self.calls("xcodebuild"))

    def test_source_interrupt_exits_without_resuming_and_cleans_once(self):
        self.check_interrupt("source")

    def test_container_interrupt_exits_without_running_xcode_and_cleans_once(self):
        self.check_interrupt("container")

    def check_interrupt(self, stage):
        for signum, status in [("INT", 130), ("TERM", 143)]:
            for stop_code in [0, 9]:
                with self.subTest(stage=stage, signal=signum, stop=stop_code):
                    result = self.invoke(FIXTURE_SIGNAL_STAGE=stage, FIXTURE_SIGNAL=signum,
                                         FIXTURE_STOP_CODE=str(stop_code))
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assert_cleaned_once()
                    self.assertFalse((self.directory / "source.resumed").exists())
                    self.assertFalse(self.calls("xcodegen"))
                    self.assertFalse(self.calls("xcodebuild"))

    def test_secondary_signal_during_cleanup_cannot_repeat_or_abort_it(self):
        for signum in ["INT", "TERM"]:
            for ui_code in [0, 7]:
                for stop_code in [0, 9]:
                    with self.subTest(signal=signum, ui=ui_code, stop=stop_code):
                        result = self.invoke(FIXTURE_SIGNAL_STAGE="cleanup", FIXTURE_SIGNAL=signum,
                                             FIXTURE_UI_CODE=str(ui_code), FIXTURE_STOP_CODE=str(stop_code))
                        self.assert_cleaned_once()
                        if ui_code:
                            self.assertEqual(result.returncode, ui_code, result.stderr)
                        elif stop_code:
                            self.assertNotEqual(result.returncode, 0, result.stderr)
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)

    def test_destination_and_xcodebuild_arguments_are_preserved(self):
        destinations = [
            ("platform=macOS,variant=Mac Catalyst", "CatalystClient"),
            ("platform=iOS Simulator,id=fixture", "MobileClient"),
            ("platform=iOS,id=fixture", "MobileClient"),
        ]
        arguments = ["-only-testing:AppUITests/Fixture/testMethod", "-quiet"]
        for destination, app in destinations:
            with self.subTest(destination=destination):
                result = self.invoke(destination, arguments, RST_PUBLIC_HOST="192.0.2.1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_cleaned_once()
                args = self.calls("xcodebuild")[0]["args"]
                self.assertEqual(args[args.index("-destination") + 1], destination)
                self.assertEqual(args[-3:], [*arguments, "test"])
                self.assertIn("  " + app + ":", (self.directory / "generated.yml").read_text())

    def test_argument_errors_do_not_start_resources(self):
        for destination in [None, "platform=unsupported", ""]:
            with self.subTest(destination=destination):
                result = self.invoke(destination)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.calls())

    def test_advertiser_is_retired_after_success_and_failure(self):
        for settings, status in [({}, 0), ({"FIXTURE_UI_CODE": "7"}, 7),
                                 ({"FIXTURE_STOP_CODE": "9"}, 1),
                                 ({"FIXTURE_UI_CODE": "7", "FIXTURE_STOP_CODE": "9"}, 7)]:
            with self.subTest(settings=settings):
                result = self.invoke(RST_UI_ADVERTISE="Private fixture", **settings)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assert_cleaned_once()
                self.leases.wait_stopped(timeout=1)
                self.assertTrue((self.directory / "advertise.stopped").exists())

    def test_term_ignoring_advertiser_is_reaped_before_wrapper_returns(self):
        result = self.invoke(RST_UI_ADVERTISE="Private fixture",
                             FIXTURE_ADVERTISE_IGNORE_TERM="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.leases.wait_stopped(timeout=1)
        self.assert_cleaned_once()
        workspace = self.directory / "workspace with 'quotes'"
        self.assertFalse((workspace / "advertiser.pid").exists())
        self.assertFalse((workspace / "advertiser.owner").exists())

    def test_advertiser_spawn_failure_stops_fixture_without_running_xcode(self):
        source = self.script.read_text()
        self.assertIn("    dns-sd -R", source)
        self.script.write_text(source.replace("    dns-sd -R",
                                              "    missing-advertiser-for-test -R", 1))
        result = self.invoke(RST_UI_ADVERTISE="Private fixture")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_cleaned_once()
        self.assertFalse(self.calls("xcodebuild"))
        workspace = self.directory / "workspace with 'quotes'"
        self.assertFalse((workspace / "advertiser.pid").exists())
        self.assertFalse((workspace / "advertiser.owner").exists())

    def test_build_spawn_failure_stops_advertiser_and_fixture(self):
        source = self.script.read_text()
        self.assertIn("  xcodebuild -project", source)
        self.script.write_text(source.replace("  xcodebuild -project",
                                              "  missing-build-for-test -project", 1))
        result = self.invoke(RST_UI_ADVERTISE="Private fixture")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_cleaned_once()
        self.leases.wait_stopped(timeout=1)
        workspace = self.directory / "workspace with 'quotes'"
        for role in ["xcodebuild", "advertiser"]:
            for suffix in ["pid", "owner"]:
                self.assertFalse((workspace / f"{role}.{suffix}").exists())

    def test_missing_device_public_host_cleans_and_preserves_usage_error(self):
        for stop_code in [0, 9]:
            with self.subTest(stop=stop_code):
                result = self.invoke("platform=iOS,id=fixture", FIXTURE_STOP_CODE=str(stop_code))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assert_cleaned_once()
                self.assertFalse(self.calls("xcodegen"))


if __name__ == "__main__":
    unittest.main()
