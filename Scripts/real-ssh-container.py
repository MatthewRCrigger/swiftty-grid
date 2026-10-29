#!/usr/bin/env python3
"""Remove a recorded fixture VM, or verify it is already absent."""

import json
import os
from pathlib import Path
import re
import signal
import stat
import sys

# -I excludes the script directory; add only our trusted sibling modules.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from real_ssh_commands import CommandError, capture_command

COMMAND_TIMEOUT = 10
LIST_LIMIT = 1024 * 1024


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def read_name(marker):
    descriptor = os.open(marker, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("container marker is not a regular file")
        data = stream.read(257)
    if len(data) > 256 or not re.fullmatch(rb"swiftty-rst-ssh-[a-zA-Z0-9-]+\n?", data):
        raise ValueError("invalid fixture container name")
    return data, data.rstrip(b"\n").decode("ascii")


def absent(name, data):
    if data is None:
        raise ValueError("container list failed or timed out; absence is unverified")
    try:
        records = json.loads(data)
        if not isinstance(records, list) or any(
            not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]
            for row in records
        ):
            raise ValueError("invalid container list schema")
        identifiers = [row["id"] for row in records]
        if len(set(identifiers)) != len(identifiers):
            raise ValueError("duplicate IDs in container list")
        return name not in identifiers
    except (UnicodeError, RecursionError) as error:
        raise ValueError("invalid container list") from error


def remove(marker, timeout=COMMAND_TIMEOUT):
    try:
        original, name = read_name(marker)
    except FileNotFoundError:
        return
    # Never infer absence from a failed delete/inspect or an error message.
    # A successful complete listing must establish that this ID is absent.
    removed = capture_command(["container", "rm", "-f", name], timeout)
    if removed is None:
        listing = capture_command(["container", "list", "--all", "--format", "json"],
                                  timeout, limit=LIST_LIMIT)
        if not absent(name, listing):
            raise ValueError(f"cannot remove fixture container {name}: still present")
    try:
        current, _ = read_name(marker)
    except FileNotFoundError:
        return
    if current != original:
        raise ValueError("container marker changed during removal; retained")
    marker.unlink()


def main():
    if len(sys.argv) != 2:
        print("usage: real-ssh-container.py STATE-DIRECTORY", file=sys.stderr)
        return 2

    def interrupt(signum, frame):
        raise Interrupted(signum)

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        remove(Path(sys.argv[1]) / "container.name")
    except Interrupted as error:
        return 128 + error.signum
    except (OSError, ValueError, CommandError) as error:
        print(f"Fixture container cleanup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
