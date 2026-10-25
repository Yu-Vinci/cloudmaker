#!/usr/bin/env bash
# usage: scripts/manual-vm.sh create|ip|delete [name]
set -euo pipefail

ACTION="${1:-}"
NAME="${2:-cm-manual}"
BASE_IMAGE="${BASE_IMAGE:-/var/lib/libvirt/images/noble-base.img}"
VIRSH=(virsh -c qemu:///system)

case "$ACTION" in
  create)
    [ -f "$BASE_IMAGE" ] || "$(dirname "$0")/get-image.sh" "$BASE_IMAGE"
    USER_DATA="$(mktemp)"
    trap 'rm -f "$USER_DATA"' EXIT
    cat > "$USER_DATA" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: student
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: student
EOF
    if [ -n "${SSH_PUBKEY:-}" ]; then
      printf '    ssh_authorized_keys:\n      - %s\n' "$SSH_PUBKEY" >> "$USER_DATA"
    fi
    echo "ssh_pwauth: true" >> "$USER_DATA"

    virt-install --connect qemu:///system \
      --name "$NAME" --memory 2048 --vcpus 2 \
      --disk size=10,format=qcow2,backing_store="$BASE_IMAGE",backing_format=qcow2,bus=virtio \
      --import --os-variant ubuntu24.04 \
      --network network=default \
      --cloud-init user-data="$USER_DATA" \
      --graphics none --noautoconsole
    ;;
  ip)
    "${VIRSH[@]}" domifaddr "$NAME"
    ;;
  delete)
    "${VIRSH[@]}" destroy "$NAME" 2>/dev/null || true
    "${VIRSH[@]}" undefine "$NAME" --remove-all-storage
    ;;
  *)
    echo "usage: $0 create|ip|delete [name]" >&2
    exit 2
    ;;
esac
