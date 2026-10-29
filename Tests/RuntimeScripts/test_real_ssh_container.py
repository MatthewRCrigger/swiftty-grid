"""Bounded VM retirement without confusing absence with a daemon failure."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from owned_tool_leases import OwnedToolLeases, TOOL_LEASE

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/real-ssh-container.py"
SPEC = importlib.util.spec_from_file_location("real_ssh_container", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ContainerCleanupTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ssh-container-", dir="/tmp")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.marker = self.root / "container.name"
        self.name = "swiftty-rst-ssh-owned-test"
        self.marker.write_text(self.name + "\n")
        self.leases = OwnedToolLeases(self.root)
        self.addCleanup(self.leases.close)
        self.environment = {**self.leases.environment,
                            "PATH": str(self.root) + os.pathsep + os.environ["PATH"]}

    def tool(self, delete, listing="print('[]')"):
        tool = self.root / "container"
        tool.write_text(
            "#!" + sys.executable + "\nimport json, os, signal, sys, time\n"
            "from pathlib import Path\nname = 'container'\n" + TOOL_LEASE + "\n"
            f"root=Path({str(self.root)!r})\n"
            "with (root/'calls').open('a') as stream:\n"
            " stream.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "(root/(sys.argv[1]+'.pid')).write_text(str(os.getpid()))\n"
            "if sys.argv[1]=='rm':\n" + self.indent(delete) + "\n"
            "elif sys.argv[1]=='list':\n" + self.indent(listing) + "\n"
        )
        tool.chmod(0o755)

    @staticmethod
    def indent(body):
        return "\n".join(" " + line for line in body.splitlines())

    def remove(self, timeout=0.5):
        with mock.patch.dict(os.environ, self.environment):
            MODULE.remove(self.marker, timeout=timeout)

    def assert_tools_reaped(self):
        for record in self.root.glob("*.pid"):
            with self.assertRaises(ProcessLookupError):
                os.kill(int(record.read_text()), 0)

    def test_successful_removal_needs_no_listing_and_is_idempotent(self):
        self.tool("print('removed')")
        self.remove()
        self.assertFalse(self.marker.exists())
        self.remove()
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        self.assertEqual(calls, [["rm", "-f", self.name]])
        self.assert_tools_reaped()

    def test_absence_uses_successful_complete_listing_and_exact_id(self):
        for identifiers in [[], [self.name + "-other"], ["other-container"], [self.name]]:
            with self.subTest(identifiers=identifiers):
                self.marker.write_text(self.name + "\n")
                listing = json.dumps([{"id": value} for value in identifiers])
                self.tool("sys.exit(74)", f"print({listing!r})")
                if self.name in identifiers:
                    with self.assertRaisesRegex(ValueError, "still present"):
                        self.remove()
                    self.assertTrue(self.marker.exists())
                else:
                    self.remove()
                    self.assertFalse(self.marker.exists())
                self.assert_tools_reaped()

    def test_nonzero_list_exit_cannot_prove_absence_even_with_valid_json(self):
        self.tool("sys.exit(74)", "print('[]')\nsys.exit(78)")
        with self.assertRaisesRegex(ValueError, "unverified"):
            self.remove()
        self.assertTrue(self.marker.exists())
        self.assert_tools_reaped()

    def test_hung_delete_or_listing_is_killed_and_reaped(self):
        for stage in ["rm", "list"]:
            with self.subTest(stage=stage):
                hang = "signal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(30)"
                self.tool(hang if stage == "rm" else "sys.exit(74)",
                          hang if stage == "list" else f"print('[{{\"id\":\"{self.name}\"}}]')")
                started = time.monotonic()
                with self.assertRaises(ValueError):
                    self.remove(timeout=0.3)
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(self.marker.read_text(), self.name + "\n")
                self.assert_tools_reaped()

    def test_flooded_delete_or_listing_is_capped_and_reaped(self):
        for stage in ["rm", "list"]:
            with self.subTest(stage=stage):
                flood = "while True: os.write(1, b'x'*65536)"
                self.tool(flood if stage == "rm" else "sys.exit(74)",
                          flood if stage == "list" else "print('[]')")
                with self.assertRaisesRegex(MODULE.CommandError, "exceeds limit"):
                    self.remove(timeout=2)
                self.assertTrue(self.marker.exists())
                self.assert_tools_reaped()

    def test_changed_marker_is_not_removed_after_successful_delete(self):
        self.tool("(root/'container.name').write_text('swiftty-rst-ssh-replacement\\n')")
        with self.assertRaisesRegex(ValueError, "marker changed"):
            self.remove()
        self.assertEqual(self.marker.read_text(), "swiftty-rst-ssh-replacement\n")

    def test_invalid_or_nonregular_marker_never_invokes_container(self):
        self.tool("raise AssertionError('must not run')")
        for data in [b"", b"--all", b"other-container", b"swiftty-rst-ssh-", b"\xff",
                     b"swiftty-rst-ssh-test\nother", b"swiftty-rst-ssh-" + b"x"*300]:
            with self.subTest(data=data[:30]):
                self.marker.write_bytes(data)
                with self.assertRaises(ValueError):
                    self.remove()
                self.assertEqual(self.marker.read_bytes(), data)
        self.marker.unlink()
        os.mkfifo(self.marker)
        with self.assertRaisesRegex(ValueError, "regular file"):
            self.remove()
        self.marker.unlink()
        unrelated = self.root / "unrelated"
        unrelated.write_text(self.name + "\n")
        self.marker.symlink_to(unrelated)
        with self.assertRaises(OSError):
            self.remove()
        self.assertTrue(self.marker.is_symlink())
        self.assertEqual(unrelated.read_text(), self.name + "\n")
        self.assertFalse((self.root / "calls").exists())

    def test_duplicate_or_invalid_ids_cannot_prove_absence(self):
        for data in [b'[{"id":"other"},{"id":"other"}]', b"[null]", b"\xff",
                     b"["*2000 + b"]"*2000]:
            with self.subTest(data=data[:30]), self.assertRaises(ValueError):
                MODULE.absent(self.name, data)

    def test_interrupted_cleanup_reaps_command_and_preserves_marker(self):
        self.tool("time.sleep(30)")
        with subprocess.Popen([sys.executable, "-I", str(SCRIPT), str(self.root)],
                              env={**os.environ, **self.environment},
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as driver:
            try:
                deadline = time.monotonic() + 3
                while not (self.root / "rm.pid").exists():
                    self.assertIsNone(driver.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                driver.send_signal(signal.SIGTERM)
                self.assertEqual(driver.wait(timeout=3), 143)
                self.assertEqual(self.marker.read_text(), self.name + "\n")
                self.assert_tools_reaped()
            finally:
                if driver.poll() is None:
                    driver.kill()
                driver.wait(timeout=3)

    def test_signal_during_child_creation_cannot_escape_owned_cleanup(self):
        for signum in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signum=signum):
                owned = []
                original_popen = subprocess.Popen
                original_handler = signal.getsignal(signum)

                def interrupt(received, frame):
                    raise MODULE.Interrupted(received)

                def spawn(*args, **kwargs):
                    child = original_popen(*args, **kwargs)
                    owned.append(child)
                    # Deliver a real signal after child creation but before
                    # the caller can assign the returned ownership handle.
                    signal.raise_signal(signum)
                    return child

                signal.signal(signum, interrupt)
                try:
                    with mock.patch.object(subprocess, "Popen", side_effect=spawn):
                        with self.assertRaises(MODULE.Interrupted) as raised:
                            MODULE.capture_command(["/bin/sleep", "30"], timeout=1)
                    self.assertEqual(raised.exception.signum, signum)
                    self.assertIs(signal.getsignal(signum), interrupt)
                    self.assertEqual(len(owned), 1)
                    self.assertIsNotNone(owned[0].returncode, "interruption skipped child reap")
                finally:
                    signal.signal(signum, original_handler)
                    for child in owned:
                        if child.poll() is None:
                            child.kill()
                        child.wait(timeout=3)
                        child.stdout.close()


if __name__ == "__main__":
    unittest.main()
