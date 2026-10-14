"""Check the real SSH gate using captured Swift Testing v0 records."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("real_ssh_evidence", ROOT / "Scripts/real-ssh-evidence.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FIXTURE = Path(__file__).parent / "Fixtures/real-ssh-events.jsonl"


class RealSSHEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "events.jsonl"
        self.records = [json.loads(line) for line in FIXTURE.read_text().splitlines()]

    def check(self, records):
        self.path.write_text("".join(json.dumps(record) + "\n" for record in records))
        MODULE.require_evidence(self.path)

    def test_captured_completed_run_passes(self):
        self.check(self.records)

    def test_empty_truncated_or_missing_run_fails(self):
        for records in [[], self.records[:-1], self.records[:5], self.records[5:]]:
            with self.subTest(records=len(records)), self.assertRaises(ValueError):
                self.check(records)

    def test_skip_and_issues_fail_even_with_all_completion_events(self):
        for kind in ["testSkipped", "issueRecorded"]:
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.check(self.records[:-1] + [{"version": 0, "kind": "event",
                                                "payload": {"kind": kind}}] + self.records[-1:])

    def test_wrong_identity_missing_test_or_duplicate_execution_fails(self):
        for index, key, value in [(1, "id", "OtherTests.test"), (1, "name", "other()"),
                                  (1, "isParameterized", True)]:
            records = json.loads(json.dumps(self.records))
            records[index]["payload"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(records)
        for records in [self.records[:1] + self.records[2:],
                        self.records[:6] + self.records[6:7] + self.records[6:],
                        self.records[:1] + self.records,
                        self.records + self.records]:
            with self.assertRaises(ValueError):
                self.check(records)

    def test_invalid_records_and_unsupported_versions_fail(self):
        for record in [None, [], {}, {"version": True},
                       {"version": 1, "kind": "event", "payload": {}},
                       {"version": 0, "kind": "event", "payload": {"kind": "futureEvent"}}]:
            with self.subTest(record=record), self.assertRaises(ValueError):
                self.check([record])
        self.path.write_text('{"version":')
        with self.assertRaises(ValueError):
            MODULE.require_evidence(self.path)

    def test_unexpected_execution_and_out_of_order_completion_fail(self):
        records = json.loads(json.dumps(self.records))
        records[7]["payload"]["kind"] = "testEnded"
        with self.assertRaises(ValueError):
            self.check(records)
        records = json.loads(json.dumps(self.records))
        records[1]["payload"]["id"] = "OtherTests.RealOpenSSHTests/foo"
        with self.assertRaises(ValueError):
            self.check(records)


if __name__ == "__main__":
    unittest.main()
