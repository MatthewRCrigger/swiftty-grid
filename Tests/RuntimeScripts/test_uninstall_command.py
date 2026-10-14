"""Owned command processes and deterministic interruption gates around cleanup."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
DRIVER = r'''
import importlib.util, json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(sys.argv[1])
source, phase, mode = sys.argv[2:5]
spec = importlib.util.spec_from_file_location('uninstall_command', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.TIMEOUT = 0.3 if mode == 'timeout' else 5
original_popen = subprocess.Popen
original_killpg = os.killpg
original_write = os.write
original_signal = signal.signal
owned = []
killed = False
gated = False
def marker(name, value):
    temporary = root/(name+'.tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(root/name)
def gate():
    global gated
    if gated: return
    gated = True
    marker('gate', {'pid': owned[0][0].pid, 'runner': os.getpid()})
    deadline = time.monotonic()+5
    while not (root/'release').exists() and time.monotonic()<deadline:
        time.sleep(0.005)
    if not (root/'release').exists(): raise RuntimeError('fixture gate expired')
def launch(*args, **kwargs):
    process = original_popen(*args, **kwargs)
    wait = process.wait
    owned.append((process, wait))
    def collect(timeout=None):
        if not killed and mode == 'closed-output': marker('waiting', {'joined': False})
        if killed and phase == 'reap': gate()
        result = wait(timeout=timeout)
        if killed: (root/'reaped').touch()
        return result
    process.wait = collect
    if phase == 'spawn': gate()
    return process
def kill_group(pid, signum):
    global killed
    assert owned and pid == owned[0][0].pid and owned[0][0].returncode is None
    if phase == 'kill': gate()
    (root/'killed').touch()
    killed = True
    original_killpg(pid, signum)
module.subprocess.Popen = launch
module.os.killpg = kill_group
def publishing():
    assert owned[0][0].returncode is not None
    marker('publishing', {'joined': True})
if phase in {'publish', 'publish-restore'}:
    if hasattr(module, 'publish_output'):
        def output(fd, data):
            publishing()
            return original_write(fd, data)
        module.os.write = output
    else:
        stdout = sys.stdout
        class Buffer:
            def write(self, data):
                publishing()
                return stdout.buffer.write(data)
        class Output:
            buffer = Buffer()
            def __getattr__(self, name): return getattr(stdout, name)
        module.sys.stdout = Output()
restored = 0
if phase == 'publish-restore':
    def change_handler(signum, handler):
        global restored
        restoring = owned and owned[0][0].returncode is not None and handler is module.interrupt
        if restoring: gate()
        previous = original_signal(signum, handler)
        if restoring:
            restored += 1
            marker('restored', {'count': restored})
        return previous
    module.signal.signal = change_handler
if phase == 'short-write':
    module.os.write = lambda fd, data: original_write(fd, data[:37])
sys.argv = ['uninstall-command.py', sys.executable, str(root/'worker.py'), mode, str(root)]
try:
    status = module.main()
finally:
    # Even the original broken implementation leaves no live fixture child:
    # the driver owns the Popen handle and uses unpatched kill/wait methods.
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, signal.SIG_IGN)
    for process, wait in owned:
        if process.returncode is None:
            (root/'fallback').touch()
            try: original_killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError): pass
            wait(timeout=3)
sys.exit(status)
'''
WORKER = r'''
import json, os, signal, sys, time
from pathlib import Path
mode, root = sys.argv[1], Path(sys.argv[2])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
temporary = root/'ready.tmp'
temporary.write_text(json.dumps({'pid':os.getpid()}))
temporary.replace(root/'ready')
if mode in {'output', 'exit-three', 'overflow'}:
    data = bytes(range(256))*256
    sys.stdout.buffer.write(data + (b'!' if mode == 'overflow' else b''))
    sys.stdout.buffer.flush()
    sys.exit(3 if mode == 'exit-three' else 0)
if mode == 'closed-output': os.close(1)
time.sleep(20)
'''


class UninstallCommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="uninstall-command-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.driver = self.root / "driver.py"
        self.driver.write_text(DRIVER)
        (self.root / "worker.py").write_text(WORKER)

    def start(self, phase, mode, stdout=subprocess.PIPE):
        process = subprocess.Popen(
            [sys.executable, str(self.driver), str(self.root),
             str(ROOT / "Scripts/uninstall-command.py"), phase, mode],
            stdout=stdout, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.finish, process)
        return process

    def finish(self, process):
        (self.root / "release").touch()
        if process.poll() is None:
            process.terminate()
        try:
            process.communicate(timeout=7)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=3)

    def wait_marker(self, name, process):
        deadline = time.monotonic() + 4
        path = self.root / name
        while not path.exists() and time.monotonic() < deadline:
            if process.poll() is not None:
                break
            time.sleep(0.005)
        self.assertTrue(path.exists(), name)
        return json.loads(path.read_text())

    def assert_settled(self):
        self.assertTrue((self.root / "killed").exists())
        self.assertTrue((self.root / "reaped").exists())
        self.assertFalse((self.root / "fallback").exists())
        pid = json.loads((self.root / "ready").read_text())["pid"]
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def cleanup_case(self, phase, initial_signal=True):
        process = self.start(phase, "stall" if initial_signal else "timeout")
        self.wait_marker("ready", process)
        if initial_signal:
            process.send_signal(signal.SIGTERM)
        self.wait_marker("gate", process)
        process.send_signal(signal.SIGHUP)
        time.sleep(0.02)
        process.send_signal(signal.SIGINT)
        (self.root / "release").touch()
        output, error = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM if initial_signal else 124, error)
        self.assertEqual(output, b"")
        self.assert_settled()

    def test_repeated_signals_before_group_kill_preserve_the_first_interruption(self):
        self.cleanup_case("kill")

    def test_repeated_signals_during_collection_do_not_abandon_the_owned_child(self):
        self.cleanup_case("reap")

    def test_first_signal_during_timeout_cleanup_does_not_replace_failure_or_skip_cleanup(self):
        self.cleanup_case("kill", initial_signal=False)

    def test_interruption_during_command_acquisition_does_not_lose_the_child(self):
        process = self.start("spawn", "stall")
        self.wait_marker("gate", process)
        self.wait_marker("ready", process)
        process.send_signal(signal.SIGTERM)
        time.sleep(0.02)
        (self.root / "release").touch()
        output, error = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM, error)
        self.assertEqual(output, b"")
        self.assert_settled()

    def test_stdout_eof_does_not_make_exit_wait_ignore_cancellation(self):
        process = self.start("reap", "closed-output")
        self.assertFalse(self.wait_marker("waiting", process)["joined"])
        process.send_signal(signal.SIGTERM)
        self.wait_marker("gate", process)
        (self.root / "release").touch()
        output, error = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM, error)
        self.assertEqual(output, b"")
        self.assert_settled()

    def test_output_publication_remains_interruptible_after_the_child_is_joined(self):
        self.publication_case(restoring=False)

    def test_repeated_signals_cannot_abandon_publication_handler_restoration(self):
        self.publication_case(restoring=True)

    def publication_case(self, restoring):
        read_fd, write_fd = os.pipe()
        try:
            os.set_blocking(write_fd, False)
            while True:
                try:
                    os.write(write_fd, b"p" * 4096)
                except BlockingIOError:
                    break
            os.set_blocking(write_fd, True)
            process = self.start("publish-restore" if restoring else "publish", "output", stdout=write_fd)
        finally:
            os.close(write_fd)
        try:
            self.assertTrue(self.wait_marker("publishing", process)["joined"])
            # A full owned pipe forces backpressure independent of its capacity.
            process.send_signal(signal.SIGTERM)
            if restoring:
                self.wait_marker("gate", process)
                process.send_signal(signal.SIGHUP)
                time.sleep(0.02)
                (self.root / "release").touch()
            self.assertEqual(process.wait(timeout=2), 128 + signal.SIGTERM)
            _, error = process.communicate(timeout=2)
            self.assertIn(b"interrupted", error)
            self.assertFalse((self.root / "fallback").exists())
            if restoring:
                self.assertEqual(json.loads((self.root / "restored").read_text())["count"], 3)
        finally:
            os.close(read_fd)

    def test_exact_output_limit_binary_bytes_and_nonzero_exit_are_preserved(self):
        for mode, status in [("output", 0), ("exit-three", 3)]:
            with self.subTest(mode=mode):
                process = self.start("short-write", mode)
                output, error = process.communicate(timeout=4)
                self.assertEqual(process.returncode, status, error)
                self.assertEqual(output, bytes(range(256)) * 256)

    def test_one_excess_output_byte_is_rejected_before_publication_and_child_is_collected(self):
        process = self.start("kill", "overflow")
        self.wait_marker("gate", process)
        (self.root / "release").touch()
        output, error = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 125, error)
        self.assertEqual(output, b"")
        self.assertIn(b"output exceeds limit", error)
        self.assert_settled()


if __name__ == "__main__":
    unittest.main()
