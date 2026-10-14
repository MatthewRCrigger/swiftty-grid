"""Paired generator publication in private repositories, without UCD downloads."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROPERTY = Path("Sources/SwifttyEngine/Terminal/GraphemeBreakTables.swift")
TEST_DATA = Path("Tests/SwifttyCoreTests/GraphemeBreakTestData.swift")
TOOL = r'''#!/PYTHON
import json, os, signal, subprocess, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['GRAPHEME_CALLS'], 'a') as stream:
    stream.write(json.dumps([name, args]) + '\n')
fault = os.environ.get('GRAPHEME_FAULT', '')
if name == 'swift':
    data = '--test-data' in args
    if fault == ('generate-data' if data else 'generate-properties'):
        print('partial generation')
        sys.exit(41)
    print('new test data' if data else 'new properties')
    sys.exit(0)
source = Path(args[-2]).name
destination = Path(args[-1])
if name == 'cp':
    if fault == 'backup-data' and destination.name == 'test-data.previous':
        sys.exit(42)
    sys.exit(subprocess.call(['/bin/cp', *args]))
rollback = source.endswith('.previous')
if rollback:
    if fault == 'restore-fails' and source == 'properties.previous':
        sys.exit(49)
    if fault == 'signal-cleanup':
        for _ in range(8):
            os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(subprocess.call(['/bin/mv', *args]))
data = source == 'test-data.swift'
if fault == ('before-data' if data else 'before-properties'):
    sys.exit(43)
status = subprocess.call(['/bin/mv', *args])
if status:
    sys.exit(status)
if fault == ('after-data' if data else 'after-properties'):
    sys.exit(44)
if not data and fault in ['restore-fails', 'signal-cleanup']:
    os.kill(os.getppid(), signal.SIGTERM)
elif fault.startswith('signal-') and fault.endswith('-data' if data else '-properties'):
    os.kill(os.getppid(), getattr(signal, fault.split('-')[1]))
'''


class GraphemeUpdateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftty-grapheme-update-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "private repository '$' 漢"
        self.root.mkdir()
        scripts = self.root / "Scripts"
        scripts.mkdir()
        self.script = scripts / "update-grapheme-tables.sh"
        shutil.copyfile(ROOT / "Scripts/update-grapheme-tables.sh", self.script)
        self.property = self.root / PROPERTY
        self.data = self.root / TEST_DATA
        for path, content, mode in [(self.property, "old properties\n", 0o640),
                                    (self.data, "old test data\n", 0o600)]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            path.chmod(mode)
        self.tools = self.root / "bin"
        self.tools.mkdir()
        for name in ["swift", "mv", "cp"]:
            tool = self.tools / name
            tool.write_text(TOOL.replace("/PYTHON", sys.executable))
            tool.chmod(0o700)
        self.calls = self.root / "calls.jsonl"
        self.ucd = self.root / "ucd input '$' 漢"
        self.ucd.mkdir()

    def run_script(self, fault="", arguments=None, cwd=None):
        return subprocess.run(
            ["/bin/sh", str(self.script),
             *([str(self.ucd)] if arguments is None else arguments)],
            cwd=cwd or self.root,
            env={**os.environ, "PATH": str(self.tools) + os.pathsep + os.environ["PATH"],
                 "GRAPHEME_CALLS": str(self.calls), "GRAPHEME_FAULT": fault},
            capture_output=True, text=True, timeout=10,
        )

    def assert_original_pair(self):
        self.assertEqual(self.property.read_text(), "old properties\n")
        self.assertEqual(self.data.read_text(), "old test data\n")
        self.assertEqual(self.property.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.data.stat().st_mode & 0o777, 0o600)

    def assert_cleaned(self):
        self.assertEqual(list(self.root.glob(".grapheme-tables.*")), [])

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_second_replacement_failure_restores_the_original_pair(self):
        result = self.run_script("before-data")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original_pair()
        self.assert_cleaned()

    def test_termination_between_replacements_restores_the_original_pair(self):
        result = self.run_script("signal-SIGTERM-properties")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original_pair()
        self.assert_cleaned()

    def test_success_publishes_both_complete_generations_with_regular_modes(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.property.read_text(), "new properties\n")
        self.assertEqual(self.data.read_text(), "new test data\n")
        for path in [self.property, self.data]:
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        commands = self.commands()
        self.assertEqual([name for name, _ in commands], ["swift", "swift", "cp", "cp", "mv", "mv"])
        self.assertEqual(commands[0][1], ["Scripts/gen-grapheme-tables.swift", str(self.ucd)])
        self.assertEqual(commands[1][1], ["Scripts/gen-grapheme-tables.swift", str(self.ucd), "--test-data"])
        self.assert_cleaned()

    def test_relative_ucd_input_is_resolved_from_the_callers_directory(self):
        relative = os.path.relpath(self.ucd, self.root.parent)
        result = self.run_script(arguments=[relative], cwd=self.root.parent)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(self.commands()[0][1][1]).resolve(), self.ucd.resolve())
        self.assert_cleaned()

    def test_generation_failure_never_starts_publication(self):
        for fault in ["generate-properties", "generate-data"]:
            with self.subTest(fault=fault):
                self.calls.unlink(missing_ok=True)
                result = self.run_script(fault)
                self.assertEqual(result.returncode, 41, result.stderr)
                self.assert_original_pair()
                self.assertTrue(all(name == "swift" for name, _ in self.commands()))
                self.assert_cleaned()

    def test_backup_failure_never_mutates_either_destination(self):
        result = self.run_script("backup-data")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_original_pair()
        self.assertFalse(any(name == "mv" for name, _ in self.commands()))
        self.assert_cleaned()

    def test_first_replacement_failure_before_or_after_rename_restores_both_files(self):
        for fault, expected in [("before-properties", 43), ("after-properties", 44)]:
            with self.subTest(fault=fault):
                result = self.run_script(fault)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assert_original_pair()
                self.assert_cleaned()

    def test_second_replacement_failure_after_rename_restores_both_files(self):
        result = self.run_script("after-data")
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assert_original_pair()
        self.assert_cleaned()

    def test_each_handled_signal_restores_both_files_after_either_rename(self):
        for name in ["SIGHUP", "SIGINT", "SIGTERM"]:
            for stage in ["properties", "data"]:
                with self.subTest(signal=name, stage=stage):
                    result = self.run_script(f"signal-{name}-{stage}")
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assert_original_pair()
                    self.assert_cleaned()

    def test_repeated_signals_during_restoration_do_not_interrupt_cleanup(self):
        result = self.run_script("signal-cleanup")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_original_pair()
        self.assert_cleaned()

    def test_recovery_failure_reports_and_retains_the_unrestored_backup(self):
        result = self.run_script("restore-fails")
        self.assertEqual(result.returncode, 1, result.stderr)
        directories = list(self.root.glob(".grapheme-tables.*"))
        self.assertEqual(len(directories), 1)
        saved = directories[0] / "properties.previous"
        self.assertEqual(saved.read_text(), "old properties\n")
        self.assertEqual(saved.stat().st_mode & 0o777, 0o640)
        self.assertIn("recovery failed", result.stderr)
        self.assertIn(str(directories[0]), result.stderr)
        self.assertEqual(self.data.read_text(), "old test data\n")
        # The retained native backup remains usable for manual recovery.
        os.replace(saved, self.property)
        self.assert_original_pair()

    def test_failed_publication_restores_former_absence_as_well_as_existing_files(self):
        for absent in [(self.property,), (self.data,), (self.property, self.data)]:
            with self.subTest(absent=absent):
                for path in absent:
                    path.unlink()
                result = self.run_script("after-data")
                self.assertEqual(result.returncode, 44, result.stderr)
                for path, content, mode in [(self.property, "old properties\n", 0o640),
                                            (self.data, "old test data\n", 0o600)]:
                    if path in absent:
                        self.assertFalse(path.exists())
                        path.write_text(content)
                        path.chmod(mode)
                    else:
                        self.assertEqual(path.read_text(), content)
                        self.assertEqual(path.stat().st_mode & 0o777, mode)
                self.assert_cleaned()

    def test_symlinks_are_restored_without_modifying_their_targets(self):
        target = self.root / "old property target"
        target.write_text("old target contents\n")
        target.chmod(0o400)
        self.property.unlink()
        self.property.symlink_to(target)
        self.data.unlink()
        self.data.symlink_to("missing data target")
        result = self.run_script("after-data")
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assertEqual(os.readlink(self.property), str(target))
        self.assertEqual(os.readlink(self.data), "missing data target")
        self.assertEqual(target.read_text(), "old target contents\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o400)
        self.assert_cleaned()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.property.is_symlink())
        self.assertFalse(self.data.is_symlink())
        self.assertEqual(target.read_text(), "old target contents\n")
        self.assert_cleaned()

    def test_directory_destination_is_rejected_before_publication(self):
        self.data.unlink()
        self.data.mkdir()
        marker = self.data / "owned marker"
        marker.write_text("preserve\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("non-file destination", result.stderr)
        self.assertEqual(marker.read_text(), "preserve\n")
        self.assertEqual(self.property.read_text(), "old properties\n")
        self.assertFalse(any(name == "mv" for name, _ in self.commands()))
        self.assert_cleaned()

    def test_directory_symlink_destination_is_rejected_without_writing_into_its_target(self):
        target = self.root / "owned directory target"
        target.mkdir()
        self.data.unlink()
        self.data.symlink_to(target, target_is_directory=True)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(self.data), str(target))
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(self.property.read_text(), "old properties\n")
        self.assertFalse(any(name == "mv" for name, _ in self.commands()))
        self.assert_cleaned()

    def test_fifo_destination_is_rejected_without_waiting_for_a_writer(self):
        self.data.unlink()
        os.mkfifo(self.data)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("non-file destination", result.stderr)
        self.assertEqual(self.property.read_text(), "old properties\n")
        self.assertFalse(any(name == "mv" for name, _ in self.commands()))
        self.assert_cleaned()

    def test_usage_errors_do_not_generate_or_modify_files(self):
        for arguments in [[], [str(self.ucd), "extra"]]:
            with self.subTest(arguments=arguments):
                result = self.run_script(arguments=arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertFalse(self.calls.exists())
                self.assert_original_pair()
                self.assert_cleaned()


if __name__ == "__main__":
    unittest.main()
