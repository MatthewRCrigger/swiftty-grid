"""Owned pane processes and an explicit natural-exit gate for launchd tests."""

import time

from owned_tool_leases import OwnedToolLeases, TOOL_LEASE


def monotonic():
    # Python 3.9's macOS time.monotonic() has a per-process origin. This
    # kernel clock has one epoch for the pane's event and its observer.
    return time.clock_gettime(time.CLOCK_MONOTONIC)


class AgentPaneFixture:
    def __init__(self, directory, ignores_hup, descendant=False, natural_exit=False):
        if natural_exit and not descendant:
            raise ValueError("natural-exit fixture requires a descendant")
        self.script = directory / "pane.py"
        self.pidfile = directory / "pane.pid"
        self.release = directory / "leader.release"
        self.exited_at = directory / "leader.exited-at"
        self.leases = OwnedToolLeases(directory)
        try:
            self.script.write_text(self.source(ignores_hup, descendant, natural_exit))
        except BaseException:
            self.leases.close()
            raise

    def source(self, ignores_hup, descendant, natural_exit):
        return f'''import json, os, signal, subprocess, sys, time
from pathlib import Path
os.environ["FIXTURE_LEASE_SOCKET"] = sys.argv[1]
os.environ["FIXTURE_LEASE_TOKEN"] = sys.argv[2]
pidfile = Path(sys.argv[3])
name = "descendant" if len(sys.argv) == 5 else "leader"
descendant = {descendant!r}
natural_exit = {natural_exit!r}
if name == "descendant" or ({ignores_hup!r} and not descendant):
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
''' + TOOL_LEASE + '''
def record(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(str(value))
    temporary.replace(path)
if descendant and name == "leader":
    subprocess.Popen([sys.executable, __file__, *sys.argv[1:], "descendant"])
    if natural_exit:
        while not (pidfile.parent / "leader.release").exists():
            time.sleep(0.01)
        record(pidfile.parent / "leader.exited-at", time.clock_gettime(time.CLOCK_MONOTONIC))
        sys.exit(7)
else:
    record(pidfile, os.getpid())
    print("READY", flush=True)
while True:
    time.sleep(30)
'''

    @property
    def arguments(self):
        return [str(self.script), str(self.leases.path), self.leases.token, str(self.pidfile)]

    def release_natural_exit(self):
        self.release.touch()

    def natural_exit_time(self):
        return float(self.exited_at.read_text())

    def close(self):
        self.leases.close()
