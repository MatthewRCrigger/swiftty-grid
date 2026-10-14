"""Shared private fake resources for the real-SSH wrapper tests."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time

from owned_tool_leases import OwnedToolLeases, TOOL_LEASE

ROOT = Path(__file__).resolve().parents[2]

TOOL = r'''#!/PYTHON
import json, os, signal, subprocess, sys, time
from pathlib import Path
directory = Path(os.environ["FIXTURE_DIRECTORY"])
state = directory / "state"
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (directory / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name, args]) + "\n")
def observe():
    pids = {p.stem: int(p.read_text()) for p in state.glob("*.pid")}
    (directory / "observed.json").write_text(json.dumps(pids))
def fail(stage, code):
    if os.environ.get("FIXTURE_FAILURE") == stage:
        observe()
        sys.exit(code)
def idle(role):
    (directory / (role + ".started")).write_text(str(os.getpid()))
    if os.environ.get("FIXTURE_FAILURE") == role + "-exit":
        observe()
        sys.exit(65)
    if role in {"bridge", "relay"} and args[-2].endswith(".ready"):
        Path(args[-2]).write_text(json.dumps({"pid": os.getpid(), "token": args[-1]}))
    def stop(signum, frame):
        time.sleep(float(os.environ.get("FIXTURE_TERM_DELAY", "0")))
        (directory / (role + ".stopped")).touch()
        sys.exit(0)
    signal.signal(signal.SIGTERM, signal.SIG_IGN
                  if role in os.environ.get("FIXTURE_IGNORE_TERM", "").split(",") else stop)
    while True: time.sleep(0.05)
if name == "container":
    if args[0] == "build": fail("container-build", 61)
    elif args[:2] == ["network", "list"]:
        fail("network", 70)
        if "--format" in args:
            networks = [] if os.environ.get("FIXTURE_FAILURE") == "empty-network" else [
                {"id": "default", "status": {"ipv4Gateway": "127.0.0.1", "ipv4Subnet": "127.0.0.0/24"}}]
            if os.environ.get("FIXTURE_FAILURE") == "wrong-gateway":
                networks[0]["status"]["ipv4Gateway"] = "192.0.2.1"
            print(json.dumps(networks))
        elif os.environ.get("FIXTURE_FAILURE") != "empty-network":
            print("default 127.0.0.0/24")
    elif args[0] == "run":
        (directory / "container.created").touch()
        fail("container-run", 71)
    elif args[0] == "rm":
        fail("container-remove", 74)
        (directory / "container.removed").touch()
    elif args[0] == "inspect":
        print(json.dumps([{"status": {"networks": [{"ipv4Address": "127.0.0.2/24"}]}}]))
    elif args[0] == "exec" and "cut" in args:
        fail("hostkey", 72)
        print("ssh-ed25519 AAAAFakeHostKey")
elif name == "mise":
    if "test" in args:
        if "--event-stream-output-path" in args and os.environ.get("FIXTURE_EVENTS"):
            Path(args[args.index("--event-stream-output-path") + 1]).write_bytes(
                Path(os.environ["FIXTURE_EVENTS"]).read_bytes())
        sys.exit(int(os.environ.get("FIXTURE_TEST_CODE", "0")))
    fail("swift-build", 62)
    if "--show-bin-path" in args: print(directory / "bin")
elif name == "swiftmux-agent": idle("host")
elif name == "swifttyd":
    (directory / "status-config").write_text(os.environ["SWIFTMUX_ROAMING_CONFIG"])
    fail("host-status", 76)
elif name == "openssl":
    if args[-1] == "12": fail("password", 69)
    print("00" * int(args[-1]))
elif name == "uuidgen": print("01234567-89AB-CDEF-0123-456789ABCDEF")
elif name == "xcrun":
    fail("pubkey-build", 63)
    target = Path(args[args.index("-o") + 1])
    target.write_text("#!" + sys.executable + "\nprint('ssh-ed25519 AAAAFakePublicKey')\n")
    target.chmod(0o755)
elif name == "ssh-keygen":
    fail("fingerprint", 73)
    print("256 SHA256:fake rst (ED25519)")
elif name == "nc":
    observe()
    if os.environ.get("FIXTURE_FAILURE") == "relay": sys.exit(1)
elif name == "python3":
    if len(args) > 2 and Path(args[1]).name == "real-ssh-proxy.py": idle(args[2])
    if args[:2] == ["-I", "-"]:
        program = sys.stdin.buffer.read()
        if b"listener.listen(8)" in program: idle("bridge")
        if b"listener.listen(16)" in program: idle("relay")
        sys.exit(subprocess.run([sys.executable, *args], input=program).returncode)
    os.execv(sys.executable, [sys.executable, *args])
'''



class RealSSHFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="real-ssh-script-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.leases = OwnedToolLeases(self.directory)
        # Independent fallback also protects deliberately failing baseline probes.
        self.addCleanup(self.leases.close)
        self.root = self.directory / "repo with 'quotes'"
        scripts = self.root / "Scripts"
        scripts.mkdir(parents=True)
        self.script = scripts / "real-ssh-env.sh"
        shutil.copyfile(ROOT / "Scripts/real-ssh-env.sh", self.script)
        shutil.copyfile(ROOT / "Scripts/real-ssh-readiness.py", scripts / "real-ssh-readiness.py")
        shutil.copyfile(ROOT / "Scripts/real-ssh-proxy.py", scripts / "real-ssh-proxy.py")
        shutil.copyfile(ROOT / "Scripts/real-ssh-config.py", scripts / "real-ssh-config.py")
        self.state = self.directory / "state"
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        body = TOOL.replace("def idle(role):\n",
                            "def idle(role):\n    name = role\n" +
                            textwrap.indent(TOOL_LEASE, "    "), 1)
        for name in ["container", "mise", "swiftmux-agent", "swmux-launcher", "swifttyd",
                     "openssl", "uuidgen", "xcrun", "ssh-keygen", "nc", "python3"]:
            file = self.bin / name
            file.write_text(body.replace("#!/PYTHON", "#!" + sys.executable, 1))
            file.chmod(0o755)
        sleep = self.bin / "sleep"
        sleep.write_text("#!/bin/sh\nexit 0\n")
        sleep.chmod(0o755)
        self.environment = {**os.environ, "FIXTURE_DIRECTORY": str(self.directory),
                            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}
        self.environment.pop("RST_PUBLIC_HOST", None)
        self.environment.pop("RST_QUIC_PORT", None)
        self.environment.pop("RST_SSH_PORT", None)
        for name in list(self.environment):
            if name.startswith("FIXTURE_") and name != "FIXTURE_DIRECTORY":
                self.environment.pop(name)
        self.environment.update(self.leases.environment)
        self.addCleanup(self.cleanup_children)

    def cleanup_children(self):
        # These connections belong to the fake host/proxies. Numeric marker
        # files and command strings cannot authorize a termination request.
        self.leases.stop_pending()

    def invoke(self, action="start", extra=(), timeout=15, **settings):
        return subprocess.run(
            ["/bin/sh", str(self.script), action, str(self.state), *extra],
            env={**self.environment, **settings}, capture_output=True,
            text=True, timeout=timeout,
        )

    def calls(self):
        path = self.directory / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_dead(self, pids):
        deadline = time.monotonic() + 3
        for pid in pids:
            while True:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                self.assertLess(time.monotonic(), deadline, f"test child {pid} survived cleanup")
                time.sleep(0.01)

