"""Opt-in exact-bundle lookup using the real CLI and owned AppKit processes.

Set SWIFTTY_APP_BINARY to the built swiftty executable. No installed app or
agent is launched, registered, terminated, or replaced by these tests.
"""

import os
from pathlib import Path
import plistlib
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


APP = os.environ.get("SWIFTTY_APP_BINARY")
FIXTURE = """
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.finishLaunching()
print("ready")
fflush(stdout)
app.run()
"""


@unittest.skipUnless(sys.platform == "darwin" and APP,
                     "set SWIFTTY_APP_BINARY for native application lookup")
class AppInstanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app_binary = Path(APP).resolve(strict=True)
        temporary = tempfile.TemporaryDirectory(prefix="swiftty-instance-", dir="/tmp")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        source = cls.root / "fixture.swift"
        source.write_text(FIXTURE)
        cls.executable = cls.root / "fixture"
        subprocess.run(["xcrun", "swiftc", str(source), "-o", str(cls.executable)],
                       capture_output=True, text=True, check=True, timeout=60)

    def query(self, app, cwd=None):
        result = subprocess.run([str(self.app_binary), "--running-app", str(app)],
                                cwd=cwd, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(result.stdout, ["running\n", "stopped\n"])
        return result.stdout.strip()

    def test_exact_bundle_ignores_other_copy_and_accepts_aliases(self):
        identifier = "com.chr33s.swiftty.instance-fixture." + uuid.uuid4().hex
        bundles = []
        for name in ["running copy 'one'.app", "selected copy.app"]:
            bundle = self.root / name
            executable = bundle / "Contents/MacOS/swiftty"
            executable.parent.mkdir(parents=True)
            shutil.copyfile(self.executable, executable)
            executable.chmod(0o700)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "swiftty",
                "CFBundlePackageType": "APPL", "LSUIElement": True,
            }))
            bundles.append(bundle)
        running, selected = bundles
        self.assertEqual(self.query(running), "stopped")
        process = subprocess.Popen([str(running / "Contents/MacOS/swiftty")],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 8)[0], "fixture did not start")
            self.assertEqual(process.stdout.readline(), b"ready\n")
            # Native evidence for the old name-only predicate, scoped to our
            # own child so no unrelated running application can satisfy it.
            named = subprocess.run(["pgrep", "-P", str(os.getpid()), "-x", "swiftty"],
                                   capture_output=True, text=True, timeout=5)
            self.assertEqual(named.returncode, 0, named.stderr)
            self.assertIn(str(process.pid), named.stdout.splitlines())
            self.assertEqual(self.query(selected), "stopped")
            self.assertEqual(self.query(running), "running")
            alias = self.root / "alias.app"
            alias.symlink_to(running, target_is_directory=True)
            self.assertEqual(self.query(alias), "running")
            self.assertEqual(self.query(running.name, cwd=self.root), "running")
            different_case = running.with_name(running.name.upper())
            if different_case.exists():
                self.assertEqual(self.query(different_case), "running")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()
        deadline = time.monotonic() + 5
        while self.query(running) != "stopped":
            self.assertLess(time.monotonic(), deadline, "exited app still reported as running")
            time.sleep(0.02)

    def test_bad_query_arguments_exit_without_starting_the_app(self):
        for arguments in [["--running-app"], ["--running-app", "/tmp/a.app", "extra"]]:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(self.app_binary), *arguments],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
