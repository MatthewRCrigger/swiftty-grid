"""Rebased installer and native publication against owned apps and fake tools."""

import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = r'''#!/PYTHON
import json, os, plistlib, shutil, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['INSTALL_FIXTURE_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as stream:
    stream.write(json.dumps([name, args])+'\n')
if name == 'package-swiftmux.sh': pass
elif name == 'swift': print(root/'repo/products')
elif name == 'launchctl':
    if args[0] == 'print' and os.environ.get('INSTALL_FIXTURE_REGISTERED_TEAM'):
        print('state = running\n"team-identifier" => "'+os.environ['INSTALL_FIXTURE_REGISTERED_TEAM']+'"')
    else: sys.exit(113)
elif name == 'pgrep': sys.exit(0)
elif name == 'codesign':
    if '-dv' in args:
        team = os.environ.get('INSTALL_FIXTURE_TEAM','not set')
        if '.Swiftty-install-' in args[-1]:
            if os.environ.get('INSTALL_FIXTURE_FAILURE') == 'metadata': sys.exit(44)
            team = os.environ.get('INSTALL_FIXTURE_STAGED_TEAM',team)
        print('TeamIdentifier='+team, file=sys.stderr)
    elif '--verify' in args:
        failure = os.environ.get('INSTALL_FIXTURE_FAILURE')
        if failure == 'verify': sys.exit(43)
        if failure == 'publish': (root/'applications with spaces').chmod(0o500)
        if failure == 'race':
            competitor = root/'applications with spaces/Swiftty GRID.app'
            competitor.mkdir()
            (competitor/'competing').write_text('competing installation')
elif name == 'ditto':
    source, destination = map(Path, args)
    if os.environ.get('INSTALL_FIXTURE_FAILURE') == 'copy':
        destination.mkdir(parents=True, exist_ok=True)
        (destination/'partial').write_text('incomplete replacement')
        sys.exit(42)
    if os.environ.get('INSTALL_FIXTURE_FAILURE') == 'interrupt':
        destination.mkdir(parents=True, exist_ok=True)
        (destination/'partial').write_text('incomplete replacement')
        marker = root/'copy-worker.json.tmp'
        marker.write_text(json.dumps({'helper':os.getppid(),'worker':os.getpid()}))
        marker.replace(root/'copy-worker.json')
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(0.1)
    shutil.copytree(source, destination, dirs_exist_ok=True)
elif name == 'sudo': sys.exit(subprocess.run(args).returncode)
elif name == 'open': pass
else: raise RuntimeError(name)
'''
APP = r'''#!/PYTHON
import json, os, sys
from pathlib import Path
root = Path(os.environ['INSTALL_FIXTURE_ROOT'])
with (root/'calls.jsonl').open('a') as stream:
    stream.write(json.dumps(['swiftty', sys.argv[1:]])+'\n')
print('enabled')
'''


@unittest.skipUnless(sys.platform == "darwin", "native macOS app publication")
class InstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftty-install-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        scripts = self.repo / "Scripts"
        scripts.mkdir(parents=True)
        source = (ROOT / "Scripts/install.sh").read_text()
        source = source.replace('dev_plist="$HOME/Library/LaunchAgents/$label.plist"',
                                'dev_plist=' + shlex.quote(str(self.root / "absent-dev-agent.plist")))
        (scripts / "install.sh").write_text(source)
        helper = ROOT / "Scripts/install-app.py"
        if helper.exists():
            shutil.copyfile(helper, scripts / helper.name)
        self.tools = self.root / "bin"
        self.tools.mkdir()
        for path in [scripts / "package-swiftmux.sh", *(self.tools / name for name in
                     ["swift", "codesign", "launchctl", "pgrep", "ditto", "open", "sudo"])]:
            path.write_text(TOOL.replace("/PYTHON", sys.executable))
            path.chmod(0o700)
        self.built = self.repo / ".build/package/Swiftty GRID.app"
        self.create_app(self.built, "new")
        self.destination = self.root / "applications with spaces"
        self.destination.mkdir()
        self.app = self.destination / "Swiftty GRID.app"
        self.create_app(self.app, "old")
        self.environment = dict(os.environ)
        self.environment.update(INSTALL_FIXTURE_ROOT=str(self.root),
                                PATH=str(self.tools) + os.pathsep + self.environment["PATH"])
        self.environment.pop("NOTARY_PROFILE", None)

    def create_app(self, path, marker):
        executables = path / "Contents/MacOS"
        executables.mkdir(parents=True)
        for name in ["swiftty", "swiftmux-agent", "swmux-launcher", "swmux"]:
            file = executables / name
            file.write_text(APP.replace("/PYTHON", sys.executable))
            file.chmod(0o700)
        with (path / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.chr33s.swiftty",
                          "CFBundleExecutable": "swiftty"}, stream)
        (path / marker).write_text(marker)

    def install(self, *arguments, **environment):
        return subprocess.run(
            ["/bin/sh", str(self.repo / "Scripts/install.sh"), "--identity", "-",
             "--dest", str(self.destination), *arguments],
            env={**self.environment, **environment}, capture_output=True, text=True, timeout=15,
        )

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_prior_app(self):
        self.assertEqual((self.app / "old").read_text(), "old")
        self.assertFalse((self.app / "new").exists())
        self.assertFalse((self.app / "partial").exists())
        self.assertFalse(any(name in {"swiftty", "open"} for name, _ in self.calls()))

    def test_copy_failure_preserves_previous_app_and_skips_registration(self):
        result = self.install(INSTALL_FIXTURE_FAILURE="copy")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_staged_signature_failure_preserves_previous_app(self):
        for failure in ["verify", "metadata"]:
            with self.subTest(failure=failure):
                result = self.install(INSTALL_FIXTURE_FAILURE=failure)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_prior_app()
                self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_successful_native_swap_preserves_open_old_file_and_registers_after_validation(self):
        with (self.app / "old").open("rb") as old:
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(old.read(), b"old")
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertFalse((self.app / "old").exists())
        self.assertEqual(list(self.destination.iterdir()), [self.app])
        calls = self.calls()
        verify = next(i for i, (name, args) in enumerate(calls) if name == "codesign" and "--verify" in args)
        register = next(i for i, (name, _) in enumerate(calls) if name == "swiftty")
        self.assertLess(verify, register)
        self.assertTrue(any(name == "swiftty" and args == ["--swiftmux-agent", "register"]
                            for name, args in calls))
        self.assertFalse(any(name == "launchctl" and args[0] == "bootout" for name, args in calls))

    def test_first_install_and_concurrent_target_creation(self):
        shutil.rmtree(self.app)
        result = self.install(INSTALL_FIXTURE_FAILURE="race")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("File exists", result.stderr)
        self.assertEqual((self.app / "competing").read_text(), "competing installation")
        self.assertFalse((self.app / "new").exists())
        self.assertFalse(any(name == "swiftty" for name, _ in self.calls()))
        shutil.rmtree(self.app)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_native_publication_permission_failure_preserves_previous_app(self):
        try:
            result = self.install(INSTALL_FIXTURE_FAILURE="publish")
        finally:
            self.destination.chmod(0o700)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("Permission denied", result.stderr)
        self.assert_prior_app()
        self.assertIn("cannot clean staging directory", result.stderr)
        for leftover in self.destination.iterdir():
            if leftover != self.app:
                self.assertEqual(list(leftover.iterdir()), [])

    def test_invalid_bundle_metadata_or_executables_preserve_previous_app(self):
        metadata = self.built / "Contents/Info.plist"
        original = metadata.read_bytes()
        for data in [b"not a plist", b'<?xml version="1.0"?><plist><dict>',
                     plistlib.dumps({"CFBundleIdentifier": "other.app", "CFBundleExecutable": "swiftty"})]:
            with self.subTest(data=data[:50]):
                metadata.write_bytes(data)
                result = self.install()
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assert_prior_app()
        metadata.write_bytes(original)
        executable = self.built / "Contents/MacOS/swiftmux-agent"
        executable.chmod(0o600)
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        executable.unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()

    def test_running_team_mismatch_requires_explicit_restart_and_then_reregisters(self):
        setting = {"INSTALL_FIXTURE_REGISTERED_TEAM": "OLDTEAM123", "INSTALL_FIXTURE_TEAM": "NEWTEAM123"}
        result = self.install(**setting)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        self.assertFalse(any(name == "ditto" for name, _ in self.calls()))
        result = self.install("--restart-agent", **setting)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertTrue(any(name == "swiftty" and args == ["--swiftmux-agent", "unregister"]
                            for name, args in calls))
        self.assertTrue(any(name == "launchctl" and args[0] == "bootout" for name, args in calls))

    def test_running_matching_team_is_not_unregistered_or_stopped(self):
        result = self.install(INSTALL_FIXTURE_REGISTERED_TEAM="SAME123456",
                              INSTALL_FIXTURE_TEAM="SAME123456")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertFalse(any(name == "swiftty" and "unregister" in args
                             or name == "launchctl" and args[0] == "bootout"
                             for name, args in self.calls()))

    def test_staged_team_change_cannot_invalidate_the_restart_decision(self):
        result = self.install(INSTALL_FIXTURE_REGISTERED_TEAM="SAME123456",
                              INSTALL_FIXTURE_TEAM="SAME123456",
                              INSTALL_FIXTURE_STAGED_TEAM="DIFF123456")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_relative_destination_directory_alias_keeps_the_selected_location(self):
        alias = self.repo / "alias directory"
        alias.symlink_to(self.destination, target_is_directory=True)
        result = self.install("--dest", alias.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_replacing_a_destination_symlink_keeps_its_external_target(self):
        previous = self.root / "previous.app"
        self.app.rename(previous)
        self.app.symlink_to(previous, target_is_directory=True)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.app.is_symlink())
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertEqual((previous / "old").read_text(), "old")
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_empty_or_option_like_destinations_fail_before_commands(self):
        for value in ["", "-", "-directory"]:
            with self.subTest(value=value):
                result = self.install("--dest", value)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(self.calls(), [])
                self.assert_prior_app()

    def test_repeated_interruption_joins_the_owned_copy_worker_and_preserves_previous_app(self):
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(
                ["/usr/bin/python3", "-I", str(self.repo / "Scripts/install-app.py"),
                 str(self.built), str(self.app), ""],
                env={**self.environment, "INSTALL_FIXTURE_FAILURE": "interrupt"},
                stdout=output, stderr=output,
            )
            self.addCleanup(self.finish_helper, process)
            marker = self.root / "copy-worker.json"
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            owned = json.loads(marker.read_text())
            self.assertEqual(owned["helper"], process.pid)
            process.send_signal(signal.SIGTERM)
            for _ in range(20):
                if process.poll() is not None:
                    break
                try:
                    process.send_signal(signal.SIGTERM)
                except ProcessLookupError:
                    break
                time.sleep(0.005)
            self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
            with self.assertRaises(ProcessLookupError):
                os.kill(owned["worker"], 0)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def finish_helper(self, process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def sign_owned_app(self):
        resources = self.built / "Contents/Resources"
        resources.mkdir()
        (self.built / "new").rename(resources / "new")
        executable = self.root / "native-main"
        compiled = subprocess.run(["/usr/bin/clang", "-x", "c", "-o", str(executable), "-"],
                                  input="int main(void) { return 0; }\n", text=True,
                                  capture_output=True, timeout=20)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        for name in ["swiftty", "swiftmux-agent", "swmux-launcher", "swmux"]:
            target = self.built / "Contents/MacOS" / name
            shutil.copyfile(executable, target)
            target.chmod(0o700)
        for name in ["swiftmux-agent", "swmux-launcher", "swmux"]:
            target = self.built / "Contents/MacOS" / name
            signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-",
                                     "--timestamp=none", str(target)], capture_output=True,
                                    text=True, timeout=10)
            self.assertEqual(signed.returncode, 0, signed.stderr)
        signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-",
                                 "--timestamp=none", str(self.built)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(signed.returncode, 0, signed.stderr)

    def run_native_helper(self):
        return subprocess.run(
            ["/usr/bin/python3", "-I", str(ROOT / "Scripts/install-app.py"),
             str(self.built), str(self.app), ""],
            env={**self.environment, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            capture_output=True, text=True, timeout=15,
        )

    def test_real_ditto_codesign_and_native_swap_publish_an_owned_ad_hoc_app(self):
        self.sign_owned_app()
        result = self.run_native_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Contents/Resources/new").read_text(), "new")
        self.assertFalse((self.app / "old").exists())
        verified = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(self.app)],
                                  capture_output=True, text=True, timeout=10)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_real_signature_verification_rejects_a_tampered_owned_app_without_replacement(self):
        self.sign_owned_app()
        (self.built / "Contents/Resources/new").write_text("changed after signing")
        result = self.run_native_helper()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("cannot replace app", result.stderr)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])


if __name__ == "__main__":
    unittest.main()
