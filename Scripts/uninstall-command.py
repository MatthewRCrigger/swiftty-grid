#!/usr/bin/env python3
"""Run an uninstall prerequisite with bounded time and captured output."""

import os
import selectors
import signal
import subprocess
import sys
import time


TIMEOUT = 10
QUIT_TIMEOUT = 5
OUTPUT_LIMIT = 65536
INTERRUPTS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
interrupted_signal = 0


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, frame):
    global interrupted_signal
    if interrupted_signal == 0:
        interrupted_signal = signum


def check_interrupted():
    if interrupted_signal:
        raise Interrupted(interrupted_signal)


def wait_for_exit(process, deadline):
    while True:
        check_interrupted()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("command deadline exceeded")
        try:
            return process.wait(timeout=min(0.1, remaining))
        except subprocess.TimeoutExpired:
            continue


def publish_output(output):
    # The command has been collected before this point. Keep blocking stdout
    # publication interruptible without raising during owned-child cleanup.
    def raise_interrupted(signum, frame):
        first = interrupted_signal == 0
        interrupt(signum, frame)
        if first:
            check_interrupted()

    check_interrupted()
    handlers = {}
    try:
        for signum in INTERRUPTS:
            handlers[signum] = signal.signal(signum, raise_interrupted)
        check_interrupted()
        remaining = memoryview(output)
        while remaining:
            count = os.write(sys.stdout.fileno(), remaining)
            if count == 0:
                raise OSError("stdout write made no progress")
            remaining = remaining[count:]
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)


def run(command, deadline=None):
    check_interrupted()
    if deadline is None:
        deadline = time.monotonic() + TIMEOUT
    if time.monotonic() >= deadline:
        raise TimeoutError("command deadline exceeded")
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    output = bytearray()
    try:
        os.set_blocking(process.stdout.fileno(), False)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                check_interrupted()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("command deadline exceeded")
                if not selector.select(min(0.1, remaining)):
                    continue
                try:
                    data = os.read(process.stdout.fileno(), min(4096, OUTPUT_LIMIT + 1 - len(output)))
                except BlockingIOError:
                    continue
                if not data:
                    break
                output.extend(data)
                if len(output) > OUTPUT_LIMIT:
                    raise ValueError("command output exceeds limit")
        status = wait_for_exit(process, deadline)
        check_interrupted()
        if time.monotonic() >= deadline:
            raise TimeoutError("command deadline exceeded")
        if status < 0:
            raise ValueError(f"command terminated by signal {-status}")
        publish_output(output)
        return status
    finally:
        # Do not collect the leader before signaling its group on failure:
        # keeping the owned child uncollected prevents PID/group reuse.
        try:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    # Darwin may report EPERM for an exited group whose
                    # owned leader has not been collected. Suppress it only
                    # when waiting on this child confirms it already exited.
                    if process.poll() is None:
                        raise
                process.wait(timeout=1)
        finally:
            process.stdout.close()


def wait_app_exit():
    # Every probe and sleep uses the same budget. A slow but successful
    # pgrep must not restart the app's five-second quit deadline.
    deadline = time.monotonic() + QUIT_TIMEOUT
    while True:
        status = run(["pgrep", "-xq", "swiftty"], deadline=deadline)
        if status == 1:
            return 0
        if status != 0:
            raise ValueError(f"cannot inspect running Swiftty processes (status {status})")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Swiftty did not quit")
        time.sleep(min(0.1, remaining))


def main():
    if len(sys.argv) < 2:
        return 125
    for signum in INTERRUPTS:
        signal.signal(signum, interrupt)
    try:
        if sys.argv[1:] == ["--wait-app-exit"]:
            return wait_app_exit()
        return run(sys.argv[1:])
    except Interrupted as error:
        print("uninstall.sh: command interrupted; installation files preserved", file=sys.stderr)
        return 128 + error.signum
    except (TimeoutError, subprocess.TimeoutExpired):
        print("uninstall.sh: command timed out; installation files preserved", file=sys.stderr)
        return 124
    except (OSError, ValueError) as error:
        print(f"uninstall.sh: command failed ({error}); installation files preserved", file=sys.stderr)
        return 125


if __name__ == "__main__":
    sys.exit(main())
