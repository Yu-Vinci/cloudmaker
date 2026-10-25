#!/usr/bin/env bash
# Checks all implemented items with one script (item 11).
#   scripts/check.sh
# Environment variables:
#   BRIDGE=br0        host bridge for item 3 (the bridge check is skipped if it does not exist)
#   BASE_IMAGE=...    base cloud image (Ubuntu 24.04 is downloaded by default)
#   API=http://127.0.0.1:8000
set -uo pipefail
cd "$(dirname "$0")/.."

API="${API:-http://127.0.0.1:8000}"
BASE_IMAGE="${BASE_IMAGE:-/var/lib/libvirt/images/noble-base.img}"
BRIDGE="${BRIDGE:-br0}"
VM_DIR=/var/lib/libvirt/images/cloudmaker
VIRSH=(virsh -c qemu:///system)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
SKIPPED=0
SUMMARY=()

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; SUMMARY+=("PASS  $1"); PASSED=$((PASSED + 1)); return 0; }
fail() {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi
  SUMMARY+=("FAIL  $1"); FAILED=$((FAILED + 1)); return 1
}
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SUMMARY+=("SKIP  $1"); SKIPPED=$((SKIPPED + 1)); }

# api METHOD PATH [JSON] -> $CODE, $BODY
api() {
  local args=(-s -o "$WORK/body" -w '%{http_code}' -X "$1")
  if [ $# -ge 3 ]; then args+=(-H 'Content-Type: application/json' -d "$3"); fi
  CODE="$(curl "${args[@]}" "$API$2")" || CODE=000
  BODY="$(cat "$WORK/body" 2>/dev/null || true)"
}
expect() { if [ "$CODE" = "$1" ]; then pass "$2"; else fail "$2" "HTTP $CODE: $BODY"; fi; }

wait_health() {
  for _ in $(seq 1 60); do curl -sf "$API/health" >/dev/null && return 0; sleep 2; done
  return 1
}
wait_state() {  # VM state seconds
  for _ in $(seq 1 "$3"); do
    [ "$("${VIRSH[@]}" domstate "$1" 2>/dev/null | head -1)" = "$2" ] && return 0
    sleep 1
  done
  return 1
}
wait_ip() {  # VM regex seconds -> prints the IP reported by the API
  local ip
  for _ in $(seq 1 $(($3 / 3))); do
    api GET "/vms/$1"
    ip="$(jq -r --arg re "$2" '[.ips[]? | select(test($re))][0] // empty' <<<"$BODY" 2>/dev/null)"
    if [ -n "$ip" ]; then echo "$ip"; return 0; fi
    sleep 3
  done
  return 1
}
SSH_OPTS=(-i "$WORK/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)
ssh_vm() { local target=$1; shift; ssh "${SSH_OPTS[@]}" "$target" "$@"; }
wait_ssh() {
  for _ in $(seq 1 $((${2:-180} / 5))); do ssh_vm "$1" true 2>/dev/null && return 0; sleep 5; done
  return 1
}

# ---------------------------------------------------------------------------
section "Preparation"
for cmd in docker curl jq ssh ssh-keygen virsh virt-install; do
  command -v "$cmd" >/dev/null || { echo "Command $cmd not found (see README, \"How to check\")"; exit 2; }
done
docker compose version >/dev/null 2>&1 || { echo "docker compose is required: sudo apt install docker-compose-v2"; exit 2; }
[ -f "$BASE_IMAGE" ] || scripts/get-image.sh "$BASE_IMAGE" || exit 2
ssh-keygen -q -t ed25519 -N '' -C cloudmaker-check -f "$WORK/id"
PUBKEY="$(cat "$WORK/id.pub")"
echo "  base image: $BASE_IMAGE"

# ---------------------------------------------------------------------------
section "Base task: VM without a GUI (virt-install + cloud-init)"
"${VIRSH[@]}" destroy cm-test-manual >/dev/null 2>&1
"${VIRSH[@]}" undefine cm-test-manual --remove-all-storage >/dev/null 2>&1
if SSH_PUBKEY="$PUBKEY" scripts/manual-vm.sh create cm-test-manual >"$WORK/manual.log" 2>&1; then
  pass "[base] virt-install created VM cm-test-manual"
  wait_state cm-test-manual running 60 && pass "[base] VM is running (virsh domstate)" || fail "[base] VM did not start"
  MIP=""
  for _ in $(seq 1 40); do
    MIP="$("${VIRSH[@]}" domifaddr cm-test-manual 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1]; exit }')"
    [ -n "$MIP" ] && break
    sleep 3
  done
  if [ -n "$MIP" ] && wait_ssh "student@$MIP"; then
    [ "$(ssh_vm "student@$MIP" hostname)" = cm-test-manual ] \
      && pass "[base] SSH login ($MIP), hostname set by cloud-init" \
      || fail "[base] hostname does not match"
  else
    fail "[base] no SSH access to the VM (IP: ${MIP:-not received})"
  fi
else
  fail "[base] virt-install" "$(tail -5 "$WORK/manual.log")"
fi
scripts/manual-vm.sh delete cm-test-manual >/dev/null 2>&1
"${VIRSH[@]}" list --all --name | grep -qx cm-test-manual \
  && fail "[base] VM cm-test-manual was not deleted" || pass "[base] VM deleted together with its disk"

# ---------------------------------------------------------------------------
section "Item 5: containerized application manages VMs on the host"
if ! docker compose up -d --build >"$WORK/compose.log" 2>&1; then
  fail "[5] docker compose up" "$(tail -20 "$WORK/compose.log")"
  exit 1
fi
if wait_health; then
  pass "[5] service runs in a container, API answers: $API/health"
else
  fail "[5] API does not answer" "$(docker compose logs --tail 20 2>&1)"
  exit 1
fi
docker inspect cloudmaker --format '{{range .Mounts}}{{.Destination}} {{end}}' | grep -q '/var/run/libvirt' \
  && pass "[5] the host libvirtd socket is mounted into the container (/var/run/libvirt)" \
  || fail "[5] libvirt socket is not mounted"

# leftovers from previous runs
for vm in cm-test-vm1 cm-test-br; do api DELETE "/vms/$vm"; done
for net in cm-test-nat cm-test-iso cm-test-lan; do api DELETE "/networks/$net"; done
api DELETE /images/cm-test-ubuntu

# ---------------------------------------------------------------------------
section "Item 7: image registration"
api POST /images "$(jq -n --arg p "$BASE_IMAGE" '{name: "cm-test-ubuntu", path: $p, description: "Ubuntu 24.04 cloud image"}')"
expect 201 "[7] POST /images registers an image (name, path, description)"
api GET /images
jq -e '.[] | select(.name == "cm-test-ubuntu" and .format != null)' <<<"$BODY" >/dev/null \
  && pass "[7] image is listed in GET /images, detected format: $(jq -r '.[] | select(.name == "cm-test-ubuntu") | .format' <<<"$BODY")" \
  || fail "[7] image is missing from GET /images" "$BODY"
api POST /images '{"name": "cm-test-bad", "path": "/var/lib/libvirt/images/no-such-file.img"}'
expect 422 "[7] a non-existent file is rejected"

# ---------------------------------------------------------------------------
section "Item 3: virtual networks"
api POST /networks '{"name": "cm-test-nat", "mode": "nat", "subnet": "10.77.0.0/24"}'
expect 201 "[3] created NAT network cm-test-nat 10.77.0.0/24"
api POST /networks '{"name": "cm-test-iso", "mode": "isolated", "subnet": "10.78.0.0/24"}'
expect 201 "[3] created isolated network cm-test-iso 10.78.0.0/24"
NETS="$("${VIRSH[@]}" net-list --name)"
grep -qx cm-test-nat <<<"$NETS" && grep -qx cm-test-iso <<<"$NETS" \
  && pass "[3] networks are active on the host (virsh net-list)" || fail "[3] networks are missing from virsh net-list"

# ---------------------------------------------------------------------------
section "Item 9: quotas"
api GET /quota
echo "  $BODY"
LIMIT_CPU="$(jq '.limits.vcpus' <<<"$BODY")"
api POST /vms "$(jq -n --argjson c "$((LIMIT_CPU + 1))" '{name: "cm-test-big", image: "cm-test-ubuntu", vcpus: $c, networks: ["cm-test-nat"]}')"
expect 409 "[9] VM with vcpus=$((LIMIT_CPU + 1)) is rejected with a limit of $LIMIT_CPU"

# ---------------------------------------------------------------------------
section "Items 1 and 2: create a VM through the API, cloud-init"
USER_DATA=$'#cloud-config\nwrite_files:\n  - path: /etc/cloudmaker-test\n    content: "hello from user_data"\n'
api POST /vms "$(jq -n --arg key "$PUBKEY" --arg ud "$USER_DATA" '{
  name: "cm-test-vm1", image: "cm-test-ubuntu", vcpus: 1, memory_mb: 1024, disk_gb: 10,
  networks: ["cm-test-nat", "cm-test-iso"], hostname: "cm-check-host",
  ssh_keys: [$key], user_data: $ud}')"
expect 201 "[1] POST /vms creates and starts VM cm-test-vm1"

api GET /quota
FREE_MEM="$(jq '.limits.memory_mb - .used.memory_mb' <<<"$BODY")"
api POST /vms "$(jq -n --argjson m "$((FREE_MEM + 256))" '{name: "cm-test-big", image: "cm-test-ubuntu", memory_mb: $m, networks: ["cm-test-nat"]}')"
expect 409 "[9] quota counts existing VMs (requested more memory than is left)"

if IP1="$(wait_ip cm-test-vm1 '^10\.77\.' 150)"; then
  pass "[1] VM got an address in network cm-test-nat: $IP1"
  if wait_ssh "cloud@$IP1"; then
    pass "[2] SSH login with the key passed through the API"
    [ "$(ssh_vm "cloud@$IP1" hostname)" = cm-check-host ] \
      && pass "[2] hostname from the API: cm-check-host" || fail "[2] hostname does not match"
    [ "$(ssh_vm "cloud@$IP1" cat /etc/cloudmaker-test 2>/dev/null)" = "hello from user_data" ] \
      && pass "[2] user_data applied (write_files)" || fail "[2] file from user_data not found"
    ISO_OK=0
    for _ in $(seq 1 10); do
      ssh_vm "cloud@$IP1" ip -4 -o addr | grep -q ' 10\.78\.' && { ISO_OK=1; break; }
      sleep 3
    done
    [ "$ISO_OK" = 1 ] && pass "[3] second VM interface got an address in isolated network cm-test-iso" \
      || fail "[3] no address in cm-test-iso"
  else
    fail "[2] no SSH access to cm-test-vm1"
  fi
else
  fail "[1] VM did not get an IP" "$BODY"
fi
"${VIRSH[@]}" list --name | grep -qx cm-test-vm1 \
  && pass "[5] VM created from the container is visible on the host: virsh list" || fail "[5] VM is not visible in virsh list"

# ---------------------------------------------------------------------------
section "Item 1: stop and start"
api POST /vms/cm-test-vm1/stop
expect 200 "[1] POST /vms/cm-test-vm1/stop (ACPI shutdown)"
wait_state cm-test-vm1 "shut off" 120 && pass "[1] VM is shut off" || fail "[1] VM did not shut off within 120 s"
api POST /vms/cm-test-vm1/start
expect 200 "[1] POST /vms/cm-test-vm1/start"
wait_state cm-test-vm1 running 30 && pass "[1] VM is running again" || fail "[1] VM did not start"

# ---------------------------------------------------------------------------
section "Item 6: state recovery"
docker compose restart >/dev/null 2>&1
wait_health || fail "[6] API did not come back after restart"
api GET /vms/cm-test-vm1
[ "$(jq -r '.state' <<<"$BODY" 2>/dev/null)" = running ] \
  && pass "[6] after a container restart the VM is still known and running" || fail "[6] VM lost after restart" "$BODY"
api GET /networks/cm-test-nat
[ "$CODE" = 200 ] \
  && pass "[6] networks and images are preserved (DB on a host volume)" || fail "[6] network lost" "$BODY"

echo "  simulated failure: service stopped, VM powered off and its domain removed from libvirt"
docker compose stop >/dev/null 2>&1
"${VIRSH[@]}" destroy cm-test-vm1 >/dev/null 2>&1
"${VIRSH[@]}" undefine cm-test-vm1 >/dev/null 2>&1
"${VIRSH[@]}" list --all --name | grep -qx cm-test-vm1 && fail "[6] could not remove the domain to simulate a failure"
docker compose start >/dev/null 2>&1
wait_health || fail "[6] API did not come up"
if wait_state cm-test-vm1 running 60; then
  api GET /health
  pass "[6] on start the service redefined and started the VM: $(jq -c '.restore' <<<"$BODY")"
  if IP1="$(wait_ip cm-test-vm1 '^10\.77\.' 150)" && wait_ssh "cloud@$IP1" \
     && [ "$(ssh_vm "cloud@$IP1" cat /etc/cloudmaker-test 2>/dev/null)" = "hello from user_data" ]; then
    pass "[6] recovered VM works with its original disk ($IP1)"
  else
    fail "[6] recovered VM is not reachable over SSH"
  fi
else
  fail "[6] VM was not recovered" "$(docker compose logs --tail 20 2>&1)"
fi

# ---------------------------------------------------------------------------
section "Item 3: bridge to the host network ($BRIDGE)"
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  sudo iptables -C DOCKER-USER -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null \
    || sudo iptables -I DOCKER-USER -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT
  HOST_CIDR="$(ip -4 -o addr show "$BRIDGE" | awk '{ print $4; exit }')"
  HOST_RE="^$(cut -d. -f1-3 <<<"${HOST_CIDR%/*}" | sed 's/\./\\./g')\\."
  echo "  host address on $BRIDGE: $HOST_CIDR"
  api POST /networks "$(jq -n --arg br "$BRIDGE" '{name: "cm-test-lan", mode: "bridge", bridge: $br}')"
  expect 201 "[3] created network cm-test-lan on top of bridge $BRIDGE"
  api POST /vms "$(jq -n --arg key "$PUBKEY" '{name: "cm-test-br", image: "cm-test-ubuntu", networks: ["cm-test-lan"], ssh_keys: [$key]}')"
  expect 201 "[3] created VM cm-test-br in network cm-test-lan"
  sleep 3
  ip -br link show master "$BRIDGE" | grep -q '^vnet' \
    && pass "[3] VM interface is attached to bridge $BRIDGE" || fail "[3] VM interface is not in $BRIDGE"
  echo "  waiting for an address from the host network DHCP (via the guest agent, up to 5 minutes)..."
  if IPB="$(wait_ip cm-test-br "$HOST_RE" 300)"; then
    pass "[3] VM got an address in the host network: $IPB"
    wait_ssh "cloud@$IPB" && pass "[3] SSH to the VM at its host-network address" || fail "[3] no SSH to $IPB"
  else
    fail "[3] VM did not get an address in the host network"
  fi
else
  skip "[3] bridge $BRIDGE not found — create it with: scripts/setup-bridge.sh <wired interface>"
fi

# ---------------------------------------------------------------------------
section "Item 1: delete"
for vm in cm-test-vm1 cm-test-br; do
  api GET "/vms/$vm"
  [ "$CODE" = 200 ] || continue
  api DELETE "/vms/$vm"
  expect 204 "[1] DELETE /vms/$vm"
  "${VIRSH[@]}" list --all --name | grep -qx "$vm" && fail "[1] $vm is still in libvirt" || pass "[1] $vm removed from libvirt"
  [ -e "$VM_DIR/$vm" ] && fail "[1] disk of $vm is still there" || pass "[1] disk and cloud-init ISO of $vm deleted"
done
for net in cm-test-nat cm-test-iso cm-test-lan; do
  api GET "/networks/$net"
  [ "$CODE" = 200 ] || continue
  api DELETE "/networks/$net"
  expect 204 "[3] DELETE /networks/$net"
done
api DELETE /images/cm-test-ubuntu
expect 204 "[7] DELETE /images/cm-test-ubuntu"

# ---------------------------------------------------------------------------
section "Summary"
printf '  %s\n' "${SUMMARY[@]}"
echo
echo "  PASS: $PASSED   FAIL: $FAILED   SKIP: $SKIPPED"
echo "  The service is left running: $API/docs ; full cleanup: scripts/cleanup.sh"
[ "$FAILED" -eq 0 ]
