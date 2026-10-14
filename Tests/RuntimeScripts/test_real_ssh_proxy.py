"""Exercise proxy byte delivery, half-close bounds, process ownership, and admission."""

from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/real-ssh-proxy.py"
SPEC = importlib.util.spec_from_file_location("real_ssh_proxy", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
# dataclasses consults its module when processing annotations.
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ssh-proxy-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()

    @contextmanager
    def pump(self, drain_timeout=1):
        client, client_proxy = socket.socketpair()
        upstream, upstream_proxy = socket.socketpair()
        for connection in [client, upstream]:
            connection.settimeout(3)
        stopping = threading.Event()
        errors = []
        def run():
            try:
                MODULE.forward(client_proxy, upstream_proxy.fileno(), upstream_proxy.fileno(),
                               lambda: MODULE.shutdown_write(upstream_proxy),
                               stopping, drain_timeout)
            except BaseException as error:
                errors.append(error)
            finally:
                client_proxy.close()
                upstream_proxy.close()
        worker = threading.Thread(target=run)
        worker.start()
        try:
            yield client, upstream, stopping, worker, errors
        finally:
            stopping.set()
            worker.join(3)
            client.close()
            upstream.close()
            self.assertFalse(worker.is_alive(), "proxy pump did not stop")

    @staticmethod
    def read_all(connection):
        result = bytearray()
        while data := connection.recv(65536):
            result.extend(data)
        return bytes(result)

    def test_half_closed_request_preserves_full_response_and_partial_writes(self):
        request = bytes(range(256)) * 256
        response = request[::-1]
        original_write = os.write
        # Real socket writes forced to short counts, rather than fake successful writes.
        with mock.patch.object(MODULE.os, "write", side_effect=lambda fd, data: original_write(fd, data[:17])):
            with self.pump() as (client, upstream, stopping, worker, errors):
                peer_errors = []
                def peer():
                    try:
                        self.assertEqual(self.read_all(upstream), request)
                        upstream.sendall(response)
                        upstream.shutdown(socket.SHUT_WR)
                    except BaseException as error:
                        peer_errors.append(error)
                peer_worker = threading.Thread(target=peer)
                peer_worker.start()
                try:
                    client.sendall(request)
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(self.read_all(client), response)
                finally:
                    peer_worker.join(3)
                self.assertFalse(peer_worker.is_alive())
                self.assertEqual(peer_errors, [])
                worker.join(3)
                self.assertEqual(errors, [])

    def test_peer_that_ignores_half_close_hits_fixed_drain_deadline(self):
        with self.pump(drain_timeout=0.15) as (client, upstream, stopping, worker, errors):
            client.shutdown(socket.SHUT_WR)
            self.assertEqual(upstream.recv(1), b"")
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(len(errors), 1)
            self.assertIsInstance(errors[0], TimeoutError)

    def test_cancellation_unblocks_idle_or_backpressured_connection(self):
        with self.pump() as (client, upstream, stopping, worker, errors):
            client.sendall(b"start")
            self.assertEqual(upstream.recv(5), b"start")
            stopping.set()
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
        with self.pump() as (client, upstream, stopping, worker, errors):
            client.setblocking(False)
            sent = 0
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    sent += client.send(b"x" * 65536)
                except BlockingIOError:
                    time.sleep(0.001)
                    if sent > 65536:
                        break
            self.assertGreater(sent, 65536)
            stopping.set()
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])

    def container_tool(self, behavior):
        path = self.root / "container"
        path.write_text("#!" + sys.executable + "\n"
                        "import os,signal,sys,time\nfrom pathlib import Path\n"
                        f"root=Path({str(self.root)!r})\n"
                        "(root/(str(os.getpid())+'.pid')).write_text(str(os.getpid()))\n" + behavior)
        path.chmod(0o755)
        return {**os.environ, "PATH": str(self.root) + os.pathsep + os.environ["PATH"]}

    def test_real_relay_pipe_roundtrip_reaps_subprocess(self):
        environment = self.container_tool("while data := os.read(0,4096):\n"
                                          " offset=0\n"
                                          " while offset<len(data): offset+=os.write(1,data[offset:])\n")
        client, server = socket.socketpair()
        client.settimeout(5)
        errors = []
        stopping = threading.Event()
        def relay():
            try:
                MODULE.serve(server, "relay", "fake-container", stopping)
            except BaseException as error:
                errors.append(error)
        with mock.patch.dict(os.environ, environment):
            worker = threading.Thread(target=relay)
            worker.start()
            payload = bytes(range(256)) * 4096
            send_errors = []
            def send():
                try:
                    client.sendall(payload)
                    client.shutdown(socket.SHUT_WR)
                except BaseException as error:
                    send_errors.append(error)
            sender = threading.Thread(target=send)
            sender.start()
            try:
                self.assertEqual(self.read_all(client), payload)
            finally:
                stopping.set()
                client.close()
                sender.join(3)
                worker.join(3)
            self.assertFalse(worker.is_alive())
            self.assertFalse(sender.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(send_errors, [])
        records = list(self.root.glob("*.pid"))
        self.assertEqual(len(records), 1)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(records[0].read_text()), 0)

    def test_stop_escalates_and_reaps_term_ignoring_owned_child(self):
        environment = self.container_tool("signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                                          "(root/'ignoring').touch()\n"
                                          "while True: time.sleep(0.05)\n")
        with subprocess.Popen([str(self.root / "container")], env=environment) as child:
            deadline = time.monotonic() + 3
            while not (self.root / "ignoring").exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            MODULE.stop_child(child, grace=0.1)
            self.assertEqual(child.returncode, -signal.SIGKILL)

    def test_server_limits_connections_and_sigterm_reaps_all_children(self):
        environment = self.container_tool("signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                                          "while True: time.sleep(0.05)\n")
        ready = self.root / "ready"
        clients = []
        with subprocess.Popen([sys.executable, str(SCRIPT), "relay", "127.0.0.1", "0",
                               "fake-container", str(ready), "token"], env=environment,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as driver:
            try:
                deadline = time.monotonic() + 8
                while not ready.exists():
                    self.assertIsNone(driver.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                port = json.loads(ready.read_text())["port"]
                for _ in range(MODULE.CONNECTION_LIMIT):
                    clients.append(socket.create_connection(("127.0.0.1", port), timeout=3))
                while len(list(self.root.glob("*.pid"))) < MODULE.CONNECTION_LIMIT:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                with socket.create_connection(("127.0.0.1", port), timeout=3) as excess:
                    self.assertEqual(excess.recv(1), b"")
                self.assertEqual(len(list(self.root.glob("*.pid"))), MODULE.CONNECTION_LIMIT)
                driver.terminate()
                self.assertEqual(driver.wait(timeout=5), 0)
                for record in self.root.glob("*.pid"):
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int(record.read_text()), 0)
            finally:
                for connection in clients:
                    connection.close()
                if driver.poll() is None:
                    driver.terminate()
                    try:
                        driver.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        driver.kill()
                        driver.wait(timeout=3)
                driver.stderr.close()

    def test_child_cleanup_failure_is_reported_and_both_pipes_close(self):
        client, server = socket.socketpair()
        process = mock.Mock()
        with client, mock.patch.object(MODULE.subprocess, "Popen", return_value=process), \
                mock.patch.object(MODULE, "forward"), \
                mock.patch.object(MODULE, "stop_child", side_effect=subprocess.TimeoutExpired("child", 1)):
            with self.assertRaises(MODULE.CleanupError):
                MODULE.serve(server, "relay", "fake-container", threading.Event())
            process.stdin.close.assert_called_once()
            process.stdout.close.assert_called_once()

    def test_bridge_connect_failure_closes_client(self):
        client, server = socket.socketpair()
        client.settimeout(1)
        with client:
            with self.assertRaises(OSError):
                MODULE.serve(server, "bridge", str(self.root / "missing.sock"), threading.Event())
            self.assertEqual(client.recv(1), b"")


if __name__ == "__main__":
    unittest.main()
