#!/usr/bin/env python3
"""Wait for and validate the retained shell's physical handover evidence."""

import argparse
import re
import sys
import time
from pathlib import Path


class EvidenceError(Exception):
    pass


class Evidence:
    def __init__(self, switches):
        if switches <= 0:
            raise EvidenceError("switches must be positive")
        self.switches = switches
        self.pid = None
        self.hops = 0
        self.path = None
        self.migrated = 0
        self.reattached = 0
        self.done = False

    def accept(self, line):
        if self.done:
            raise EvidenceError("output follows completion")
        if line.startswith("FAILED-"):
            raise EvidenceError("the app reported failure")
        if self.pid is None:
            match = re.fullmatch(r"ready-([1-9][0-9]{0,18})", line)
            if not match:
                raise EvidenceError("expected initial shell PID")
            self.pid = match[1]
            return
        match = re.fullmatch(
            r"hop-([1-9][0-9]{0,18})-([1-9][0-9]{0,18})-"
            r"(wifi|cellular)-(migrated|reattached)", line
        )
        if match:
            hop, pid, path, mode = match.groups()
            if int(hop) != self.hops + 1 or self.hops == self.switches:
                raise EvidenceError("unexpected, duplicate, or extra hop")
            if pid != self.pid:
                raise EvidenceError("shell PID changed")
            if path == self.path:
                raise EvidenceError("consecutive hops use the same network")
            self.hops += 1
            self.path = path
            if mode == "migrated":
                self.migrated += 1
            else:
                self.reattached += 1
            return
        if line == "done-" + self.pid:
            if self.hops != self.switches:
                raise EvidenceError("completion arrived before all hops")
            self.done = True
            return
        raise EvidenceError("malformed evidence or changed shell PID")

    def summary(self):
        if not self.done:
            raise EvidenceError("evidence is incomplete")
        return (f"{self.hops} hop lines, 1 distinct shell pid, 0 duplicated hops, "
                f"{self.migrated} migrated, {self.reattached} reattached")


def report(line):
    print(line, flush=True)


def monitor(progress, switches, *, clock=time.monotonic, sleep=time.sleep,
            emit=report, ready_timeout=180, hop_timeout=1290, done_timeout=60):
    # The app allows 900s to toggle, 180s to recover, and 180s for output.
    # Only a verified ready/hop record advances this finite sequence.
    evidence = Evidence(switches)
    deadline = clock() + ready_timeout
    pending = b""
    with progress.open("rb") as source:
        while True:
            if clock() >= deadline:
                phase = ("ready" if evidence.pid is None else
                         "done" if evidence.hops == switches else
                         f"hop {evidence.hops + 1}")
                raise EvidenceError(f"timed out waiting for {phase}")
            if progress.stat().st_size < source.tell():
                raise EvidenceError("evidence log was truncated")
            chunk = source.read(4096)
            if chunk:
                pending += chunk
                while b"\n" in pending:
                    raw, pending = pending.split(b"\n", 1)
                    if len(raw) > 256:
                        raise EvidenceError("evidence line is too long")
                    try:
                        line = raw.decode("ascii")
                    except UnicodeDecodeError as error:
                        raise EvidenceError("evidence is not ASCII") from error
                    evidence.accept(line)
                    emit("HANDOVER mac-log: " + line)
                    timeout = (done_timeout if evidence.hops == switches
                               else hop_timeout)
                    deadline = clock() + timeout
                if len(pending) > 256:
                    raise EvidenceError("evidence line is too long")
                continue
            if evidence.done:
                if pending:
                    raise EvidenceError("partial output follows completion")
                return evidence
            sleep(min(1, max(0, deadline - clock())))


def positive(value):
    try:
        count = int(value) if re.fullmatch(r"[0-9]+", value) else 0
    except ValueError:
        count = 0
    if not 0 < count <= sys.maxsize:
        raise argparse.ArgumentTypeError("switches must be a positive integer")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("progress", type=Path)
    parser.add_argument("switches", type=positive)
    args = parser.parse_args()
    try:
        evidence = monitor(args.progress, args.switches)
    except (OSError, EvidenceError) as error:
        print(f"HANDOVER failed: {error}; evidence: {args.progress}",
              file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    print("HANDOVER summary: " + evidence.summary())
    return 0


if __name__ == "__main__":
    sys.exit(main())
