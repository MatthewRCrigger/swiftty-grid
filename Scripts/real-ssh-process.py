#!/usr/bin/env python3
"""Own real-SSH fixture children across separate start/stop invocations.

PID files are informational. Only the parent holding the unreaped Popen child
may signal it; stop clients use a private, authenticated lifetime socket instead.
"""

import json
import os
from pathlib import Path
import secrets
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

ROLES = {"host", "bridge", "relay", "advertiser", "xcodebuild"}
TIMEOUT = 10
# Proxies have a five-second worker/descendant cleanup budget of their own.
TERMINATION_GRACE = 6


def read_record(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError(f"not a regular file: {path}")
        data = stream.read(4097)
    if len(data) > 4096:
        raise ValueError(f"oversized process record: {path}")
    return data


def receive(connection):
    deadline = time.monotonic() + TIMEOUT
    data = bytearray()
    while not data.endswith(b"\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("process owner response timed out")
        connection.settimeout(remaining)
        chunk = connection.recv(4097 - len(data))
        if not chunk:
            raise EOFError("process owner connection closed")
        data.extend(chunk)
        if len(data) > 4096:
            raise ValueError("oversized process owner message")
    return json.loads(data)


def send(connection, value):
    connection.settimeout(TIMEOUT)
    connection.sendall(json.dumps(value).encode() + b"\n")


def retire(child):
    # No other thread or SIGCHLD handler reaps this child. An exited but
    # unreaped child still reserves its PID; a reaped child is never signaled.
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=TERMINATION_GRACE)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=1)


def remove_record(path, expected):
    try:
        actual = read_record(path)
    except FileNotFoundError:
        return
    if actual != expected:
        raise ValueError(f"process record changed; retained {path}")
    path.unlink()


def serve(state, role, startup_fd, command):
    os.umask(0o077)
    records = []
    child = None
    startup = socket.socket(fileno=startup_fd)
    endpoint = Path(tempfile.mkdtemp(prefix="rst-owner-", dir="/tmp"))
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stopping = False
    status_published = False

    def interrupted(signum, frame):
        # Do not raise between Popen creating the child and assigning its
        # handle: cleanup must always receive the child it owns.
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)

    def clear_records():
        nonlocal status_published
        if (role == "xcodebuild" and not status_published
                and child is not None and child.returncode is not None):
            # Publish only a collected child's status, before removing its owner.
            # Readers never observe a partially written result.
            pending = state / f"{role}.status.tmp"
            with pending.open("x") as stream:
                stream.write(str(child.returncode))
            pending.replace(state / f"{role}.status")
            status_published = True
        # Keep the authenticated owner record until child retirement and PID
        # marker removal both succeed, so a failed stop can be retried.
        while records:
            path, data = records[-1]
            remove_record(path, data)
            records.pop()

    def record(path, data):
        with path.open("xb") as stream:
            records.append((path, data))
            stream.write(data)

    try:
        address = endpoint / "control"
        listener.bind(str(address))
        listener.listen(4)
        listener.settimeout(0.1)
        identity = {"socket": str(address), "token": secrets.token_hex(32),
                    "state": str(state), "role": role}
        record(state / f"{role}.owner", json.dumps(identity).encode())
        if os.path.lexists(state / f"{role}.pid"):
            raise ValueError(f"existing {role} PID marker")
        with (state / f"{role}.log").open("ab", buffering=0) as log:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log)
        record(state / f"{role}.pid", f"{child.pid}\n".encode())
        send(startup, child.pid)
        if receive(startup) != "handoff":
            raise ValueError("process owner handoff refused")
        send(startup, "ready")
        startup.close()
        while not stopping:
            if child.poll() is not None:
                clear_records()
                return
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            with connection:
                try:
                    request = receive(connection)
                    if request == {**identity, "action": "alive"}:
                        if child.poll() is not None:
                            clear_records()
                            raise ValueError("owned process exited")
                        send(connection, "alive")
                        continue
                    if request != {**identity, "action": "stop"}:
                        raise ValueError("process owner identity mismatch")
                    retire(child)
                    clear_records()
                    send(connection, "stopped")
                    return
                except (OSError, ValueError, EOFError, subprocess.TimeoutExpired) as error:
                    try:
                        send(connection, {"error": str(error)})
                    except OSError:
                        pass
    finally:
        # Repeated interruption must not skip retirement. If retirement fails,
        # leave the records as evidence; a saved numeric PID is never a fallback.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            if child is not None:
                retire(child)
            clear_records()
        finally:
            startup.close()
            listener.close()
            (endpoint / "control").unlink(missing_ok=True)
            endpoint.rmdir()


def start(state, role, command):
    if not command:
        raise ValueError("missing child command")
    for suffix in ["pid", "owner"]:
        if os.path.lexists(state / f"{role}.{suffix}"):
            raise ValueError(f"existing {role} process record")
    if role == "xcodebuild":
        for suffix in ["status", "status.tmp"]:
            (state / f"{role}.{suffix}").unlink(missing_ok=True)
    parent, child = socket.socketpair()
    process = None
    handed_off = False
    try:
        with (state / f"{role}.log").open("ab") as log:
            log.truncate(0)
            process = subprocess.Popen(
                [sys.executable, "-I", __file__, "serve", str(state), role,
                 str(child.fileno()), *command],
                pass_fds=(child.fileno(),), stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=log, start_new_session=True,
            )
        child.close()
        pid = receive(parent)
        if type(pid) is not int or pid <= 1:
            raise ValueError("invalid owned child PID")
        send(parent, "handoff")
        if receive(parent) != "ready":
            raise ValueError("process owner not ready")
        handed_off = True
        print(pid)
    finally:
        parent.close()
        child.close()
        if process is not None and not handed_off:
            # EOF aborts an incomplete handoff. Wait for the owner to clean its
            # child; never kill the owner out from under an unreaped child.
            process.wait(timeout=TIMEOUT + TERMINATION_GRACE + 2)


def request_owner(state, role, action):
    owner = state / f"{role}.owner"
    pid = state / f"{role}.pid"
    try:
        identity = json.loads(read_record(owner))
    except FileNotFoundError:
        if action == "stop" and not os.path.lexists(pid):
            return
        raise ValueError(f"no process owner for {pid}; legacy PID marker retained")
    if (not isinstance(identity, dict) or identity.get("state") != str(state)
            or identity.get("role") != role
            or not isinstance(identity.get("socket"), str)
            or not isinstance(identity.get("token"), str)):
        raise ValueError(f"invalid process owner: {owner}")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(TIMEOUT)
            connection.connect(identity["socket"])
            send(connection, {**identity, "action": action})
            response = receive(connection)
            if response != ("stopped" if action == "stop" else "alive"):
                raise ValueError(f"process {action} failed: {response}")
    except (OSError, EOFError):
        # The owner may have observed natural exit and reaped its child while
        # we connected. Permission/transport failures with records left are errors.
        if action != "stop" or os.path.lexists(owner) or os.path.lexists(pid):
            raise


def build_status(state):
    """One bounded observation; the shell can handle signals between polls."""
    result = state / "xcodebuild.status"
    try:
        status = int(read_record(result))
        return status if status >= 0 else 128 - status
    except FileNotFoundError:
        pass
    try:
        request_owner(state, "xcodebuild", "alive")
    except (OSError, ValueError, EOFError):
        # Natural exit may have raced the liveness query.
        status = int(read_record(result))
        return status if status >= 0 else 128 - status
    return "running"


def main():
    if len(sys.argv) < 4 or sys.argv[2] == "" or sys.argv[3] not in ROLES:
        raise ValueError("usage: real-ssh-process.py start|stop|alive|status STATE ROLE [COMMAND...]")
    action, state, role = sys.argv[1], Path(sys.argv[2]).resolve(), sys.argv[3]
    if action == "start":
        start(state, role, sys.argv[4:])
    elif action in {"stop", "alive"} and len(sys.argv) == 4:
        request_owner(state, role, action)
    elif action == "status" and role == "xcodebuild" and len(sys.argv) == 4:
        print(build_status(state))
    elif action == "serve":
        serve(state, role, int(sys.argv[4]), sys.argv[5:])
    else:
        raise ValueError("invalid process owner command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, EOFError, subprocess.TimeoutExpired) as error:
        print(f"Fixture process failed: {error}", file=sys.stderr)
        sys.exit(1)
