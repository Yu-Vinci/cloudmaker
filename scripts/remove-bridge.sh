#!/usr/bin/env bash
# usage: scripts/remove-bridge.sh [bridge]

BR="${1:-br0}"

for con in $(nmcli -t -f NAME con show | grep "^$BR"); do
  sudo nmcli con delete "$con"
done
sudo iptables -D DOCKER-USER -i "$BR" -o "$BR" -j ACCEPT 2>/dev/null
echo "Bridge $BR removed"
