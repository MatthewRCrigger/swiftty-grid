"""Failure-path tests for real-ssh-env.sh with owned, isolated fake resources."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest

from real_ssh_test_fixture import ROOT, RealSSHFixture


class RealSSHSetupTests(RealSSHFixture, unittest.TestCase):
    def test_configuration_selects_all_host_products_and_their_binary_directory(self):
        for selected in [None, "debug", "release"]:
            with self.subTest(configuration=selected):
                previous = len(self.calls())
                settings = {} if selected is None else {"RST_REAL_SSH_CONFIGURATION": selected}
                result = self.invoke(**settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                try:
                    configuration = selected or "debug"
                    builds = [args for name, args in self.calls()[previous:] if name == "mise"]
                    expected = [["exec", "--", "swift", "build", "-c", configuration,
                                 "--product", product]
                                for product in ["swiftmux-agent", "swmux-launcher", "swifttyd"]]
                    expected.append(["exec", "--", "swift", "build", "-c", configuration,
                                     "--show-bin-path"])
                    self.assertEqual(builds, expected)
                    self.assertIn(f"export RST_REAL_SSH_CONFIGURATION={configuration}\n",
                                  (self.state / "env").read_text())
                finally:
                    stopped = self.invoke("stop")
                    self.assertEqual(stopped.returncode, 0, stopped.stderr)

    def test_invalid_configuration_is_rejected_before_resource_commands(self):
        for value in ["", "Release", "../release", "--help"]:
            with self.subTest(configuration=value):
                previous = len(self.calls())
                result = self.invoke(RST_REAL_SSH_CONFIGURATION=value)
                try:
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(self.calls()[previous:], [])
                    self.assertFalse(self.state.exists())
                finally:
                    if self.state.exists():
                        self.invoke("stop")

    def test_concurrent_start_and_stop_cannot_take_over_pending_startup(self):
        gate = self.directory / "build-release"
        process = subprocess.Popen(
            ["/bin/sh", str(self.script), "start", str(self.state)],
            env={**self.environment, "FIXTURE_BUILD_GATE": str(gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            deadline = time.monotonic() + 5
            while not gate.with_suffix(".waiting").exists():
                self.assertIsNone(process.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            for action in ["start", "stop"]:
                result = self.invoke(action)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("startup", result.stderr)
            self.assertFalse(any(name == "swiftmux-agent" for name, _ in self.calls()))
        finally:
            gate.touch()
            output, error = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(output.strip(), str(self.state / "env"))
        self.assertFalse((self.state / "start.lock").exists())
        self.assertEqual(self.invoke("stop").returncode, 0)

    def test_legacy_pid_marker_cannot_authorize_signaling_an_unrelated_process(self):
        self.state.mkdir()
        child = subprocess.Popen(["/bin/sleep", "30"])
        try:
            for role in ["host", "advertiser", "xcodebuild"]:
                with self.subTest(role=role):
                    marker = self.state / (role + ".pid")
                    marker.write_text(str(child.pid))
                    result = self.invoke("stop")
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIsNone(child.poll())
                    self.assertEqual(marker.read_text(), str(child.pid))
                    marker.unlink()
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)

    def test_stop_waits_for_delayed_or_ignored_termination_before_removing_markers(self):
        for settings in [{"FIXTURE_TERM_DELAY": "0.3"},
                         {"FIXTURE_IGNORE_TERM": "host,bridge,relay"}]:
            with self.subTest(settings=settings):
                started = self.invoke(**settings)
                self.assertEqual(started.returncode, 0, started.stderr)
                pids = [int(p.read_text()) for p in self.state.glob("*.pid")]
                result = self.invoke("stop", timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                # Success means retirement already completed, not eventual exit.
                for pid in pids:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                self.assertFalse(list(self.state.glob("*.pid")))

    def test_success_hands_off_private_environment_and_stop_cleans_resources(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = Path(result.stdout.strip())
        self.assertEqual(environment, self.state / "env")
        self.assertEqual(environment.stat().st_mode & 0o777, 0o600)
        self.assertIn("export RST_REAL_SSH_USER=rst", environment.read_text())
        self.assertEqual(len(list(self.state.glob("*.pid"))), 3)
        self.assertEqual(Path((self.directory / "status-config").read_text()),
                         self.state / "config.json")
        self.assertTrue((self.state / "bridge.ready").exists())
        self.assertTrue((self.state / "relay.ready").exists())
        self.assertFalse(any(name == "nc" for name, args in self.calls()))
        pids = [int(file.read_text()) for file in self.state.glob("*.pid")]
        stopped = self.invoke("stop")
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        self.assert_dead(pids)
        self.assertFalse(list(self.state.glob("*.pid")))
        self.assertTrue((self.directory / "container.removed").exists())

    def test_unexpected_password_failure_unwinds_host_and_preserves_code(self):
        result = self.invoke(FIXTURE_FAILURE="password")
        self.assertEqual(result.returncode, 69, result.stderr)
        observed = json.loads((self.directory / "observed.json").read_text())
        self.assertIn("host", observed)
        self.assert_dead(observed.values())
        self.assertFalse((self.state / "host.pid").exists())
        self.assertEqual(result.stdout, "")

    def test_network_and_fingerprint_command_failures_are_not_masked_by_pipelines(self):
        for stage, code in [("network", 70), ("fingerprint", 73)]:
            with self.subTest(stage=stage):
                result = self.invoke(FIXTURE_FAILURE=stage)
                self.assertEqual(result.returncode, code, result.stderr)
                observed = json.loads((self.directory / "observed.json").read_text())
                self.assert_dead(observed.values())
                self.assertFalse(list(self.state.glob("*.pid")))
                self.assertEqual(result.stdout, "")
        self.assertTrue((self.directory / "container.removed").exists())

    def test_container_partial_creation_is_recorded_before_failing_run(self):
        result = self.invoke(FIXTURE_FAILURE="container-run")
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.directory / "container.created").exists())
        self.assertTrue((self.directory / "container.removed").exists())
        self.assertFalse((self.state / "container.name").exists())
        observed = json.loads((self.directory / "observed.json").read_text())
        self.assert_dead(observed.values())

    def test_dead_owned_process_aborts_setup_even_when_port_probe_would_succeed(self):
        for role in ["host", "bridge", "relay"]:
            with self.subTest(role=role):
                result = self.invoke(FIXTURE_FAILURE=role + "-exit")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(role + " did not start", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(list(self.state.glob("*.pid")))
                pids = [int(file.read_text()) for file in self.directory.glob("*.started")]
                self.assert_dead(pids)
                self.assertFalse(any(name == "nc" for name, args in self.calls()))
                for file in self.directory.glob("*.started"):
                    file.unlink()
                for file in self.state.glob("*.ready"):
                    file.unlink()

    def test_early_build_failure_starts_no_host_or_container(self):
        result = self.invoke(FIXTURE_FAILURE="container-build")
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.directory / "host.started").exists())
        self.assertFalse((self.directory / "container.created").exists())

    def test_empty_gateway_aborts_before_container_creation(self):
        result = self.invoke(FIXTURE_FAILURE="empty-network")
        self.assertEqual(result.returncode, 1)
        self.assertIn("has no gateway", result.stderr)
        self.assertFalse((self.directory / "container.created").exists())
        self.assertFalse(list(self.state.glob("*.pid")))

    def test_invalid_port_overrides_fail_before_resource_commands(self):
        for key in ["RST_QUIC_PORT", "RST_SSH_PORT"]:
            for value in ["", "0", "65536", "-1", "１２", "1.5", " 80", "999999999999999999"]:
                with self.subTest(key=key, value=value):
                    calls = self.directory / "calls.jsonl"
                    calls.unlink(missing_ok=True)
                    result = self.invoke(**{key: value})
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse(list(self.state.glob("*.pid")))
                    self.assertTrue(all(name == "python3" for name, args in self.calls()))
                    self.assertFalse((self.directory / "container.created").exists())

    def test_pinned_ports_are_normalized_in_configuration_and_environment(self):
        result = self.invoke(RST_QUIC_PORT="00001", RST_SSH_PORT="065535")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.state / "config.json").read_text())["port"], 1)
        environment = (self.state / "env").read_text()
        self.assertIn("export RST_REAL_SSH_PORT=65535\n", environment)
        self.assertIn("export RST_REAL_SSH_QUIC_PORT=1\n", environment)
        self.assertEqual(self.invoke("stop").returncode, 0)
        self.assert_dead([int(p.read_text()) for p in self.directory.glob("*.started")])

    def test_gateway_outside_reported_subnet_aborts_before_container_creation(self):
        result = self.invoke(FIXTURE_FAILURE="wrong-gateway")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("has no gateway", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse((self.directory / "container.created").exists())
        self.assertFalse(list(self.state.glob("*.pid")))
        self.assert_dead([int(p.read_text()) for p in self.directory.glob("*.started")])

    def test_existing_markers_are_refused_before_build_or_cleanup(self):
        self.state.mkdir()
        for name in ["host.pid", "advertiser.pid", "advertiser.owner",
                     "xcodebuild.pid", "xcodebuild.owner"]:
            with self.subTest(marker=name):
                marker = self.state / name
                marker.write_text(str(os.getpid()))
                result = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertIn("already recorded", result.stderr)
                self.assertEqual(marker.read_text(), str(os.getpid()))
                self.assertEqual(self.calls(), [])
                marker.unlink()

    def test_bad_pids_and_container_markers_never_become_kill_targets(self):
        self.state.mkdir()
        marker = self.state / "host.pid"
        for value in ["0", "1", "-1", "--help", "", "abc", "0002", "2147483648"]:
            with self.subTest(value=value):
                marker.write_text(value)
                result = self.invoke("stop")
                self.assertEqual(result.returncode, 1)
                self.assertTrue(marker.exists())
        marker.unlink()
        container = self.state / "container.name"
        for value in ["--all", "other-container", "swiftty-rst-ssh-x\nother"]:
            with self.subTest(value=value):
                container.write_text(value)
                self.assertEqual(self.invoke("stop").returncode, 1)
                self.assertTrue(container.exists())
        self.assertTrue(all(name == "python3" for name, _ in self.calls()))

    def test_failed_container_removal_preserves_marker_and_reports_failure(self):
        self.state.mkdir()
        marker = self.state / "container.name"
        marker.write_text("swiftty-rst-ssh-test")
        result = self.invoke("stop", FIXTURE_FAILURE="container-remove")
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot remove", result.stderr)
        self.assertEqual(marker.read_text(), "swiftty-rst-ssh-test")

    def test_already_absent_container_is_successful_cleanup(self):
        self.state.mkdir()
        marker = self.state / "container.name"
        marker.write_text("swiftty-rst-ssh-test\n")
        result = self.invoke("stop", FIXTURE_CONTAINER_ABSENT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertIn(["container", ["list", "--all", "--format", "json"]], self.calls())

    def test_failed_or_malformed_listing_cannot_prove_container_absence(self):
        self.state.mkdir()
        marker = self.state / "container.name"
        for settings in [{"FIXTURE_FAILURE": "container-list"},
                         *({"FIXTURE_CONTAINER_LIST": value} for value in
                           ["", "{", "{}", "null", "[{}]", '[{"id":null}]',
                            '[{"id":""}]', '[{"id":"swiftty-rst-ssh-test"}]'])]:
            with self.subTest(settings=settings):
                marker.write_text("swiftty-rst-ssh-test\n")
                result = self.invoke("stop", FIXTURE_CONTAINER_ABSENT="1", **settings)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(marker.read_text(), "swiftty-rst-ssh-test\n")

    def test_broken_marker_link_is_refused_before_start(self):
        self.state.mkdir()
        marker = self.state / "host.pid"
        marker.symlink_to(self.directory / "unrelated-missing-file")
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertTrue(marker.is_symlink())
        self.assertEqual(self.calls(), [])

    def test_extra_start_arguments_are_rejected_before_tools(self):
        self.assertEqual(self.invoke(extra=("unexpected",)).returncode, 2)
        self.assertEqual(self.calls(), [])

    def install_stub_environment(self):
        shutil.copyfile(ROOT / "Scripts/real-ssh-evidence.py",
                        self.root / "Scripts/real-ssh-evidence.py")
        # Captured local schema probe; module renamed to test the gate contract.
        events = self.directory / "test-events.jsonl"
        fixture = Path(__file__).parent / "Fixtures/real-ssh-events.jsonl"
        shutil.copyfile(fixture, events)
        self.environment["FIXTURE_EVENTS"] = str(events)
        self.state.mkdir()
        environment = self.state / "env"
        environment.write_text("export RST_REAL_SSH_USER=rst\n")
        self.script.write_text(
            "#!" + sys.executable + "\n"
            "import os,sys\nfrom pathlib import Path\n"
            "root=Path(os.environ['FIXTURE_DIRECTORY'])\n"
            "with (root/'calls.jsonl').open('a') as f:\n"
            " import json; f.write(json.dumps(['fixture',sys.argv[1:]])+'\\n')\n"
            "if sys.argv[1]=='start': print(root/'state/env')\n"
            "else:\n"
            " with (root/'stop.calls').open('a') as f: f.write('stop\\n')\n"
            " sys.exit(int(os.environ.get('FIXTURE_STOP_CODE','0')))\n"
        )
        self.script.chmod(0o755)
    def test_real_ssh_caller_cleans_once_and_preserves_primary_failure(self):
        caller = self.root / "Scripts/test-real-ssh.sh"
        shutil.copyfile(ROOT / "Scripts/test-real-ssh.sh", caller)
        self.install_stub_environment()
        for test_code, stop_code, expected in [(0, 0, 0), (73, 0, 73),
                                                (0, 42, 1), (73, 42, 73)]:
            with self.subTest(test_code=test_code, stop_code=stop_code):
                (self.directory / "stop.calls").unlink(missing_ok=True)
                result = subprocess.run(
                    ["/bin/sh", str(caller)], env={**self.environment,
                        "FIXTURE_TEST_CODE": str(test_code),
                        "FIXTURE_STOP_CODE": str(stop_code)},
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual((self.directory / "stop.calls").read_text(), "stop\n")

    def test_real_ssh_caller_uses_the_configuration_recorded_by_the_fixture(self):
        caller = self.root / "Scripts/test-real-ssh.sh"
        shutil.copyfile(ROOT / "Scripts/test-real-ssh.sh", caller)
        self.install_stub_environment()
        with (self.state / "env").open("a") as environment:
            environment.write("export RST_REAL_SSH_CONFIGURATION=release\n")
        result = subprocess.run(
            ["/bin/sh", str(caller)],
            env={**self.environment, "RST_REAL_SSH_CONFIGURATION": "release"},
            capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        tests = [args for name, args in self.calls() if name == "mise" and "test" in args]
        self.assertEqual(len(tests), 1)
        self.assertEqual(tests[0][:6], ["exec", "--", "swift", "test", "-c", "release"])
        self.assertIn("--skip-build", tests[0])
        calls = self.calls()
        build = ["mise", ["exec", "--", "swift", "build", "-c", "release",
                          "--build-tests", "-Xswiftc", "-enable-testing"]]
        self.assertLess(calls.index(build), calls.index(["fixture", ["start"]]))
        self.assertLess(calls.index(["fixture", ["start"]]), calls.index(["mise", tests[0]]))

    def test_real_ssh_caller_rejects_configuration_mismatch_and_stops_fixture(self):
        caller = self.root / "Scripts/test-real-ssh.sh"
        shutil.copyfile(ROOT / "Scripts/test-real-ssh.sh", caller)
        self.install_stub_environment()
        with (self.state / "env").open("a") as environment:
            environment.write("export RST_REAL_SSH_CONFIGURATION=release\n")
        result = subprocess.run(
            ["/bin/sh", str(caller)], env=self.environment,
            capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"differs from the prebuilt tests", result.stderr)
        self.assertEqual((self.directory / "stop.calls").read_text(), "stop\n")
        self.assertFalse(any(name == "mise" and "test" in args for name, args in self.calls()))

    def test_real_ssh_caller_build_failure_starts_no_fixture(self):
        caller = self.root / "Scripts/test-real-ssh.sh"
        shutil.copyfile(ROOT / "Scripts/test-real-ssh.sh", caller)
        self.install_stub_environment()
        result = subprocess.run(
            ["/bin/sh", str(caller)],
            env={**self.environment, "FIXTURE_FAILURE": "swift-build"},
            capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 62, result.stderr)
        self.assertFalse(any(name == "fixture" for name, _ in self.calls()))

    def test_real_ssh_caller_rejects_invalid_configuration_before_building(self):
        caller = self.root / "Scripts/test-real-ssh.sh"
        shutil.copyfile(ROOT / "Scripts/test-real-ssh.sh", caller)
        self.install_stub_environment()
        for value in ["", "Release", "../release", "--help"]:
            with self.subTest(configuration=value):
                result = subprocess.run(
                    ["/bin/sh", str(caller)],
                    env={**self.environment, "RST_REAL_SSH_CONFIGURATION": value},
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(self.calls(), [])

    def test_real_ssh_caller_rejects_missing_or_skipped_test_evidence(self):
        caller = self.root / "Scripts/test-real-ssh.sh"
        shutil.copyfile(ROOT / "Scripts/test-real-ssh.sh", caller)
        self.install_stub_environment()
        fixture = Path(self.environment["FIXTURE_EVENTS"])
        for evidence in [None, "", json.dumps({"version": 0, "kind": "event",
                                         "payload": {"kind": "testSkipped"}}) + "\n"]:
            with self.subTest(evidence=evidence):
                (self.directory / "stop.calls").unlink(missing_ok=True)
                if evidence is not None:
                    fixture.write_text(evidence)
                # A previous successful stream must not cover a silent test invocation.
                shutil.copyfile(Path(__file__).parent / "Fixtures/real-ssh-events.jsonl",
                                self.state / "test-events.jsonl")
                result = subprocess.run(
                    ["/bin/sh", str(caller)], env={**self.environment,
                        "FIXTURE_EVENTS": str(fixture) if evidence is not None else ""},
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"evidence failed", result.stderr)
                self.assertEqual((self.directory / "stop.calls").read_text(), "stop\n")

    def test_handover_caller_cleans_once_after_generation_failure(self):
        caller = self.root / "Scripts/test-handover.sh"
        shutil.copyfile(ROOT / "Scripts/test-handover.sh", caller)
        self.install_stub_environment()
        # Stop before signing, installation, or any physical-device operation.
        for name in ["xcodegen", "xcodebuild"]:
            tool = self.bin / name
            tool.write_text("#!/bin/sh\nexit 74\n")
            tool.chmod(0o755)
        for stop_code in [0, 42]:
            with self.subTest(stop_code=stop_code):
                (self.directory / "stop.calls").unlink(missing_ok=True)
                result = subprocess.run(
                    ["/bin/sh", str(caller), "fake-device"],
                    env={**self.environment, "RST_PUBLIC_HOST": "127.0.0.1",
                         "FIXTURE_STOP_CODE": str(stop_code)},
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 74, result.stderr)
                self.assertEqual((self.directory / "stop.calls").read_text(), "stop\n")


if __name__ == "__main__":
    unittest.main()
