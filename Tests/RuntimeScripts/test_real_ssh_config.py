"""Validate fixture port advertisements and authoritative JSON gateway selection."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/real-ssh-config.py"
SPEC = importlib.util.spec_from_file_location("real_ssh_config", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def network(gateway="192.168.64.1", subnet="192.168.64.0/24", identity="default"):
    return {"id": identity, "status": {"ipv4Gateway": gateway, "ipv4Subnet": subnet}}


class ConfigurationTests(unittest.TestCase):
    def test_port_boundaries_and_leading_zero_normalization(self):
        for value, expected in [("1", 1), ("65535", 65535), ("000080", 80), ("052000", 52000)]:
            with self.subTest(value=value):
                self.assertEqual(MODULE.port_number(value), expected)

    def test_invalid_ports_are_rejected(self):
        for value in ["", "0", "00000", "65536", "-1", "+80", " 80", "80 ",
                      "12.0", "１２", "١٢", "12\n", "9" * 10000]:
            with self.subTest(value=value[:20]), self.assertRaises(argparse.ArgumentTypeError):
                MODULE.port_number(value)

    def test_reported_gateway_is_used_for_multiple_subnet_layouts(self):
        for gateway, subnet in [("192.168.64.1", "192.168.64.0/24"),
                                ("192.168.64.129", "192.168.64.128/25"),
                                ("10.0.4.6", "10.0.4.0/29"),
                                ("10.0.7.2", "10.0.0.0/20"),
                                ("192.0.2.0", "192.0.2.0/31")]:
            with self.subTest(subnet=subnet):
                self.assertEqual(MODULE.default_gateway(json.dumps([network(gateway, subnet)]).encode()),
                                 gateway)

    def test_default_identity_is_unique_and_unrelated_networks_do_not_override_it(self):
        records = [network("10.0.0.1", "10.0.0.0/24", "other"), network()]
        self.assertEqual(MODULE.default_gateway(json.dumps(records).encode()), "192.168.64.1")
        for records in [[], [network(identity="other")], [network(), network()]]:
            with self.subTest(records=records), self.assertRaises(ValueError):
                MODULE.default_gateway(json.dumps(records).encode())

    def test_missing_or_malformed_network_information_fails(self):
        for records in [None, {}, [None], [{}], [{"id": "default"}],
                        [{"id": "default", "status": None}],
                        [{"id": "default", "status": {"ipv4Gateway": 1, "ipv4Subnet": "192.168.64.0/24"}}]]:
            with self.subTest(records=records), self.assertRaises(ValueError):
                MODULE.default_gateway(json.dumps(records).encode())
        for data in [b"{", b"\xff", b"[" * 2000 + b"]" * 2000, b"x" * (MODULE.LIMIT + 1)]:
            with self.subTest(data=data[:5]), self.assertRaises(ValueError):
                MODULE.default_gateway(data)

    def test_invalid_gateway_address_or_subnet_fails(self):
        for gateway, subnet in [("192.0.2.1", "192.168.64.0/24"),
                                ("192.168.64.0", "192.168.64.0/24"),
                                ("192.168.64.255", "192.168.64.0/24"),
                                ("0.0.0.0", "0.0.0.0/0"),
                                ("224.1.1.1", "224.1.1.0/24"),
                                ("::1", "192.168.64.0/24"),
                                ("192.168.64.1", "192.168.64.1/24"),
                                ("192.168.64.1/24", "192.168.64.0/24"),
                                ("192.168.64.1", "invalid")]:
            with self.subTest(gateway=gateway, subnet=subnet), self.assertRaises(ValueError):
                MODULE.default_gateway(json.dumps([network(gateway, subnet)]).encode())

    def test_cli_ports_and_gateway_emit_only_canonical_values(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "ports", "00080", "065535"],
                                capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"80 65535\n")
        result = subprocess.run([sys.executable, str(SCRIPT), "gateway"],
                                input=json.dumps([network()]).encode(), capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"192.168.64.1\n")

    def test_cli_invalid_configuration_never_emits_advertised_value(self):
        for arguments, data, expected in [(["ports", "0", "22"], None, 2),
                                           (["ports", "22", "65536"], None, 2),
                                           (["gateway"], b"[]", 1),
                                           (["gateway"], b"x" * (MODULE.LIMIT + 1), 1)]:
            with self.subTest(arguments=arguments):
                result = subprocess.run([sys.executable, str(SCRIPT), *arguments], input=data,
                                        capture_output=True, timeout=3)
                self.assertEqual(result.returncode, expected)
                self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
