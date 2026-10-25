#!/usr/bin/env bash
# usage: scripts/setup-bridge.sh <wired interface> [bridge]
set -euo pipefail

IFACE="${1:?usage: $0 <wired interface, e.g. enp0s31f6> [bridge]}"
BR="${2:-br0}"

if ! nmcli con show "$BR" >/dev/null 2>&1; then
  sudo nmcli con add type bridge ifname "$BR" con-name "$BR" bridge.stp no
  sudo nmcli con add type bridge-slave ifname "$IFACE" master "$BR" con-name "$BR-port-$IFACE"
fi
sudo nmcli con up "$BR-port-$IFACE"
sudo nmcli con up "$BR"

# docker drops forwarded traffic by default, so allow traffic through the bridge
sudo iptables -C DOCKER-USER -i "$BR" -o "$BR" -j ACCEPT 2>/dev/null \
  || sudo iptables -I DOCKER-USER -i "$BR" -o "$BR" -j ACCEPT

sleep 5
ip -br addr show "$BR"
