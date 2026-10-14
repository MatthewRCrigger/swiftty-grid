"""Discovery and formatter failure propagation in an owned Swift tree."""

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
import json, os, signal, subprocess, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['FORMAT_CALLS'], 'a') as stream:
    stream.write(json.dumps([name, args]) + '\n')
fault = os.environ.get('FORMAT_FAULT', '')
if name == 'rg':
    if fault == 'partial-discovery':
        sys.stdout.buffer.write(b'Sources/first.swift\0')
        print('owned discovery error', file=sys.stderr)
        sys.exit(2)
    if fault == 'partial-status-one':
        sys.stdout.buffer.write(b'Sources/first.swift\0')
        sys.exit(1)
    if fault == 'signal-discovery':
        sys.stdout.buffer.write(b'Sources/first.swift\0')
        os.kill(os.getppid(), signal.SIGTERM)
        sys.exit(0)
    if fault in ['empty-success', 'empty-no-match']:
        sys.exit(0 if fault == 'empty-success' else 1)
    sys.exit(subprocess.call([os.environ['FORMAT_REAL_RG'], *args]))
files = args[4:]
package = files == ['Package.swift']
if fault == ('package-error' if package else 'source-error'):
    sys.exit(18 if package else 17)
if args[0] == 'format':
    for file in files:
        Path(file).write_text('formatted owned fixture\n')
'''


class FormatSwiftTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftty-format-wrapper-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "private repository '$' 漢"
        self.root.mkdir()
        for name in ["Sources", "Tests", "Scripts", "bin", "temporary"]:
            (self.root / name).mkdir()
        self.script = self.root / "Scripts/format-swift.sh"
        shutil.copyfile(ROOT / "Scripts/format-swift.sh", self.script)
        self.package = self.root / "Package.swift"
        self.package.write_text("owned package\n")
        (self.root / ".swift-format").write_text("{}\n")
        self.first = self.root / "Sources/first.swift"
        self.first.write_text("owned source\n")
        for name in ["rg", "swift-format"]:
            executable = self.root / "bin" / name
            executable.write_text(TOOL.replace("/PYTHON", sys.executable))
            executable.chmod(0o700)
        self.calls = self.root / "calls.jsonl"
        self.real_rg = shutil.which("rg")
        self.assertIsNotNone(self.real_rg, "rg is required by the wrapper")

    def run_script(self, *arguments, fault="", cwd=None):
        return subprocess.run(
            ["/bin/sh", str(self.script), *arguments], cwd=cwd or self.root,
            env={**os.environ, "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                 "TMPDIR": str(self.root / "temporary"), "FORMAT_CALLS": str(self.calls),
                 "FORMAT_FAULT": fault, "FORMAT_REAL_RG": self.real_rg},
            capture_output=True, text=True, timeout=10,
        )

    def commands(self):
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def format_commands(self):
        return [args for name, args in self.commands() if name == "swift-format"]

    def assert_cleaned(self):
        self.assertEqual(list((self.root / "temporary").iterdir()), [])

    def test_partial_discovery_never_formats_source_or_package(self):
        for action in ["format", "check"]:
            with self.subTest(action=action):
                self.calls.unlink(missing_ok=True)
                result = self.run_script(action, fault="partial-discovery")
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("owned discovery error", result.stderr)
                self.assertEqual(self.format_commands(), [])
                self.assertEqual(self.first.read_text(), "owned source\n")
                self.assertEqual(self.package.read_text(), "owned package\n")
                self.assert_cleaned()

    def test_usage_errors_do_not_discover_or_format_files(self):
        for arguments in [("unknown",), ("format", "unexpected"), ("check", "unexpected")]:
            with self.subTest(arguments=arguments):
                self.calls.unlink(missing_ok=True)
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertEqual(self.commands(), [])
                self.assert_cleaned()

    def test_default_format_and_explicit_modes_preserve_their_flags(self):
        for arguments, expected in [((), ["format", "--in-place"]),
                                    (("format",), ["format", "--in-place"]),
                                    (("check",), ["lint", "--strict"])]:
            with self.subTest(arguments=arguments):
                self.calls.unlink(missing_ok=True)
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = self.format_commands()
                self.assertEqual(len(commands), 2)
                self.assertTrue(all(args[:4] == expected + ["--configuration", ".swift-format"]
                                    for args in commands))
                self.assertEqual(commands[0][4:], ["Sources/first.swift"])
                self.assertEqual(commands[1][4:], ["Package.swift"])
                self.assert_cleaned()

    def test_null_separated_discovery_preserves_names_and_generated_exclusions(self):
        names = ["Sources/spaces and 'quotes' \"$`漢.swift", "Tests/line\nbreak.swift",
                 "Scripts/--option.swift", "Tests/regular.swift"]
        excluded = ["Sources/Tables.swift", "Tests/GraphemeBreakTestData.swift",
                    "Sources/GraphemeBreakTables.swift"]
        for name in names + excluded:
            (self.root / name).write_text("keep owned contents\n")
        (self.root / "Sources/ignored.txt").write_text("keep owned contents\n")
        result = self.run_script("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        source_arguments = [file for args in self.format_commands()[:-1] for file in args[4:]]
        self.assertCountEqual(source_arguments, ["Sources/first.swift", *names])
        self.assertTrue(all((self.root / name).read_text() == "keep owned contents\n"
                            for name in names + excluded))
        self.assert_cleaned()

    def test_successful_empty_discovery_and_no_matches_check_only_the_package(self):
        for fault in ["empty-success", "empty-no-match"]:
            with self.subTest(fault=fault):
                self.calls.unlink(missing_ok=True)
                result = self.run_script("check", fault=fault)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.format_commands(), [
                    ["lint", "--strict", "--configuration", ".swift-format", "Package.swift"]])
                self.assert_cleaned()

    def test_native_discovery_with_no_swift_matches_still_checks_the_package(self):
        self.first.unlink()
        result = self.run_script("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.format_commands(), [
            ["lint", "--strict", "--configuration", ".swift-format", "Package.swift"]])
        self.assert_cleaned()

    def test_native_discovery_with_a_missing_root_never_formats_its_partial_results(self):
        (self.root / "Tests").rmdir()
        result = self.run_script("format")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("Tests", result.stderr)
        self.assertEqual(self.format_commands(), [])
        self.assertEqual(self.first.read_text(), "owned source\n")
        self.assertEqual(self.package.read_text(), "owned package\n")
        self.assert_cleaned()

    def test_status_one_with_partial_results_is_rejected(self):
        result = self.run_script("format", fault="partial-status-one")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.format_commands(), [])
        self.assertEqual(self.first.read_text(), "owned source\n")
        self.assert_cleaned()

    def test_signal_during_discovery_cleans_staging_without_formatting(self):
        result = self.run_script("format", fault="signal-discovery")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.format_commands(), [])
        self.assertEqual(self.first.read_text(), "owned source\n")
        self.assertEqual(self.package.read_text(), "owned package\n")
        self.assert_cleaned()

    def test_source_formatter_failure_stops_before_the_package_check(self):
        result = self.run_script("check", fault="source-error")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.format_commands()), 1)
        self.assertNotIn("Package.swift", self.format_commands()[0])
        self.assert_cleaned()

    def test_package_formatter_failure_propagates(self):
        result = self.run_script("check", fault="package-error")
        self.assertEqual(result.returncode, 18, result.stderr)
        self.assertEqual(len(self.format_commands()), 2)
        self.assert_cleaned()

    def test_script_resolves_its_repository_when_called_from_elsewhere(self):
        result = self.run_script("check", cwd=self.root.parent)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.format_commands()[0][4:], ["Sources/first.swift"])
        self.assertEqual(self.format_commands()[1][4:], ["Package.swift"])
        self.assert_cleaned()

    def test_staging_creation_failure_prevents_discovery_and_formatting(self):
        (self.root / "temporary").rmdir()
        result = self.run_script("format")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [])
        self.assertEqual(self.first.read_text(), "owned source\n")
        self.assertEqual(self.package.read_text(), "owned package\n")


if __name__ == "__main__":
    unittest.main()
