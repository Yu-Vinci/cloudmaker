`cloudmaker` is a lightweight single-host cloud: an HTTP API for creating, starting, stopping and deleting QEMU/KVM virtual machines. It runs in a Docker container and talks to the host's libvirtd, so every VM it manages is also visible in `virsh`.

### Implemented Items
Numbering follows the assignment.

* **Base task**: a headless VM created with `virt-install` and cloud-init, documented in [docs/manual-vm.md](docs/manual-vm.md).
* **1. HTTP API** for creating, starting, stopping and deleting VMs.
* **2. cloud-init**: user_data, SSH keys, hostname, username and password are passed through the API.
* **3. Networks**: NAT and isolated libvirt networks, plus a `bridge` network that connects VMs directly to the host network through `br0`.
* **5. Containerized app managing host VMs** through the host's libvirt socket; the VMs are visible in `virsh list`.
* **6. State recovery**: VMs are stored in SQLite; after a container or host restart, VM definitions missing from libvirt are recreated and VMs that should be running are started.
* **7. Image registration** with a name, path and description.
* **9. Quotas** on total vCPU, RAM and disk across all VMs.
* **11. One check script**: `scripts/check.sh`.
* **12. Cleanup script**: `scripts/cleanup.sh`.

Items 4, 8 and 10 are not implemented.

### How to Check
Requires Ubuntu 24.04 x86_64 with `/dev/kvm`.

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst docker.io docker-compose-v2 jq curl git
sudo usermod -aG kvm,libvirt,docker $USER
```

Log out and back in so the new groups take effect, then:

```bash
git clone https://github.com/Yu-Vinci/cloudmaker.git && cd cloudmaker
scripts/setup-bridge.sh enp0s31f6   # optional, for the bridge part of item 3
scripts/check.sh
scripts/cleanup.sh
```

Replace `enp0s31f6` with the name of your wired interface (`ip -br link`).

`check.sh` downloads the Ubuntu 24.04 cloud image (~600 MB), starts the service with `docker compose`, tests every item and ends with a `PASS / FAIL / SKIP` table. All lines should be `PASS`; the bridge test is `SKIP` if there is no `br0`. A full run takes 5–10 minutes.

### API
The service listens on `127.0.0.1:8000`, interactive docs are at `/docs`.

* `GET|POST /images`, `GET|DELETE /images/{name}`
* `GET|POST /networks` (`mode`: `nat`, `isolated` or `bridge`), `GET|DELETE /networks/{name}`
* `GET|POST /vms`, `GET|DELETE /vms/{name}`, `POST /vms/{name}/start|stop`
* `GET /quota`, `GET /health`

```bash
curl -X POST localhost:8000/vms -H 'Content-Type: application/json' -d '{
  "name": "web1", "image": "ubuntu", "vcpus": 2, "memory_mb": 2048,
  "networks": ["default"], "ssh_keys": ["ssh-ed25519 AAAA..."]
}'
```

Quota limits default to 8 vCPU / 8192 MB / 100 GB and are set with `QUOTA_VCPUS`, `QUOTA_MEMORY_MB` and `QUOTA_DISK_GB`.
