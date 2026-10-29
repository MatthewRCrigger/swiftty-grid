"""Capped, deadline-bound command output with owned-child cleanup."""

from contextlib import contextmanager
import math
import os
import selectors
import signal
import subprocess
import threading
import time


class CommandError(Exception):
    pass


@contextmanager
def defer_interrupts():
    """Delay raising handlers until a newly spawned child has an owner."""
    if threading.current_thread() is not threading.main_thread():
        # Python delivers signal handlers on the main thread, not this one.
        yield
        return
    handlers = {}
    pending = {}

    def remember(signum, frame):
        pending.setdefault(signum, frame)

    try:
        for signum in [signal.SIGINT, signal.SIGTERM]:
            handler = signal.getsignal(signum)
            if callable(handler):
                handlers[signum] = handler
                signal.signal(signum, remember)
        yield
    finally:
        # Restore all handlers before delivering an interrupt that may raise.
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, set(handlers))
        try:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        for signum, frame in pending.items():
            handlers[signum](signum, frame)


def capture_command(command, timeout, limit=65536):
    """Return capped stdout only on success; kill/reap failed or timed-out probes."""
    if not math.isfinite(timeout) or timeout <= 0:
        raise CommandError("command timeout must be finite and positive")
    if type(limit) is not int or limit < 0:
        raise CommandError("command output limit must be nonnegative")
    deadline = time.monotonic() + timeout
    process = None
    try:
        with defer_interrupts():
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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
                    raise CommandError("command output exceeds limit")
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
            if process is not None and process.poll() is None:
                process.kill()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired as error:
                    raise CommandError("command did not exit after SIGKILL") from error
        finally:
            if process is not None:
                process.stdout.close()
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

