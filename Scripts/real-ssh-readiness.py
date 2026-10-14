#!/usr/bin/env python3
"""Bounded startup checks for the real SSH fixture's owned processes."""

import argparse
import ipaddress
import json
import math
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time


class ReadinessError(Exception):
    pass


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def positive_pid(value):
    if not value.isascii() or not value.isdecimal() or value.startswith("0"):
        raise argparse.ArgumentTypeError("PID must be an integer greater than one")
    pid = int(value)
    if not 1 < pid <= 2147483647:
        raise argparse.ArgumentTypeError("PID outside supported range")
    return pid


def require_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError as error:
        raise ReadinessError(f"fixture process {pid} exited before readiness") from error
    except PermissionError as error:
        raise ReadinessError(f"cannot inspect fixture process {pid}") from error


def wait_ready(pid, probe, timeout=10, probe_timeout=1):
    if not math.isfinite(timeout) or timeout <= 0:
        raise ReadinessError("readiness timeout must be finite and positive")
    if not math.isfinite(probe_timeout) or probe_timeout <= 0:
        raise ReadinessError("probe timeout must be finite and positive")
    deadline = time.monotonic() + timeout
    while True:
        require_alive(pid)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ReadinessError(f"fixture process {pid} readiness timed out")
        if probe(min(probe_timeout, remaining)):
            require_alive(pid)
            if time.monotonic() < deadline:
                return
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def wait_host(pid, helper, config, timeout=10):
    def probe(remaining):
        try:
            result = subprocess.run(
                [str(helper), "status"],
                env={**os.environ, "SWIFTMUX_ROAMING_CONFIG": str(config)},
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                timeout=remaining,
            )
            return result.returncode == 0
        except subprocess.TimeoutExpired:
            return False
    wait_ready(pid, probe, timeout)


def wait_listener(pid, path, token, timeout=10):
    def probe(remaining):
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            with os.fdopen(descriptor, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise ReadinessError("listener acknowledgment is not a regular file")
                data = stream.read(4097)
        except FileNotFoundError:
            return False
        if len(data) > 4096:
            raise ReadinessError("listener acknowledgment exceeds 4096 bytes")
        try:
            acknowledgment = json.loads(data)
        except (ValueError, UnicodeError) as error:
            raise ReadinessError("invalid listener acknowledgment") from error
        if (not isinstance(acknowledgment, dict)
                or type(acknowledgment.get("pid")) is not int
                or acknowledgment["pid"] != pid
                or acknowledgment.get("token") != token):
            raise ReadinessError("listener acknowledgment does not match owned process")
        return True
    wait_ready(pid, probe, timeout)


def capture_probe(command, timeout, limit=65536):
    """Return capped stdout only on success; kill/reap failed or timed-out probes."""
    if not math.isfinite(timeout) or timeout <= 0:
        raise ReadinessError("probe timeout must be finite and positive")
    if type(limit) is not int or limit < 0:
        raise ReadinessError("probe output limit must be nonnegative")
    deadline = time.monotonic() + timeout
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        output = bytearray()
        os.set_blocking(process.stdout.fileno(), False)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                if not selector.select(min(0.1, remaining)):
                    continue
                try:
                    data = os.read(process.stdout.fileno(), min(4096, limit + 1 - len(output)))
                except BlockingIOError:
                    continue
                if not data:
                    break
                output.extend(data)
                if len(output) > limit:
                    raise ReadinessError("container probe output exceeds limit")
        try:
            status = process.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            return None
        if status != 0 or time.monotonic() >= deadline:
            return None
        return bytes(output)
    finally:
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            if process.poll() is None:
                process.kill()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired as error:
                    raise ReadinessError("container probe did not exit after SIGKILL") from error
        finally:
            process.stdout.close()
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def container_address(inspection):
    try:
        containers = json.loads(inspection)
        if not isinstance(containers, list) or len(containers) != 1:
            return None
        raw = containers[0]["status"]["networks"][0]["ipv4Address"]
        if not isinstance(raw, str):
            return None
        return str(ipaddress.IPv4Interface(raw).ip)
    except (ValueError, UnicodeError, KeyError, IndexError, TypeError):
        return None


def wait_container(pid, name, timeout=20):
    address = []

    def probe(remaining):
        phase_deadline = time.monotonic() + remaining
        inspection = capture_probe(["container", "inspect", name], remaining)
        if inspection is None:
            return False
        candidate = container_address(inspection)
        if candidate is None:
            return False
        remaining = phase_deadline - time.monotonic()
        if remaining <= 0:
            return False
        if capture_probe(["container", "exec", name, "test", "-s", "/tmp/hostkey.pub"],
                         remaining) is None:
            return False
        address[:] = [candidate]
        return True

    wait_ready(pid, probe, timeout, probe_timeout=2)
    return address[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    host = sub.add_parser("host")
    host.add_argument("pid", type=positive_pid)
    host.add_argument("helper", type=Path)
    host.add_argument("config", type=Path)
    listener = sub.add_parser("listener")
    listener.add_argument("pid", type=positive_pid)
    listener.add_argument("path", type=Path)
    listener.add_argument("token")
    container = sub.add_parser("container")
    container.add_argument("pid", type=positive_pid)
    container.add_argument("name")
    alive = sub.add_parser("alive")
    alive.add_argument("pids", type=positive_pid, nargs="+")
    args = parser.parse_args()

    def interrupt(signum, frame):
        raise Interrupted(signum)

    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        if args.command == "host":
            wait_host(args.pid, args.helper, args.config)
        elif args.command == "listener":
            wait_listener(args.pid, args.path, args.token)
        elif args.command == "container":
            print(wait_container(args.pid, args.name))
        else:
            for pid in args.pids:
                require_alive(pid)
    except Interrupted as error:
        return 128 + error.signum
    except (ReadinessError, OSError) as error:
        print(f"Fixture readiness failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
