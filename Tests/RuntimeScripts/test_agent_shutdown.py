"""Opt-in real launchd regression; only unique fixture jobs and homes are used.

Build swiftmux-agent/swmux/swmux-launcher, then set
SWIFTTY_AGENT_SHUTDOWN_PRODUCTS to `swift build --show-bin-path` to run.
Requires a logged-in macOS GUI domain. Never stops an installed Swiftty job.
"""

import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from agent_shutdown_fixture import AgentPaneFixture, monotonic


PRODUCTS = os.environ.get("SWIFTTY_AGENT_SHUTDOWN_PRODUCTS")


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


@unittest.skipUnless(PRODUCTS, "set SWIFTTY_AGENT_SHUTDOWN_PRODUCTS for owned launchd fixtures")
class AgentShutdownTests(unittest.TestCase):
    def command(self, arguments, env=None, allowed=(0,)):
        result = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=12)
        self.assertIn(result.returncode, allowed, result.stderr)
        return result

    def test_agent_signals_and_bootout_reap_cooperative_and_ignoring_panes(self):
        products = Path(PRODUCTS).resolve(strict=True)
        for name in ["swiftmux-agent", "swmux", "swmux-launcher"]:
            self.assertTrue(os.access(products / name, os.X_OK), name)
        for stop in ["bootout", signal.SIGTERM, signal.SIGINT]:
            for ignores_hup in [False, True]:
                with self.subTest(stop=stop, ignores_hup=ignores_hup):
                    self.check_fixture(products, stop, ignores_hup)

    def test_bootout_retires_ignoring_descendant_after_cooperative_leader_exit(self):
        self.check_fixture(Path(PRODUCTS).resolve(strict=True), "bootout", True, descendant=True)

    def test_natural_leader_exit_retires_ignoring_descendant(self):
        for observation_delay in [0, 1.5]:
            with self.subTest(observation_delay=observation_delay):
                self.check_fixture(Path(PRODUCTS).resolve(strict=True), None, True,
                                   descendant=True, natural_exit=True,
                                   observation_delay=observation_delay)

    def check_fixture(self, products, stop, ignores_hup, descendant=False, natural_exit=False,
                      observation_delay=0):
        with tempfile.TemporaryDirectory(prefix="agent-shutdown-fixture-", dir="/tmp") as directory:
            root = Path(directory).resolve()
            home = root / "home"
            home.mkdir()
            label = "com.chr33s.swiftty.review." + uuid.uuid4().hex
            domain = f"gui/{os.getuid()}"
            service = domain + "/" + label
            env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), SWMUX_SERVICE=label)
            plist = root / "fixture.plist"
            plist.write_bytes(plistlib.dumps({
                "Label": label,
                "ProgramArguments": [str(products / "swiftmux-agent"), "--mach-service", label,
                                     "--launcher", str(products / "swmux-launcher"),
                                     "--no-roaming", "--idle-exit", "never"],
                "MachServices": {label: True}, "RunAtLoad": True,
                "ProcessType": "Interactive", "EnablePressuredExit": False,
                "EnableTransactions": False,
                "EnvironmentVariables": {key: env[key] for key in
                                         ["HOME", "CFFIXED_USER_HOME", "SWMUX_SERVICE"]},
                "StandardOutPath": str(root / "agent.stdout"),
                "StandardErrorPath": str(root / "agent.stderr"),
            }))
            pane = AgentPaneFixture(root, ignores_hup, descendant, natural_exit)
            try:
                self.command(["/bin/launchctl", "bootstrap", domain, str(plist)])
                self.command([str(products / "swmux"), "status"], env)
                self.command([str(products / "swmux"), "new", "-d", "-s", "review", "-c", str(home),
                              "--", sys.executable, *pane.arguments], env)
                deadline = time.monotonic() + 4
                while not pane.pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                pid = int(pane.pidfile.read_text())
                identity = self.command(["/bin/ps", "-p", str(pid), "-o", "command="]).stdout
                self.assertIn(str(pane.script), identity)
                if observation_delay:
                    time.sleep(observation_delay)
                stopped_at = monotonic()
                if natural_exit:
                    # CLI/identity observations finish while the leader is
                    # held. Its own clock records the eventual exit event.
                    pane.release_natural_exit()
                elif stop == "bootout":
                    self.command(["/bin/launchctl", "bootout", service])
                elif stop is not None:
                    self.command(["/bin/launchctl", "kill", stop.name, service])
                deadline = time.monotonic() + 5
                while alive(pid) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(alive(pid), "pane descendant survived natural exit" if natural_exit
                                 else "pane survived agent termination")
                ended_at = monotonic()
                if natural_exit:
                    stopped_at = pane.natural_exit_time()
                elapsed = ended_at - stopped_at
                if ignores_hup:
                    self.assertGreaterEqual(elapsed, 2, "termination skipped the grace period")
                else:
                    self.assertLess(elapsed, 1, "cooperative pane retirement waited for escalation")
                if natural_exit:
                    final_status = self.command([str(products / "swmux"), "status"], env).stdout
                    self.assertIn("0 pane(s)", final_status)
            finally:
                # Bootstrap can fail after registering the label. Always try
                # removing only our UUID job, independently retire owned pane
                # connections, then verify absence. Report cleanup failures
                # separately so they cannot replace a primary assertion.
                for cleanup in [
                    lambda: self.command(["/bin/launchctl", "bootout", service],
                                         allowed=(0, 3, 113)),
                    pane.close,
                    lambda: self.command(["/bin/launchctl", "print", service], allowed=(113,)),
                ]:
                    try:
                        cleanup()
                    except Exception as error:
                        def report_cleanup(error=error):
                            raise error
                        self.addCleanup(report_cleanup)


if __name__ == "__main__":
    unittest.main()
