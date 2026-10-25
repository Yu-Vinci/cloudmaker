#!/usr/bin/env bash
# usage: scripts/cleanup.sh [--all]
cd "$(dirname "$0")/.."

API=http://127.0.0.1:8000
VM_DIR=/var/lib/libvirt/images/cloudmaker
VIRSH=(virsh -c qemu:///system)

echo "== VMs and networks created through the API"
if curl -sf "$API/health" >/dev/null; then
  for vm in $(curl -s "$API/vms" | jq -r '.[].name'); do
    curl -s -X DELETE "$API/vms/$vm"
    echo "  removed $vm"
  done
  for net in $(curl -s "$API/networks" | jq -r '.[].name'); do
    curl -s -X DELETE "$API/networks/$net"
    echo "  removed $net"
  done
fi

echo "== Leftover VMs and networks"
for vm in $("${VIRSH[@]}" list --all --name); do
  if [[ "$vm" == cm-test-* ]] || "${VIRSH[@]}" domblklist "$vm" | grep -q "$VM_DIR"; then
    "${VIRSH[@]}" destroy "$vm" >/dev/null 2>&1
    "${VIRSH[@]}" undefine "$vm" --remove-all-storage >/dev/null 2>&1 || "${VIRSH[@]}" undefine "$vm" >/dev/null
    echo "  removed $vm"
  fi
done
for net in $("${VIRSH[@]}" net-list --all --name | grep '^cm-test-'); do
  "${VIRSH[@]}" net-destroy "$net" >/dev/null 2>&1
  "${VIRSH[@]}" net-undefine "$net" >/dev/null
  echo "  removed $net"
done

echo "== Container"
if [ "${1:-}" = "--all" ]; then
  docker compose down --rmi all
else
  docker compose down
fi

echo "== Files"
sudo rm -rf "$VM_DIR" /var/lib/cloudmaker
if [ "${1:-}" = "--all" ]; then
  sudo rm -f /var/lib/libvirt/images/noble-base.img
fi
echo "Done"
