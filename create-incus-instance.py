#!/usr/bin/env python3
# /// script
# requires-python = ">=3.14"
# dependencies = [
#     "pyyaml>=6.0.3",
# ]
# ///

import argparse
import ipaddress
import json
import subprocess
import sys

import yaml


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create an Incus instance")

    parser.add_argument("name", help="Name of the Incus instance to create")
    parser.add_argument(
        "--image",
        help="Image to use for the instance",
        default="images:debian/13/cloud",
    )
    parser.add_argument(
        "--profile",
        dest="profiles",
        help="Profile to use for the instance",
        action="append",
        default=["debian"],
    )
    parser.add_argument(
        "--vm", help="Create a VM instead of a container", action="store_true"
    )
    parser.add_argument("--dhcp", help="Use DHCP for networking", action="store_true")
    parser.add_argument(
        "--incus-bridge", help="Name of the Incus bridge to use", default="incusbr0"
    )
    parser.add_argument(
        "--nameserver",
        dest="nameservers",
        help="DNS nameserver to use (can be specified multiple times)",
        action="append",
    )
    parser.add_argument(
        "--search-domain",
        dest="search_domains",
        help="DNS search domain to use (can be specified multiple times)",
        action="append",
    )

    return parser.parse_args()


def get_network_config(bridge: str) -> dict:
    print(f"Retrieving network configuration for Incus bridge '{bridge}'")
    ipv4_address = subprocess.run(
        ["incus", "network", "get", bridge, "ipv4.address"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    print(f"Bridge '{bridge}' has IPv4 address: {ipv4_address}")

    ipv4_interface = ipaddress.IPv4Interface(ipv4_address)
    ipv4_network = ipv4_interface.network
    gateway_ip = str(ipv4_network.network_address + 1)
    print(f"Calculated gateway IP: {gateway_ip}")

    incus_bridge_info = subprocess.run(
        ["incus", "query", f"/1.0/networks/{bridge}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    instances = json.loads(incus_bridge_info)["used_by"]
    instance_ips = [gateway_ip]
    for instance in instances:
        if instance.startswith("/1.0/instances/"):
            instance_info = subprocess.run(
                ["incus", "query", f"{instance}/state"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            instance_data = json.loads(instance_info)
            network = instance_data.get("network", None)
            if network is not None:
                for i, net in network.items():
                    if i == "lo":
                        continue
                    ip_addresses = net.get("addresses", [])
                    for ip in ip_addresses:
                        if ip.get("family") == "inet":
                            instance_ips.append(ip["address"])

    print(f"Existing IPs in use: {instance_ips}")

    network_config = {}
    for host in ipv4_network.hosts():
        if str(host) not in instance_ips:
            network_config = {
                "address": f"{host!s}/{ipv4_network.prefixlen}",
                "gateway": gateway_ip,
            }
            break

    return network_config


def main() -> int:
    args = parse_args()
    instance_type = "virtual machine" if args.vm else "container"
    print(
        f"Creating Incus {instance_type} instance '{args.name}' with image '{args.image}' and profiles '{args.profiles}'"
    )
    command = ["incus", "create", args.image, args.name]
    for profile in args.profiles or []:
        command.extend(["--profile", profile])
    if args.vm:
        command.append("--vm")
    p = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        print(f"Failed to create instance: {p.stderr}")
        return 1

    print(f"Instance '{args.name}' created successfully")

    if args.dhcp:
        print("DHCP is enabled, skipping static IP configuration")
        return 0

    print("DHCP is disabled, calculating static IP configuration...")
    interface_name = "eth0" if not args.vm else "enp5s0"
    nameservers = args.nameservers if args.nameservers else ["1.1.1.1"]
    search_domains = args.search_domains if args.search_domains else ["lab.internal"]
    print(f"Using Incus bridge '{args.incus_bridge}' for network configuration")
    network_config = get_network_config(args.incus_bridge)
    cloud_init_config = yaml.dump(
        data={
                "version": 2,
                "renderer": "networkd",
                "ethernets": {
                    interface_name: {
                        "dhcp4": False,
                        "routes": [
                            {
                                "to": "0.0.0.0/0",
                                "via": network_config["gateway"],
                            }
                        ],
                        "addresses": [network_config["address"]],
                        "nameservers": {
                            "addresses": nameservers,
                            "search": search_domains,
                        },
                    }
                },
            },
        sort_keys=False,
        default_flow_style=False,
    )
    print("Generated cloud-init network configuration:")
    print(cloud_init_config)

    print("Applying cloud-init network configuration to the instance...")
    p = subprocess.run(
        ["incus", "config", "set", args.name, "cloud-init.network-config", "-"],
        check=True,
        capture_output=True,
        text=True,
        input=cloud_init_config,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
