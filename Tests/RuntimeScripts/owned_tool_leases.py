"""Private lifetime connections for fake tools launched by a test driver."""

import json
import secrets
import select
import socket
import threading
import time


# This runs only in the fake executable, before its command body. The socket
# stays open until process exit; the controller never signals a recorded PID.
TOOL_LEASE = r'''
import socket, threading
lease = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
lease.connect(os.environ["FIXTURE_LEASE_SOCKET"])
lease.sendall((json.dumps({"token": os.environ["FIXTURE_LEASE_TOKEN"],
                          "pid": os.getpid(), "tool": name}) + "\n").encode())
if lease.recv(1) != b"+":
    raise RuntimeError("fake tool lifetime connection refused")
def watch_owner():
    try:
        lease.recv(1)
    finally:
        # Give a fake tool's normal TERM handler a chance to finish, then
        # ensure an ignored signal cannot strand this test-owned executable.
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(0.2)
        os._exit(0)
threading.Thread(target=watch_owner, daemon=True).start()
'''


class OwnedToolLeases:
    def __init__(self, directory):
        self.path = directory / "lease.sock"
        self.token = secrets.token_hex(16)
        self.lock = threading.Lock()
        self.connections = []
        self.last_retired = []
        self.retiring = False
        self.errors = []
        self.stopping = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.listener.bind(str(self.path))
            self.listener.listen()
            self.listener.settimeout(0.05)
            self.thread = threading.Thread(target=self.accept_tools, daemon=True)
            self.thread.start()
        except BaseException:
            self.listener.close()
            self.path.unlink(missing_ok=True)
            raise

    @property
    def environment(self):
        return {"FIXTURE_LEASE_SOCKET": str(self.path),
                "FIXTURE_LEASE_TOKEN": self.token}

    def begin_run(self):
        with self.lock:
            if self.connections:
                raise RuntimeError("previous fake tools were not collected")
            self.retiring = False
            self.last_retired = []
            self.token = secrets.token_hex(16)
        return self.environment

    def accept_tools(self):
        while not self.stopping.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if not self.stopping.is_set():
                    with self.lock:
                        self.errors.append("fake tool listener failed")
                return
            try:
                connection.settimeout(2)
                data = bytearray()
                while not data.endswith(b"\n") and len(data) <= 1024:
                    chunk = connection.recv(1)
                    if not chunk:
                        raise RuntimeError("incomplete fake tool registration")
                    data.extend(chunk)
                identity = json.loads(data)
                connection.settimeout(None)
                # Register before releasing the tool to run its command body.
                with self.lock:
                    if self.retiring or identity["token"] != self.token:
                        connection.close()
                        continue
                    self.connections.append((connection, identity))
                    connection.sendall(b"+")
            except Exception as error:
                connection.close()
                with self.lock:
                    self.connections = [item for item in self.connections
                                        if item[0] is not connection]
                    self.errors.append(str(error))

    def wait_stopped(self, timeout=5):
        with self.lock:
            pending = [connection for connection, _ in self.connections]
        deadline = time.monotonic() + timeout
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("test-owned fake tools did not exit")
            readable, _, _ = select.select(pending, [], [], remaining)
            for connection in readable:
                if connection.recv(1) != b"":
                    raise RuntimeError("unexpected fake tool lifetime data")
                pending.remove(connection)

    def stop_pending(self):
        with self.lock:
            # A tool still starting after driver death must not enter its
            # command body. The next run also gets a fresh token.
            self.retiring = True
            connections = list(self.connections)
        for connection, _ in connections:
            try:
                connection.sendall(b"!")
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.wait_stopped()
        for connection, _ in connections:
            connection.close()
        with self.lock:
            if connections:
                self.last_retired = [identity for _, identity in connections]
            self.connections = [item for item in self.connections
                                if item not in connections]
            if self.errors:
                errors, self.errors = self.errors, []
                raise RuntimeError("; ".join(errors))

    def close(self):
        try:
            self.stop_pending()
        finally:
            self.stopping.set()
            self.listener.close()
            self.thread.join(timeout=3)
            self.path.unlink(missing_ok=True)
            if self.thread.is_alive():
                raise RuntimeError("fake tool listener did not finish")
