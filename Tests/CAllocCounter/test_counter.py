"""Isolate process-wide malloc hooks: python3 -m unittest discover -s Tests/CAllocCounter -v."""

from pathlib import Path
import subprocess
import tempfile
import unittest


class CounterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.directory = tempfile.TemporaryDirectory(prefix="swiftty-counter-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.binary = Path(cls.directory.name) / "counter"
        subprocess.run(
            ["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I", str(root / "Sources/CAllocCounter/include"),
             str(root / "Sources/CAllocCounter/CAllocCounter.c"),
             str(root / "Tests/CAllocCounter/counter.c"), "-o", str(cls.binary)],
            check=True, capture_output=True, text=True, timeout=30,
        )

    def probe(self, mode):
        result = subprocess.run(
            [str(self.binary), mode], capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_foreign_stop(self):
        self.probe("foreign-stop")

    def test_concurrent_handoff(self):
        self.probe("handoff")

    def test_owner_exit(self):
        self.probe("abandon")

    def test_owner_restart(self):
        self.probe("restart")

    def test_external_hook_replacement(self):
        self.probe("replaced")

    def test_trace_excludes_instrumentation(self):
        self.probe("trace")

    def test_real_heap_allocation(self):
        self.probe("heap")


if __name__ == "__main__":
    unittest.main()
