"""Uninstall control flow with rebased owned paths and fake system commands."""

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


ROOT = Path(__file__).resolve().parents[2]
TOOL = r'''#!/PYTHON
import json, os, shutil, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['FIXTURE_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as stream:
    stream.write(json.dumps([name, args])+'\n')
stage = name + (':' + args[-1] if name == 'swiftty' else
                ':' + args[0] if name == 'launchctl' else '')
if os.environ.get('FIXTURE_FLOOD') == stage:
    (root/'child.pid').write_text(str(os.getpid()))
    sys.stdout.buffer.write(b'x' * 65537)
    sys.stdout.buffer.flush()
    while True: time.sleep(30)
if os.environ.get('FIXTURE_STALL') == stage:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (root/'child.pid').write_text(str(os.getpid()))
    if os.environ.get('FIXTURE_CLOSE_STDOUT'): os.close(1)
    while True: time.sleep(30)
if name == 'pgrep':
    time.sleep(float(os.environ.get('FIXTURE_PROCESS_DELAY', '0')))
    if (root/'quit').exists():
        after_quit = os.environ.get('FIXTURE_AFTER_QUIT')
        if after_quit == 'error': sys.exit(2)
        if after_quit in {'stall', 'late-absence'}:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            (root/'child.pid').write_text(str(os.getpid()))
            time.sleep(30 if after_quit == 'stall' else 2)
            sys.exit(1)
    mode = os.environ.get('FIXTURE_PROCESS','absent')
    if mode == 'error': sys.exit(2)
    sys.exit(0 if mode == 'stuck' or (mode == 'running' and not (root/'quit').exists()) else 1)
elif name == 'osascript':
    if os.environ.get('FIXTURE_QUIT_ERROR'): sys.exit(42)
    (root/'quit').touch()
elif name == 'swiftty':
    if args[-1] == 'status':
        if os.environ.get('FIXTURE_STATUS_ERROR'): sys.exit(43)
        print(os.environ.get('FIXTURE_AGENT','enabled'))
    else:
        if os.environ.get('FIXTURE_UNREGISTER_ERROR'): sys.exit(44)
        print(os.environ.get('FIXTURE_UNREGISTER_RESULT','notRegistered'))
elif name == 'launchctl':
    sys.exit(int(os.environ.get('FIXTURE_BOOTOUT' if args[0]=='bootout' else 'FIXTURE_PROBE',
                               '0' if args[0]=='bootout' else '113')))
elif name == 'id': print('501')
elif name == 'sudo':
    assert args[0]=='rm', args
    sys.exit(subprocess.run([str(root/'bin/rm'), *args[1:]]).returncode)
elif name == 'rm':
    if os.environ.get('FIXTURE_REMOVE_ERROR'): sys.exit(45)
    for argument in args:
        if argument.startswith('-'): continue
        path = Path(argument)
        parent = path.parent.resolve()
        assert path.is_absolute() and (parent == root or root in parent.parents), path
        if path.is_symlink() or path.is_file(): path.unlink(missing_ok=True)
        elif path.is_dir(): shutil.rmtree(path)
'''


class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uninstall-fixture-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.script = self.root / "uninstall.sh"
        self.install_script((ROOT / "Scripts/uninstall.sh").read_text())
        runner = (ROOT / "Scripts/uninstall-command.py").read_text()
        (self.root / "uninstall-command.py").write_text(runner)
        self.destination = self.root / "install with 'quotes'"
        self.app = self.destination / "Swiftty.app"
        self.app_binary = self.app / "Contents/MacOS/swiftty"
        self.app_binary.parent.mkdir(parents=True)
        self.user_home = self.root / "user"
        self.plist = self.user_home / "Library/LaunchAgents/com.chr33s.swiftty.swiftmux.plist"
        self.plist.parent.mkdir(parents=True)
        self.plist.write_text("fixture")
        self.helper = self.root / "libexec/swifttyd"
        self.helper.parent.mkdir()
        self.helper.write_text("fixture")
        self.state = self.user_home / "Library/Application Support/SwiftMux"
        self.settings = self.user_home / ".config/swmux"
        self.state.mkdir(parents=True)
        self.settings.mkdir(parents=True)
        for path in [self.app_binary, *(self.bin / name for name in
                                      ["pgrep", "osascript", "launchctl", "id", "rm", "sudo"])]:
            path.write_text(TOOL.replace("#!/PYTHON", "#!" + sys.executable, 1))
            path.chmod(0o755)
        self.environment = {**os.environ, "FIXTURE_ROOT": str(self.root),
                            "FIXTURE_USER_HOME": str(self.user_home),
                            "FIXTURE_HELPER": str(self.helper),
                            "FIXTURE_DEST": str(self.destination),
                            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                            "TERM": "dumb", "TERM_PROGRAM": "fixture"}

    def install_script(self, source):
        # Rebase only filesystem roots in the copy. Do not change HOME or run
        # actual Apple Events, launchctl mutations, sudo, or system deletion.
        source = source.replace("$HOME", "$FIXTURE_USER_HOME")
        source = source.replace("dest=/Applications", "dest=$FIXTURE_DEST")
        source = source.replace("helper=/usr/local/libexec/swifttyd", "helper=$FIXTURE_HELPER")
        self.script.write_text(source)

    def invoke(self, arguments=("--yes", "--purge"), timeout=8, **settings):
        return subprocess.run(["/bin/sh", str(self.script), *arguments],
                              env={**self.environment, **settings}, capture_output=True,
                              text=True, timeout=timeout)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_preserved(self):
        for path in [self.app, self.plist, self.helper, self.state, self.settings]:
            self.assertTrue(path.exists(), str(path))
        self.assertFalse(any(name in {"rm", "sudo"} for name, args in self.calls()))

    def test_service_loaded_or_probe_failed_prevents_all_deletion(self):
        for bootout, probe in [("5", "0"), ("0", "0"), ("0", "5"), ("3", "125")]:
            with self.subTest(bootout=bootout, probe=probe):
                result = self.invoke(FIXTURE_BOOTOUT=bootout, FIXTURE_PROBE=probe)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("files preserved", result.stderr)
                self.assert_preserved()

    def test_slow_successful_process_probes_share_one_quit_deadline(self):
        runner = (ROOT / "Scripts/uninstall-command.py").read_text()
        (self.root / "uninstall-command.py").write_text(runner.replace("QUIT_TIMEOUT = 5", "QUIT_TIMEOUT = 1"))
        started = time.monotonic()
        result = self.invoke(timeout=20, FIXTURE_PROCESS="stuck", FIXTURE_PROCESS_DELAY="0.08")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 3)
        self.assert_preserved()
        self.assertFalse(any(name in {"swiftty", "launchctl"} for name, args in self.calls()))

    def test_quit_wait_rejects_failed_hung_or_late_absence_probes(self):
        runner = (ROOT / "Scripts/uninstall-command.py").read_text()
        (self.root / "uninstall-command.py").write_text(runner.replace("QUIT_TIMEOUT = 5", "QUIT_TIMEOUT = 1"))
        for mode in ["error", "stall", "late-absence"]:
            with self.subTest(mode=mode):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                (self.root / "quit").unlink(missing_ok=True)
                started = time.monotonic()
                result = self.invoke(FIXTURE_PROCESS="running", FIXTURE_AFTER_QUIT=mode)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertLess(time.monotonic() - started, 3)
                self.assert_preserved()
                self.assertFalse(any(name in {"swiftty", "launchctl"} for name, args in self.calls()))
                if mode == "error":
                    self.assertIn("status 2", result.stderr)
                else:
                    self.assertIn("timed out", result.stderr)
                    pid = int((self.root / "child.pid").read_text())
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)

    def test_stalled_prerequisites_are_killed_and_preserve_every_path(self):
        # Shorten only this test's copied runner; leave normal commands ample
        # startup time, including cold Python imports on a busy test host.
        runner = (ROOT / "Scripts/uninstall-command.py").read_text()
        (self.root / "uninstall-command.py").write_text(runner.replace("TIMEOUT = 10", "TIMEOUT = 1"))
        for stage in ["pgrep", "osascript", "swiftty:status", "swiftty:unregister",
                      "launchctl:bootout", "launchctl:print", "id"]:
            with self.subTest(stage=stage):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                (self.root / "quit").unlink(missing_ok=True)
                result = self.invoke(FIXTURE_STALL=stage,
                                     FIXTURE_PROCESS="running" if stage == "osascript" else "absent")
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("timed out", result.stderr)
                self.assert_preserved()
                pid = int((self.root / "child.pid").read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
                if stage == "launchctl:bootout":
                    self.assertFalse(any(name == "launchctl" and args[0] == "print"
                                         for name, args in self.calls()))

    def test_unbounded_registration_output_is_rejected_and_child_reaped(self):
        result = self.invoke(FIXTURE_FLOOD="swiftty:status")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("output exceeds limit", result.stderr)
        self.assert_preserved()
        pid = int((self.root / "child.pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_stdout_eof_does_not_remove_child_exit_deadline(self):
        runner = (ROOT / "Scripts/uninstall-command.py").read_text()
        (self.root / "uninstall-command.py").write_text(runner.replace("TIMEOUT = 10", "TIMEOUT = 1"))
        result = self.invoke(FIXTURE_STALL="swiftty:status", FIXTURE_CLOSE_STDOUT="1")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("timed out", result.stderr)
        self.assert_preserved()
        pid = int((self.root / "child.pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_interrupted_or_uncertain_bootout_stops_before_absence_probe(self):
        for status in [124, 125, 128 + signal.SIGTERM]:
            with self.subTest(status=status):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result = self.invoke(FIXTURE_BOOTOUT=str(status))
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("bootout did not complete", result.stderr)
                self.assert_preserved()
                self.assertFalse(any(name == "launchctl" and args[0] == "print"
                                     for name, args in self.calls()))

    def test_interrupted_runner_kills_and_reaps_owned_noncooperative_child(self):
        process = subprocess.Popen(
            [sys.executable, str(self.root / "uninstall-command.py"),
             str(self.app_binary), "--swiftmux-agent", "status"],
            env={**self.environment, "FIXTURE_STALL": "swiftty:status"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not (self.root / "child.pid").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / "child.pid").exists())
            pid = int((self.root / "child.pid").read_text())
            process.terminate()
            output, error = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, error)
            self.assertEqual(output, b"")
            self.assertIn(b"interrupted", error)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            self.assert_preserved()
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)

    def test_unregister_failure_or_nonfinal_status_preserves_files(self):
        for settings in [{"FIXTURE_UNREGISTER_ERROR": "1"},
                         {"FIXTURE_UNREGISTER_RESULT": "enabled"},
                         {"FIXTURE_UNREGISTER_RESULT": "requiresApproval"},
                         {"FIXTURE_STATUS_ERROR": "1"}, {"FIXTURE_AGENT": "unknown"}]:
            with self.subTest(settings=settings):
                result = self.invoke(**settings)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assert_preserved()

    def test_quit_failures_or_process_probe_errors_prevent_unregistration(self):
        for settings in [{"FIXTURE_PROCESS": "running", "FIXTURE_QUIT_ERROR": "1"},
                         {"FIXTURE_PROCESS": "stuck"}, {"FIXTURE_PROCESS": "error"}]:
            with self.subTest(settings=settings):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result = self.invoke(**settings)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse(any(name in {"swiftty", "launchctl"} for name, args in self.calls()))
                self.assert_preserved()

    def test_successful_quit_unregister_and_absence_delete_owned_paths_in_order(self):
        result = self.invoke(FIXTURE_PROCESS="running")
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in [self.app, self.plist, self.helper, self.state, self.settings]:
            self.assertFalse(path.exists())
        calls = self.calls()
        probe = next(index for index, (name, args) in enumerate(calls)
                     if name == "launchctl" and args[0] == "print")
        self.assertTrue(all(index > probe for index, (name, args) in enumerate(calls)
                            if name in {"rm", "sudo"}))

    def test_already_unregistered_and_absent_agent_is_idempotent(self):
        for state in ["notRegistered", "notFound"]:
            self.app_binary.parent.mkdir(parents=True, exist_ok=True)
            self.app_binary.write_text(TOOL.replace("#!/PYTHON", "#!" + sys.executable, 1))
            self.app_binary.chmod(0o755)
            result = self.invoke(FIXTURE_AGENT=state, FIXTURE_BOOTOUT="3")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invoke(FIXTURE_BOOTOUT="3").returncode, 0)
        self.assertEqual(sum(name == "swiftty" and args[-1] == "status" for name, args in self.calls()), 2)
        self.assertFalse(any(name == "swiftty" and args[-1] == "unregister"
                             for name, args in self.calls()))

    def test_missing_empty_or_option_destination_fails_before_commands(self):
        for arguments in [("--dest",), ("--dest", ""), ("--dest", "--yes"), ("--dest", "-y")]:
            with self.subTest(arguments=arguments):
                result = self.invoke(arguments)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(self.calls(), [])
                self.assert_preserved()

    def test_inside_swiftty_or_swiftmux_is_refused_before_shutdown(self):
        for settings in [{"TERM_PROGRAM": "swiftty"}, {"TERM": "swmux-256color"}]:
            with self.subTest(settings=settings):
                result = self.invoke(**settings)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.calls(), [])
                self.assert_preserved()

    def test_broken_record_and_helper_links_are_removed_without_following_them(self):
        self.plist.unlink()
        self.plist.symlink_to(self.root / "absent-plist-target")
        self.helper.unlink()
        self.helper.symlink_to(self.root / "absent-helper-target")
        result = self.invoke(FIXTURE_BOOTOUT="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.plist.is_symlink())
        self.assertFalse(self.helper.is_symlink())

    def test_nonfile_plist_and_failed_removal_do_not_report_success(self):
        self.plist.unlink()
        self.plist.mkdir()
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a file", result.stderr)
        self.assert_preserved()
        self.plist.rmdir()
        self.plist.write_text("fixture")
        result = self.invoke(FIXTURE_REMOVE_ERROR="1")
        self.assertEqual(result.returncode, 45)
        self.assertNotIn("removed", result.stdout)
        self.assertTrue(self.app.exists())
        self.assertTrue(self.helper.exists())
        self.assertTrue(self.state.exists())


if __name__ == "__main__":
    unittest.main()
