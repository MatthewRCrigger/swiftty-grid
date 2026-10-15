"""Execute the UI wrapper with private fake tools; no Xcode or SSH resources."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]

TOOL = r'''#!/PYTHON
import json, os, signal, sys
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
    print("TEST SUCCEEDED" if os.environ.get("FIXTURE_UI_CODE", "0") == "0" else "TEST FAILED")
    sys.exit(int(os.environ.get("FIXTURE_UI_CODE", "0")))
else:
    raise AssertionError(name)
'''


class AppUICleanupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="app-ui-cleanup-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        scripts = self.directory / "repo with 'quotes'" / "Scripts"
        scripts.mkdir(parents=True)
        self.script = scripts / "test-app-ui.sh"
        shutil.copyfile(ROOT / "Scripts/test-app-ui.sh", self.script)
        binary_directory = self.directory / "bin"
        binary_directory.mkdir()
        for file in [scripts / "real-ssh-env.sh", *[
            binary_directory / name for name in ["container", "xcodegen", "xcodebuild"]
        ]]:
            file.write_text(TOOL.replace("#!/PYTHON", "#!" + sys.executable, 1))
            file.chmod(0o755)
        self.environment = {**os.environ, "FIXTURE_DIRECTORY": str(self.directory),
                            "PATH": str(binary_directory) + os.pathsep + "/usr/bin:/bin"}
        self.environment.pop("RST_PUBLIC_HOST", None)
        for name in list(self.environment):
            if name.startswith("FIXTURE_") and name != "FIXTURE_DIRECTORY":
                self.environment.pop(name)

    def invoke(self, destination="platform=macOS,variant=Mac Catalyst", arguments=(), **settings):
        for name in ["calls.jsonl", "stop.count", "source.resumed", "generated.yml"]:
            (self.directory / name).unlink(missing_ok=True)
        workspace = self.directory / "workspace with 'quotes'"
        if workspace.exists():
            shutil.rmtree(workspace)
        argv = [] if destination is None else [destination, *arguments]
        return subprocess.run(["/bin/sh", str(self.script), *argv],
                              env={**self.environment, **settings}, capture_output=True,
                              text=True, timeout=10)

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

    def test_missing_device_public_host_cleans_and_preserves_usage_error(self):
        for stop_code in [0, 9]:
            with self.subTest(stop=stop_code):
                result = self.invoke("platform=iOS,id=fixture", FIXTURE_STOP_CODE=str(stop_code))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assert_cleaned_once()
                self.assertFalse(self.calls("xcodegen"))


if __name__ == "__main__":
    unittest.main()
