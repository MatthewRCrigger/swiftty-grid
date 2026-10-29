"""Run the complete platform-build reporter with private, finite fake tools."""

import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCHEMES = ["MobileClient", "CatalystClient", "VisionClient", "TVClient",
           "WatchCompanion"]
TOOL = r'''#!/PYTHON
import json, os, plistlib, resource, sys, tempfile
from pathlib import Path
# The write-limit probe applies to the report shell, not fake build logs.
soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
resource.setrlimit(resource.RLIMIT_FSIZE, (hard, hard))
directory = Path(os.environ["FIXTURE_DIRECTORY"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (directory / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps({"name": name, "args": args, "cwd": os.getcwd()}) + "\n")
def break_report(stage):
    mode = os.environ.get("FIXTURE_BREAK_REPORT")
    evidence = Path(os.environ["FIXTURE_EVIDENCE"])
    if mode == "recover-initial" and stage == "MobileClient":
        if evidence.is_dir(): evidence.rmdir()
        evidence.parent.mkdir(parents=True, exist_ok=True)
        evidence.touch()
    if mode == "recover-append":
        if stage == "MobileClient":
            (directory / "saved-report").write_bytes(evidence.read_bytes())
            evidence.unlink()
            evidence.mkdir()
        elif stage == "CatalystClient":
            evidence.rmdir()
            evidence.write_bytes((directory / "saved-report").read_bytes())
    if os.environ.get("FIXTURE_BREAK_REPORT") == stage:
        evidence.unlink()
        evidence.mkdir()
if name == "mktemp":
    if os.environ.get("FIXTURE_WORKSPACE_FAILURE") == "mktemp":
        print(directory / "failed-workspace")
        sys.exit(72)
    print(tempfile.mkdtemp(prefix="swiftty-platforms.", dir=directory))
elif name == "mkdir":
    if os.environ.get("FIXTURE_WORKSPACE_FAILURE") == "mkdir": sys.exit(72)
    assert args[0] == "-p", args
    Path(args[1]).mkdir(parents=True, exist_ok=True)
elif name == "xcodegen":
    root = Path(args[args.index("--project") + 1])
    generated = root / "Config/Generated"
    generated.mkdir(parents=True, exist_ok=True)
    for target in ["MobileClient", "CatalystClient", "VisionClient"]:
        (generated / (target + ".entitlements")).write_bytes(plistlib.dumps({
            "com.apple.developer.associated-domains": ["applinks:links.example.test"]}))
    bad = os.environ.get("FIXTURE_BAD_ENTITLEMENT")
    if bad == "missing": (generated / "CatalystClient.entitlements").unlink()
    elif bad == "malformed": (generated / "CatalystClient.entitlements").write_text("not a plist")
    sys.exit(int(os.environ.get("FIXTURE_GENERATE_CODE", "0")))
elif name == "xcodebuild":
    if args == ["-version"]: print("Xcode fixture 27.0")
    elif "-resolvePackageDependencies" in args:
        sys.exit(int(os.environ.get("FIXTURE_RESOLVE_CODE", "0")))
    else:
        scheme = args[args.index("-scheme") + 1]
        break_report(scheme)
        if os.environ.get("FIXTURE_MISSING_LOG") == scheme:
            derived = Path(args[args.index("-derivedDataPath") + 1])
            (derived.parent / ("logs/" + scheme + ".log")).unlink()
        if os.environ.get("FIXTURE_BAD_WARNING_FILE") == scheme:
            derived = Path(args[args.index("-derivedDataPath") + 1])
            (derived.parent / ("logs/" + scheme + ".warnings")).mkdir()
        if not os.environ.get("FIXTURE_NO_WARNINGS"):
            print("/private/repo/Apps/Shared/File.swift:12:8: warning: fixture warning")
        if scheme == "WatchCompanion" and os.environ.get("FIXTURE_WATCH_FORBIDDEN"):
            print("Building SSHClient")
        if scheme in json.loads(os.environ.get("FIXTURE_FAILED_SCHEMES", "[]")):
            print("error: controlled build failure")
            sys.exit(73)
elif name == "swift":
    if args == ["--version"]:
        print("libSwiftScan ignored fixture warning\nSwift fixture 6.4")
        if os.environ.get("FIXTURE_VERSION_FAILURE") == "swift": sys.exit(75)
    else:
        assert args == ["build", "--product", "swifttyd"], args
        break_report("swifttyd")
        sys.exit(int(os.environ.get("FIXTURE_SWIFT_CODE", "0")))
elif name == "xcrun":
    print("Swift Xcode fixture" if args == ["swift", "--version"] else "27.0")
    if args == ["swift", "--version"] and os.environ.get("FIXTURE_VERSION_FAILURE") == "xcrun":
        sys.exit(75)
elif name == "git":
    if "rev-parse" in args: print("fixture-revision")
elif name == "sw_vers": print("fixture-macOS")
elif name == "uname": print("fixture-arm64")
elif name == "cat":
    if os.environ.get("FIXTURE_CAT_CODE"):
        print("controlled evidence publication failure", file=sys.stderr)
        sys.exit(int(os.environ["FIXTURE_CAT_CODE"]))
    sys.stdout.write(Path(args[0]).read_text())
else: raise AssertionError(name)
'''


class PlatformBuildEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="platform-evidence-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / "repo with 'quotes'"
        scripts = self.root / "Scripts"
        scripts.mkdir(parents=True)
        self.script = scripts / "build-platforms.sh"
        shutil.copyfile(ROOT / "Scripts/build-platforms.sh", self.script)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name in ["mktemp", "mkdir", "xcodegen", "xcodebuild", "swift", "xcrun", "git",
                     "sw_vers", "uname", "cat"]:
            path = self.bin / name
            path.write_text(TOOL.replace("#!/PYTHON", "#!" + sys.executable, 1))
            path.chmod(0o755)
        self.environment = {**os.environ, "FIXTURE_DIRECTORY": str(self.directory),
                            "PATH": str(self.bin) + ":/usr/bin:/bin",
                            "TMPDIR": str(self.directory),
                            "SWIFTTY_LINK_DOMAINS": "links.example.test"}
        for name in list(self.environment):
            if name.startswith("FIXTURE_") and name != "FIXTURE_DIRECTORY":
                self.environment.pop(name)
        self.evidence = self.directory / "build evidence 'quoted'.txt"

    def invoke(self, evidence=None, limit=None, default=False, **settings):
        (self.directory / "calls.jsonl").unlink(missing_ok=True)
        evidence = evidence or self.evidence
        def limit_report_writes():
            _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
            resource.setrlimit(resource.RLIMIT_FSIZE, (limit, hard))
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        return subprocess.run(
            ["/bin/sh", str(self.script), *([] if default else [str(evidence)])],
            env={**self.environment, **settings, "FIXTURE_EVIDENCE": str(evidence)},
            capture_output=True, text=True, timeout=15,
            preexec_fn=limit_report_writes if limit is not None else None,
        )

    def calls(self, name=None):
        path = self.directory / "calls.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call for call in calls if name is None or call["name"] == name]

    def assert_all_builds_collected(self):
        builds = [call for call in self.calls("xcodebuild") if call["args"][0] == "build"]
        self.assertEqual([call["args"][call["args"].index("-scheme") + 1]
                          for call in builds], SCHEMES)
        swift = [call for call in self.calls("swift") if call["args"][0] == "build"]
        self.assertEqual(len(swift), 1)
        self.assertEqual(Path(swift[0]["cwd"]).resolve(), self.root.resolve())

    def test_success_records_metadata_every_destination_and_scope(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_all_builds_collected()
        report = self.evidence.read_text()
        for text in ["fixture-revision", "Swift fixture 6.4", "Xcode fixture 27.0",
                     "applinks:links.example.test", "Scope of this evidence",
                     "Build-only: each product", "swifttyd", "dependency check: PASS"]:
            self.assertIn(text, report)
        self.assertNotIn("libSwiftScan", report)
        self.assertIn(report, result.stdout)
        for call in self.calls("xcodebuild"):
            if call["args"][0] == "build":
                self.assertIn("CODE_SIGNING_ALLOWED=NO", call["args"])
                self.assertIn("CODE_SIGNING_REQUIRED=NO", call["args"])
                scheme = call["args"][call["args"].index("-scheme") + 1]
                destination = call["args"][call["args"].index("-destination") + 1]
                self.assertEqual(destination, {
                    "MobileClient": "generic/platform=iOS Simulator",
                    "CatalystClient": "generic/platform=macOS,variant=Mac Catalyst",
                    "VisionClient": "generic/platform=visionOS Simulator",
                    "TVClient": "generic/platform=tvOS Simulator",
                    "WatchCompanion": "generic/platform=watchOS Simulator",
                }[scheme])
        rows = [line for line in report.splitlines() if "app-source warnings:" in line]
        self.assertEqual(len(rows), 5)
        self.assertTrue(all("PASS; app-source warnings: 1" in line for line in rows))

    def test_default_report_is_created_in_the_owned_workspace(self):
        result = self.invoke(default=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        workspace = Path(next(line[11:] for line in result.stdout.splitlines()
                              if line.startswith("Workspace: ")))
        self.assertEqual(workspace.parent, self.directory)
        self.assertTrue((workspace / "build-evidence.txt").is_file())
        self.assert_all_builds_collected()

    def test_failed_builds_and_watch_dependency_still_collect_every_target(self):
        for settings in [{"FIXTURE_FAILED_SCHEMES": '["MobileClient","TVClient"]'},
                         {"FIXTURE_SWIFT_CODE": "74"},
                         {"FIXTURE_WATCH_FORBIDDEN": "1"}]:
            with self.subTest(settings=settings):
                result = self.invoke(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assert_all_builds_collected()
                self.assertIn("FAIL", self.evidence.read_text())

    def test_initial_evidence_open_failure_never_reports_success(self):
        for evidence in [self.directory / "missing parent/report.txt", self.directory]:
            with self.subTest(evidence=evidence):
                result = self.invoke(evidence=evidence)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_all_builds_collected()

    def test_failed_append_after_a_build_never_reports_success(self):
        for stage in ["MobileClient", "WatchCompanion", "swifttyd"]:
            with self.subTest(stage=stage):
                if self.evidence.is_dir(): self.evidence.rmdir()
                result = self.invoke(FIXTURE_BREAK_REPORT=stage)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_all_builds_collected()

    def test_kernel_write_failures_after_open_never_report_success(self):
        for limit in [8, 32, 64]:
            with self.subTest(limit=limit):
                result = self.invoke(limit=limit)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_all_builds_collected()
                self.assertIn("File too large", result.stderr)
                self.assertTrue(self.evidence.is_file())

    def test_initial_write_failure_remains_failure_after_path_recovers(self):
        result = self.invoke(evidence=self.directory / "missing parent/report.txt",
                             FIXTURE_BREAK_REPORT="recover-initial")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_all_builds_collected()
        report = (self.directory / "missing parent/report.txt").read_text()
        self.assertIn("Scope of this evidence", report)
        self.assertIn(report, result.stdout)

    def test_lost_build_row_remains_failure_after_later_writes_succeed(self):
        result = self.invoke(FIXTURE_BREAK_REPORT="recover-append")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_all_builds_collected()
        report = self.evidence.read_text()
        rows = [line for line in report.splitlines() if "app-source warnings:" in line]
        self.assertEqual(len(rows), 4)
        self.assertFalse(any(row.startswith("MobileClient") for row in rows))
        self.assertIn("Scope of this evidence", report)
        self.assertIn(report, result.stdout)

    def test_failed_final_publication_never_reports_success(self):
        result = self.invoke(FIXTURE_CAT_CODE="43")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_all_builds_collected()
        self.assertIn("Scope of this evidence", self.evidence.read_text())

    def test_generator_failure_starts_no_builds(self):
        result = self.invoke(FIXTURE_GENERATE_CODE="41")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call["name"] for call in self.calls()], ["mktemp", "mkdir", "xcodegen"])

    def test_workspace_setup_failure_starts_no_generator_or_build_tools(self):
        for failure in ["mktemp", "mkdir"]:
            with self.subTest(failure=failure):
                result = self.invoke(FIXTURE_WORKSPACE_FAILURE=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(all(call["name"] in {"mktemp", "mkdir"}
                                    for call in self.calls()))

    def test_resolved_package_parse_failure_cannot_produce_success_evidence(self):
        path = self.root / "Package.resolved"
        path.write_text(json.dumps({"pins": [{"identity": "fixture-package",
                         "state": {"version": "1.2.3", "revision": "fixture-commit"}}]}))
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture-package: 1.2.3 @ fixture-commit", self.evidence.read_text())
        path.write_text("not JSON")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_all_builds_collected()

    def test_version_filter_cannot_hide_a_failed_version_command(self):
        for command in ["swift", "xcrun"]:
            with self.subTest(command=command):
                result = self.invoke(FIXTURE_VERSION_FAILURE=command)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_all_builds_collected()
                self.assertIn("Scope of this evidence", self.evidence.read_text())

    def test_unreadable_entitlements_cannot_produce_success_evidence(self):
        for bad in ["missing", "malformed"]:
            with self.subTest(bad=bad):
                result = self.invoke(FIXTURE_BAD_ENTITLEMENT=bad)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_all_builds_collected()

    def test_unreadable_build_logs_cannot_produce_success_evidence(self):
        for scheme in ["MobileClient", "WatchCompanion"]:
            with self.subTest(scheme=scheme):
                result = self.invoke(FIXTURE_MISSING_LOG=scheme)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_all_builds_collected()
                self.assertIn("app-source warnings: unavailable", self.evidence.read_text())
                if scheme == "WatchCompanion":
                    self.assertIn("dependency check: FAIL", self.evidence.read_text())

    def test_warning_output_write_failure_cannot_produce_success_evidence(self):
        result = self.invoke(FIXTURE_BAD_WARNING_FILE="MobileClient")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_all_builds_collected()
        self.assertIn("app-source warnings: unavailable", self.evidence.read_text())

    def test_builds_without_warnings_are_successful(self):
        result = self.invoke(FIXTURE_NO_WARNINGS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_all_builds_collected()
        rows = [line for line in self.evidence.read_text().splitlines()
                if "app-source warnings:" in line]
        self.assertEqual(len(rows), 5)
        self.assertTrue(all("PASS; app-source warnings: 0" in line for line in rows))


if __name__ == "__main__":
    unittest.main()
