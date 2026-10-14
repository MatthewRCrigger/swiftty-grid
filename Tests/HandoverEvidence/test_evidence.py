"""Local tests for handover evidence; no SSH, simulator, or device required."""

import importlib.util
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/handover-evidence.py"
SPEC = importlib.util.spec_from_file_location("handover_evidence", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeTime:
    def __init__(self, events=()):
        self.now = 0
        self.events = list(events)

    def clock(self):
        return self.now

    def sleep(self, duration):
        self.now += duration
        while self.events and self.events[0][0] <= self.now:
            _, action = self.events.pop(0)
            action()


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="handover-evidence-")
        self.addCleanup(self.directory.cleanup)
        self.progress = Path(self.directory.name) / "evidence '漢'.log"
        self.progress.write_bytes(b"")

    def append(self, data):
        with self.progress.open("ab") as stream:
            stream.write(data)

    def monitor(self, switches=2, fake=None, **kwargs):
        fake = fake or FakeTime()
        return MODULE.monitor(
            self.progress, switches, clock=fake.clock, sleep=fake.sleep,
            emit=lambda line: None, **kwargs
        )

    def test_valid_modes_and_ordered_shell_evidence(self):
        self.append(b"ready-4312\nhop-1-4312-cellular-migrated\n"
                    b"hop-2-4312-wifi-reattached\ndone-4312\n")
        result = self.monitor()
        self.assertTrue(result.done)
        self.assertEqual(result.hops, 2)
        self.assertEqual(result.pid, "4312")
        self.assertEqual(result.summary(),
                         "2 hop lines, 1 distinct shell pid, 0 duplicated hops, "
                         "1 migrated, 1 reattached")

    def test_valid_evidence_crosses_read_chunk_boundaries(self):
        self.append(b"ready-4312\n")
        for hop in range(1, 201):
            path = "wifi" if hop % 2 else "cellular"
            self.append(f"hop-{hop}-4312-{path}-migrated\n".encode("ascii"))
        self.append(b"done-4312\n")
        self.assertGreater(self.progress.stat().st_size, 4096)
        result = self.monitor(200)
        self.assertEqual(result.migrated, 200)
        self.assertTrue(result.done)

    def test_missing_duplicate_extra_or_reordered_hops_fail(self):
        cases = [
            b"done-4312\n",
            b"hop-2-4312-wifi-migrated\n",
            b"hop-1-4312-wifi-migrated\nhop-1-4312-cellular-migrated\n",
            b"hop-1-4312-wifi-migrated\nhop-3-4312-cellular-migrated\n",
            b"hop-1-4312-wifi-migrated\nhop-2-4312-cellular-migrated\n"
            b"hop-3-4312-wifi-migrated\n",
        ]
        for suffix in cases:
            with self.subTest(suffix=suffix):
                self.progress.write_bytes(b"ready-4312\n" + suffix)
                with self.assertRaises(MODULE.EvidenceError):
                    self.monitor()

    def test_every_stage_keeps_one_pid(self):
        for suffix in [
            b"ready-999\n", b"hop-1-999-cellular-migrated\n",
            b"hop-1-4312-cellular-migrated\ndone-999\n",
        ]:
            with self.subTest(suffix=suffix):
                self.progress.write_bytes(b"ready-4312\n" + suffix)
                with self.assertRaises(MODULE.EvidenceError):
                    self.monitor(1)

    def test_paths_and_modes_are_required_and_paths_change(self):
        for suffix in [
            b"hop-1-4312\n", b"hop-1-4312-wifi-unknown\n",
            b"hop-1-4312-none-migrated\n",
            b"hop-1-4312-wifi-migrated\nhop-2-4312-wifi-reattached\n",
        ]:
            with self.subTest(suffix=suffix):
                self.progress.write_bytes(b"ready-4312\n" + suffix)
                with self.assertRaises(MODULE.EvidenceError):
                    self.monitor()

    def test_echo_controls_non_ascii_and_bad_pids_fail(self):
        for record in [
            b"printf 'ready-%s\\n' \"$$\"", b"prompt ready-4312",
            b"ready-0", b"ready-+1", b"ready-01", b"ready-4312 trailing",
            b"ready-4312\r", b"ready-4312\x1b", b"ready-\xff", b"",
        ]:
            with self.subTest(record=record):
                self.progress.write_bytes(record + b"\n")
                with self.assertRaises(MODULE.EvidenceError):
                    self.monitor()

    def test_failure_marker_in_every_phase_is_immediate(self):
        for prefix in [
            b"", b"ready-4312\n",
            b"ready-4312\nhop-1-4312-wifi-migrated\n",
        ]:
            with self.subTest(prefix=prefix):
                self.progress.write_bytes(prefix + b"FAILED-anything\n")
                fake = FakeTime()
                with self.assertRaisesRegex(MODULE.EvidenceError, "reported failure"):
                    self.monitor(1, fake)
                self.assertEqual(fake.now, 0)

    def test_extra_complete_and_partial_output_after_done_fail(self):
        valid = b"ready-4312\nhop-1-4312-wifi-migrated\ndone-4312\n"
        for extra in [b"done-4312\n", b"garbage\n", b"partial"]:
            with self.subTest(extra=extra):
                self.progress.write_bytes(valid + extra)
                with self.assertRaisesRegex(MODULE.EvidenceError, "follows completion"):
                    self.monitor(1)

    def test_silent_app_and_missing_done_have_bounded_deadlines(self):
        for prefix, phase in [
            (b"", "ready"),
            (b"ready-4312\n", "hop 1"),
            (b"ready-4312\nhop-1-4312-wifi-migrated\n", "done"),
        ]:
            with self.subTest(phase=phase):
                self.progress.write_bytes(prefix)
                fake = FakeTime()
                with self.assertRaisesRegex(MODULE.EvidenceError,
                                            "timed out waiting for " + phase):
                    self.monitor(1, fake, ready_timeout=0.3,
                                 hop_timeout=0.3, done_timeout=0.3)
                self.assertAlmostEqual(fake.now, 0.3)

    def test_only_verified_progress_refreshes_deadline(self):
        fake = FakeTime([
            (1, lambda: self.append(b"ready-4312\n")),
            (2, lambda: self.append(b"hop-1-")),
            (6, lambda: self.append(b"4312-wifi-migrated\n")),
        ])
        with self.assertRaisesRegex(MODULE.EvidenceError, "waiting for hop 1"):
            self.monitor(1, fake, ready_timeout=2, hop_timeout=4)
        self.assertEqual(fake.now, 5)

    def test_success_refreshes_each_phase_deadline(self):
        fake = FakeTime([
            (1, lambda: self.append(b"ready-4312\n")),
            (4, lambda: self.append(b"hop-1-4312-wifi-migrated\n")),
            (7, lambda: self.append(b"hop-2-4312-cellular-reattached\n")),
            (8, lambda: self.append(b"done-4312\n")),
        ])
        result = self.monitor(2, fake, ready_timeout=2, hop_timeout=4,
                              done_timeout=2)
        self.assertTrue(result.done)
        self.assertEqual(fake.now, 8)

    def test_partial_records_wait_for_newline(self):
        self.append(b"ready-4312")
        fake = FakeTime([(1, lambda: self.append(
            b"\nhop-1-4312-wifi-migrated\ndone-4312\n"
        ))])
        self.assertTrue(self.monitor(1, fake).done)
        self.assertEqual(fake.now, 1)

    def test_oversized_complete_and_partial_lines_are_refused(self):
        for ending in [b"", b"\n"]:
            with self.subTest(ending=ending):
                self.progress.write_bytes(b"x" * 257 + ending)
                with self.assertRaisesRegex(MODULE.EvidenceError, "too long"):
                    self.monitor()

    def test_truncated_log_fails(self):
        self.append(b"ready-4312\n")
        fake = FakeTime([(1, lambda: self.progress.write_bytes(b""))])
        with self.assertRaisesRegex(MODULE.EvidenceError, "truncated"):
            self.monitor(1, fake)

    def test_incomplete_state_cannot_produce_summary(self):
        with self.assertRaises(MODULE.EvidenceError):
            MODULE.Evidence(1).summary()

    def test_cli_exits_zero_only_for_complete_valid_evidence(self):
        valid = b"ready-4312\nhop-1-4312-wifi-migrated\ndone-4312\n"
        for data, code in [(valid, 0), (b"done-4312\n", 1),
                           (b"FAILED-run\n", 1)]:
            with self.subTest(data=data):
                self.progress.write_bytes(data)
                result = subprocess.run(
                    [sys.executable, "-I", str(SCRIPT), str(self.progress), "1"],
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(b"HANDOVER summary:" in result.stdout, code == 0)

    def test_cli_refuses_bad_counts_and_missing_file(self):
        for count in ["0", "-1", "", "invalid", "+1",
                      "9223372036854775808", "9" * 5000]:
            with self.subTest(count=count):
                result = subprocess.run(
                    [sys.executable, "-I", str(SCRIPT), str(self.progress), count],
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 2)
        self.progress.unlink()
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(self.progress), "1"],
            capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"HANDOVER failed:", result.stderr)

    def test_driver_monitor_propagates_success_and_failure(self):
        driver = SCRIPT.with_name("test-handover.sh").read_text()
        monitor_body = driver[driver.index("# Validate ordered hops"):]
        valid = b"ready-4312\nhop-1-4312-wifi-migrated\ndone-4312\n"
        for data, code in [(valid, 0), (b"done-4312\n", 1)]:
            with self.subTest(data=data):
                self.progress.write_bytes(data)
                result = subprocess.run(
                    ["/bin/sh", "-c", "set -eu\nrepository_root=$1\n"
                     "progress=$2\nswitches=$3\n" + monitor_body,
                     "handover-monitor", str(SCRIPT.parent.parent),
                     str(self.progress), "1"],
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, code, result.stderr)

    def test_cli_reports_live_progress_and_can_be_interrupted(self):
        self.append(b"ready-4312\n")
        process = subprocess.Popen(
            [sys.executable, "-I", str(SCRIPT), str(self.progress), "1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=5),
                                "ready output remained buffered")
                self.assertEqual(process.stdout.readline(),
                                 b"HANDOVER mac-log: ready-4312\n")
            process.send_signal(signal.SIGINT)
            self.assertEqual(process.wait(timeout=5), 130)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
