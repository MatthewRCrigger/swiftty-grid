"""Native agent startup under real, isolated Security API failure injection.

Set SWIFTTY_AGENT_BINARY to the newly built ad-hoc agent. No installed agent or
launchd registration is modified, and no production injection hook is added.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


AGENT = os.environ.get("SWIFTTY_AGENT_BINARY")
FIXTURE = Path(__file__).parent / "Fixtures/agent-signing-interpose.c"


@unittest.skipUnless(sys.platform == "darwin" and AGENT,
                     "set SWIFTTY_AGENT_BINARY for owned native signing fixtures")
class AgentSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.agent = Path(AGENT).resolve(strict=True)
        temporary = tempfile.TemporaryDirectory(prefix="agent-signing-", dir="/tmp")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        cls.library = cls.root / "signing-failure.dylib"
        architectures = subprocess.run(["/usr/bin/lipo", "-archs", str(cls.agent)],
                                       capture_output=True, text=True, check=True, timeout=5)
        command = ["xcrun", "clang", "-dynamiclib", "-framework", "Security",
                   "-Wall", "-Wextra", "-Werror", str(FIXTURE), "-o", str(cls.library)]
        for architecture in architectures.stdout.split():
            command += ["-arch", architecture]
        subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)

    def run_agent(self, stage):
        directory = self.root / stage
        directory.mkdir()
        environment = {**os.environ, "CFFIXED_USER_HOME": str(directory),
                       "DYLD_INSERT_LIBRARIES": str(self.library),
                       "SWIFTTY_TEST_SIGNING_FAILURE": stage}
        process = subprocess.Popen(
            [str(self.agent), "--no-roaming", "--launcher", "/usr/bin/true",
             "--mach-service", "com.chr33s.swiftty.signing-test." + uuid.uuid4().hex,
             "--idle-exit", "0"],
            env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            stdout, stderr = process.communicate(timeout=5)
            return process.returncode, stdout.decode(), stderr.decode(), directory
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()

    def test_lookup_failures_abort_before_service_initialization(self):
        for stage, operation in [("self", "SecCodeCopySelf"),
                                 ("validity", "SecCodeCheckValidity"),
                                 ("static", "SecCodeCopyStaticCode"),
                                 ("information", "SecCodeCopySigningInformation")]:
            with self.subTest(stage=stage):
                status, stdout, stderr, directory = self.run_agent(stage)
                self.assertEqual(status, 78, stderr)
                self.assertEqual(stdout, "")
                self.assertIn("fixture injected signing failure: " + stage, stderr)
                self.assertIn("cannot establish peer signing policy", stderr)
                self.assertIn(operation + " failed (OSStatus -25291)", stderr)
                self.assertFalse((directory / "Library/Application Support/SwiftMux/terminfo").exists())

    def test_verified_ad_hoc_agent_still_starts_and_exits_normally(self):
        signature = subprocess.run(["/usr/bin/codesign", "-d", "-vv", str(self.agent)],
                                   capture_output=True, text=True, check=True, timeout=5)
        self.assertIn("Signature=adhoc", signature.stderr)
        status, _, stderr, directory = self.run_agent("none")
        self.assertEqual(status, 0, stderr)
        self.assertNotIn("cannot establish peer signing policy", stderr)
        self.assertTrue((directory / "Library/Application Support/SwiftMux/terminfo").exists())


if __name__ == "__main__":
    unittest.main()
