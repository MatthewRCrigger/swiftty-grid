#!/usr/bin/env python3
"""Require completed, unskipped RealOpenSSH tests from Swift Testing JSONL v0."""

import json
from pathlib import Path
import sys


SUITE = "IntegrationTests.RealOpenSSHTests"
NAMES = {
    "unknown OpenSSH host key needs a decision and matches the server",
    "roaming session bootstraps over OpenSSH exec and attaches over QUIC",
    "ordinary SSH shell works as the UDP-blocked fallback",
    "SFTP upload and download round trip through OpenSSH sftp-server",
}


def require_evidence(path):
    descriptors = {}
    started, ended = set(), set()
    in_run = False
    runs = 0
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("event stream exceeds 16 MiB")
    with path.open() as stream:
        for line in stream:
            record = json.loads(line)
            if (not isinstance(record, dict) or type(record.get("version")) is not int
                    or record["version"] != 0 or not isinstance(record.get("payload"), dict)):
                raise ValueError("unsupported event stream record")
            payload = record["payload"]
            if record.get("kind") == "test":
                identity = payload.get("id")
                if not isinstance(identity, str) or identity in descriptors:
                    raise ValueError("invalid or repeated test descriptor")
                descriptors[identity] = payload
                continue
            if record.get("kind") != "event":
                raise ValueError("unknown record kind")
            kind = payload.get("kind")
            if kind in {"issueRecorded", "testSkipped"}:
                raise ValueError(f"test event reports {kind}")
            if kind == "runStarted":
                if in_run:
                    raise ValueError("overlapping runs")
                in_run = True
            elif kind == "runEnded":
                if not in_run or started != ended:
                    raise ValueError("run ended without completed tests")
                in_run = False
                runs += 1
            elif kind in {"testStarted", "testEnded"}:
                identity = payload.get("testID")
                if not in_run or identity not in descriptors:
                    raise ValueError("test event outside a run or without descriptor")
                target = started if kind == "testStarted" else ended
                if identity in target or (kind == "testEnded" and identity not in started):
                    raise ValueError("repeated or out-of-order test event")
                target.add(identity)
            elif kind not in {"testCaseStarted", "testCaseEnded", "valueAttached"}:
                raise ValueError(f"unsupported event kind: {kind}")
    functions = {key: value for key, value in descriptors.items()
                 if value.get("kind") == "function"}
    names = {value.get("name") for value in functions.values()}
    expected_names = {f"`{name}`()" for name in NAMES}
    if (in_run or runs == 0 or names != expected_names or len(functions) != 4
            or any(not key.startswith(SUITE + "/")
                   or value.get("isParameterized") is not False
                   for key, value in functions.items())
            or set(functions) | {SUITE} != ended
            or descriptors.get(SUITE, {}).get("kind") != "suite"):
        raise ValueError("stream does not prove all four RealOpenSSH tests completed")


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <event-stream.jsonl>", file=sys.stderr)
        return 2
    try:
        require_evidence(Path(sys.argv[1]))
    except (OSError, ValueError, TypeError) as error:
        print(f"Real OpenSSH test evidence failed: {error}", file=sys.stderr)
        return 1
    print("Verified all four RealOpenSSH tests completed without skips or issues.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
