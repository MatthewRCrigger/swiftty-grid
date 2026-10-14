#!/usr/bin/env python3
"""Bounded TCP proxies for the real SSH fixture's control bridge and SSH relay."""

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Callable


BUFFER_LIMIT = 65536
CONNECTION_LIMIT = 16


class CleanupError(Exception):
    pass


@dataclass
class Flow:
    reader: int
    writer: int
    finish: Callable[[], None]
    buffer: bytearray = field(default_factory=bytearray)
    eof: bool = False
    closed: bool = False


def shutdown_write(connection):
    try:
        connection.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def forward(client, reader, writer, finish_upstream, stopping, drain_timeout=10):
    flows = [Flow(client.fileno(), writer, finish_upstream),
             Flow(reader, client.fileno(), lambda: shutdown_write(client))]
    for descriptor in {client.fileno(), reader, writer}:
        os.set_blocking(descriptor, False)
    drain_deadline = None
    with selectors.DefaultSelector() as selector:
        while not stopping.is_set():
            for flow in flows:
                if flow.eof and not flow.buffer and not flow.closed:
                    flow.finish()
                    flow.closed = True
            if all(flow.closed for flow in flows):
                return
            if drain_deadline is not None and time.monotonic() >= drain_deadline:
                raise TimeoutError("proxy half-close drain timed out")
            desired = {}
            for flow in flows:
                if not flow.eof and len(flow.buffer) < BUFFER_LIMIT:
                    desired[flow.reader] = desired.get(flow.reader, 0) | selectors.EVENT_READ
                if flow.buffer:
                    desired[flow.writer] = desired.get(flow.writer, 0) | selectors.EVENT_WRITE
            for descriptor in list(selector.get_map()):
                if descriptor not in desired:
                    selector.unregister(descriptor)
            for descriptor, events in desired.items():
                if descriptor in selector.get_map():
                    selector.modify(descriptor, events)
                else:
                    selector.register(descriptor, events)
            wait = 0.1
            if drain_deadline is not None:
                wait = min(wait, max(0, drain_deadline - time.monotonic()))
            for key, events in selector.select(wait):
                for flow in flows:
                    if (key.fd == flow.reader and events & selectors.EVENT_READ
                            and not flow.eof and len(flow.buffer) < BUFFER_LIMIT):
                        try:
                            data = os.read(flow.reader, BUFFER_LIMIT - len(flow.buffer))
                        except BlockingIOError:
                            continue
                        if data:
                            flow.buffer.extend(data)
                        else:
                            flow.eof = True
                            if drain_deadline is None:
                                drain_deadline = time.monotonic() + drain_timeout
                    if key.fd == flow.writer and events & selectors.EVENT_WRITE and flow.buffer:
                        try:
                            count = os.write(flow.writer, flow.buffer)
                        except BlockingIOError:
                            continue
                        if count <= 0:
                            raise OSError("proxy write made no progress")
                        del flow.buffer[:count]


def stop_child(process, grace=1):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=grace)


def serve(client, mode, target, stopping, drain_timeout=10):
    with client:
        if stopping.is_set():
            return
        if mode == "bridge":
            with socket.socket(socket.AF_UNIX) as upstream:
                upstream.settimeout(1)
                upstream.connect(target)
                forward(client, upstream.fileno(), upstream.fileno(),
                        lambda: shutdown_write(upstream), stopping, drain_timeout)
        else:
            process = subprocess.Popen(
                ["container", "exec", "-i", target, "socat", "STDIO", "TCP:127.0.0.1:22"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0,
            )
            try:
                forward(client, process.stdout.fileno(), process.stdin.fileno(),
                        process.stdin.close, stopping, drain_timeout)
            finally:
                try:
                    stop_child(process)
                except (OSError, subprocess.SubprocessError) as error:
                    raise CleanupError(f"cannot stop relay child: {error}") from error
                finally:
                    process.stdin.close()
                    process.stdout.close()


def acknowledge(path, token, listener):
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent,
                                         prefix=".readiness-", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            json.dump({"pid": os.getpid(), "token": token,
                       "port": listener.getsockname()[1]}, temporary)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def run(mode, host, port, target, ready, token, stopping):
    workers = set()
    cleanup_failure = []
    lock = threading.Lock()

    def worker(client):
        try:
            serve(client, mode, target, stopping)
        except CleanupError as error:
            with lock:
                if not cleanup_failure:
                    cleanup_failure.append(str(error))
            stopping.set()
        except (OSError, subprocess.SubprocessError) as error:
            print(f"proxy connection failed: {error}", file=sys.stderr)
        finally:
            with lock:
                workers.remove(threading.current_thread())

    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, port))
        listener.listen(CONNECTION_LIMIT)
        listener.settimeout(0.1)
        acknowledge(ready, token, listener)
        try:
            while not stopping.is_set():
                try:
                    client, address = listener.accept()
                except socket.timeout:
                    continue
                with lock:
                    if len(workers) >= CONNECTION_LIMIT:
                        client.close()
                        continue
                    thread = threading.Thread(target=worker, args=(client,), daemon=True)
                    workers.add(thread)
                    try:
                        thread.start()
                    except BaseException:
                        workers.remove(thread)
                        client.close()
                        raise
        finally:
            # Keep cleanup intact if another interrupt arrives.
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            stopping.set()
            with lock:
                active = list(workers)
            deadline = time.monotonic() + 5
            for thread in active:
                thread.join(max(0, deadline - time.monotonic()))
            if any(thread.is_alive() for thread in active):
                raise RuntimeError("proxy cleanup did not finish within five seconds")
            if cleanup_failure:
                raise RuntimeError(cleanup_failure[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["bridge", "relay"])
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("target")
    parser.add_argument("ready", type=Path)
    parser.add_argument("token")
    args = parser.parse_args()
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda signum, frame: stopping.set())
    signal.signal(signal.SIGINT, lambda signum, frame: stopping.set())
    try:
        run(args.mode, args.host, args.port, args.target, args.ready, args.token, stopping)
    except (OSError, RuntimeError) as error:
        print(f"proxy failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
