"""Native launcher report failures, with per-binary syscall substitution."""

import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
DRIVER = r'''
#define main production_main
#define write report_write
#define execve fixture_execve
#include "launcher.c"
#undef main
#undef write
#undef execve

static int attempts;
static unsigned char received[128];
static size_t used;

ssize_t report_write(int fd, const void *buffer, size_t count) {
  attempts++;
  const char *mode = getenv("REPORT_FIXTURE_MODE");
  if (fd != 4 || count > sizeof received - used) {
    errno = EOVERFLOW;
    return -1;
  }
  if (strcmp(mode, "interrupted") == 0 && attempts == 1) {
    errno = EINTR;
    return -1;
  }
  if (strcmp(mode, "error") == 0) {
    errno = EIO;
    return -1;
  }
  if (strcmp(mode, "zero") == 0) return 0;
  size_t amount = strcmp(mode, "partial") == 0 && count > 2 ? 2 : count;
  memcpy(received + used, buffer, amount);
  used += amount;
  return (ssize_t)amount;
}

int fixture_execve(const char *path, char *const argv[], char *const environment[]) {
  (void)path; (void)argv; (void)environment;
  const char *marker = getenv("REPORT_FIXTURE_MARKER");
  int fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) _exit(81);
  if (pwrite(fd, "exec attempted", 14, 0) != 14) _exit(82);
  close(fd);
  _exit(0);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "unit") == 0) {
    report("S", "exec", 0);
    printf("{\"attempts\":%d,\"bytes\":%zu,\"hex\":\"", attempts, used);
    for (size_t i = 0; i < used; ++i) printf("%02x", received[i]);
    puts("\"}");
    return 0;
  }
  return production_main(argc, argv);
}
'''


@unittest.skipUnless(sys.platform == "darwin", "native Darwin launcher fixture")
class LauncherReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="swiftty-report-fixture-")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        shutil.copyfile(ROOT / "Sources/SwiftMuxLauncher/main.c", cls.root / "launcher.c")
        (cls.root / "driver.c").write_text(DRIVER)
        cls.binary = cls.root / "driver"
        result = subprocess.run(
            ["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
             str(cls.root / "driver.c"), "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr)

    def report(self, mode):
        result = subprocess.run(
            [str(self.binary), "unit"],
            env={**os.environ, "REPORT_FIXTURE_MODE": mode},
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_interrupted_write_retries_the_entire_unwritten_report(self):
        result = self.report("interrupted")
        self.assertEqual(result["hex"], b"S exec 0\n".hex())
        self.assertEqual(result["attempts"], 2)

    def test_partial_writes_preserve_each_unwritten_suffix(self):
        result = self.report("partial")
        self.assertEqual(result["hex"], b"S exec 0\n".hex())
        self.assertEqual(result["bytes"], 9)
        self.assertEqual(result["attempts"], 5)

    def test_zero_and_hard_failure_do_not_spin(self):
        for mode in ["zero", "error"]:
            with self.subTest(mode=mode):
                result = self.report(mode)
                self.assertEqual(result["bytes"], 0)
                self.assertEqual(result["attempts"], 1)

    def test_failed_success_report_never_attempts_exec(self):
        for mode in ["zero", "error"]:
            with self.subTest(mode=mode):
                self.run_native(mode)

    def test_successful_complete_interrupted_and_partial_reports_allow_exec(self):
        for mode in ["complete", "interrupted", "partial"]:
            with self.subTest(mode=mode):
                self.run_native(mode, expect_exec=True)

    def test_failed_directory_warning_never_attempts_exec(self):
        for mode in ["zero", "error"]:
            with self.subTest(mode=mode):
                self.run_native(mode, missing_directory=True)

    def run_native(self, mode, expect_exec=False, missing_directory=False):
        marker = self.root / ("exec-" + mode + ("-warning" if missing_directory else ""))
        directory = self.root / "nonexistent" if missing_directory else self.root
        master, slave = os.openpty()
        read_fd, write_fd = os.pipe()
        # Keep dup2 sources above the child's dedicated 3/4 destinations.
        moved_slave = fcntl.fcntl(slave, fcntl.F_DUPFD_CLOEXEC, 5)
        moved_write = fcntl.fcntl(write_fd, fcntl.F_DUPFD_CLOEXEC, 5)
        descriptors = [master, slave, read_fd, write_fd, moved_slave, moved_write]
        pid = None
        collected = False
        try:
            pid = os.posix_spawn(
                str(self.binary), [str(self.binary), str(directory), "/usr/bin/true", "true"],
                {**os.environ, "REPORT_FIXTURE_MODE": mode, "REPORT_FIXTURE_MARKER": str(marker)},
                file_actions=[(os.POSIX_SPAWN_DUP2, moved_slave, 3),
                              (os.POSIX_SPAWN_DUP2, moved_write, 4)],
            )
            for fd in [write_fd, moved_write]:
                os.close(fd)
                descriptors.remove(fd)
            ready, _, _ = select.select([read_fd], [], [], 5)
            self.assertTrue(ready, "launcher report did not close")
            self.assertEqual(os.read(read_fd, 128), b"")
            deadline = time.monotonic() + 5
            status = None
            while time.monotonic() < deadline:
                result, observed = os.waitpid(pid, os.WNOHANG)
                if result == pid:
                    collected = True
                    status = observed
                    break
                time.sleep(0.001)
            self.assertIsNotNone(status, "owned launcher did not exit")
            self.assertEqual(marker.exists(), expect_exec, "unexpected exec attempt state")
            self.assertEqual(os.waitstatus_to_exitcode(status), 0 if expect_exec else 127)
        finally:
            if pid is not None and not collected:
                # This child is still exclusively owned and unreaped.
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            for fd in descriptors:
                os.close(fd)


if __name__ == "__main__":
    unittest.main()
