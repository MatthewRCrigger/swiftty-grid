#!/usr/bin/env python3
"""Validate fixed fixture ports and the container daemon's default IPv4 gateway."""

import argparse
import ipaddress
import json
import sys


LIMIT = 65536


def port_number(value):
    if not value.isascii() or not value.isdecimal():
        raise argparse.ArgumentTypeError("port must be a decimal integer from 1 to 65535")
    digits = value.lstrip("0")
    if not digits or len(digits) > 5 or int(digits) > 65535:
        raise argparse.ArgumentTypeError("port must be a decimal integer from 1 to 65535")
    return int(digits)


def default_gateway(data):
    if len(data) > LIMIT:
        raise ValueError("network list exceeds 64 KiB")
    try:
        networks = json.loads(data)
        if not isinstance(networks, list) or any(not isinstance(item, dict) for item in networks):
            raise ValueError("network list must contain network records")
        matches = [item for item in networks if item.get("id") == "default"]
        if len(matches) != 1:
            raise ValueError("network list must contain exactly one default network")
        status = matches[0]["status"]
        raw_gateway, raw_subnet = status["ipv4Gateway"], status["ipv4Subnet"]
        if not isinstance(raw_gateway, str) or not isinstance(raw_subnet, str):
            raise ValueError("default network gateway and subnet must be strings")
        gateway = ipaddress.IPv4Address(raw_gateway)
        subnet = ipaddress.IPv4Network(raw_subnet)
        if (gateway not in subnet or gateway.is_unspecified or gateway.is_multicast
                or (subnet.prefixlen < 31 and gateway in {subnet.network_address, subnet.broadcast_address})):
            raise ValueError("default network has no usable IPv4 gateway")
        return str(gateway)
    except (KeyError, TypeError, RecursionError) as error:
        raise ValueError("invalid default network gateway information") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    ports = sub.add_parser("ports")
    ports.add_argument("quic", type=port_number)
    ports.add_argument("ssh", type=port_number)
    sub.add_parser("gateway")
    args = parser.parse_args()
    try:
        if args.command == "ports":
            print(args.quic, args.ssh)
        else:
            print(default_gateway(sys.stdin.buffer.read(LIMIT + 1)))
    except (ValueError, UnicodeError, OSError) as error:
        print(f"fixture configuration failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
