# Base task: running a VM without a GUI

Host: Ubuntu 24.04, Intel CPU with VT-x, QEMU/KVM hypervisor managed through libvirt.
Everything is done from the command line; the same steps are automated in `scripts/manual-vm.sh`.

## 1. Check hardware virtualization

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo   # > 0
ls -l /dev/kvm                       # the KVM device exists
```

## 2. Install QEMU/KVM and libvirt

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst
sudo usermod -aG kvm,libvirt $USER   # then log out and back in
virsh -c qemu:///system list --all   # an empty list means the hypervisor is reachable
```

`qemu:///system` is the system libvirtd instance (VMs run as `libvirt-qemu` and can use the
`default` network with NAT and DHCP: 192.168.122.0/24).

## 3. Image and disk

No OS installation from an ISO is needed: an Ubuntu cloud image (qcow2) already contains cloud-init.

```bash
sudo wget -O /var/lib/libvirt/images/noble-base.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/noble-base.img /var/lib/libvirt/images/test1.qcow2 10G
```

The VM disk is an overlay on top of the base image: writes go to `test1.qcow2`,
the base image is not modified.

## 4. Configuration with cloud-init

On first boot the cloud image looks for a cloud-init datasource. `virt-install --cloud-init`
builds an ISO labelled `cidata` (NoCloud datasource) from a `user-data` file:

```yaml
#cloud-config
hostname: test1
users:
  - name: student
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: student
ssh_pwauth: true
```

## 5. Create and start the VM

```bash
virt-install --connect qemu:///system \
  --name test1 --memory 2048 --vcpus 2 \
  --disk /var/lib/libvirt/images/test1.qcow2 --import \
  --os-variant ubuntu24.04 \
  --network network=default \
  --cloud-init user-data=$HOME/user-data.yaml \
  --graphics none --noautoconsole
```

* `--import` — do not install an OS, boot from the existing disk;
* `--graphics none` — no graphical console, serial console only;
* `--noautoconsole` — do not attach to the console, return immediately.

virt-install generates the domain XML, registers it in libvirt (`virsh define`) and starts it
(`virsh start`). The VM process itself is `qemu-system-x86_64` with `-accel kvm`.

## 6. Check

```bash
virsh -c qemu:///system list --all          # test1   running
virsh -c qemu:///system domifaddr test1     # 192.168.122.252/24 (DHCP lease in network default)
ssh student@192.168.122.252                 # password: student
hostname && whoami && sudo whoami           # test1 / student / root — cloud-init worked
virsh -c qemu:///system console test1       # serial console, exit with Ctrl+]
```

## 7. Manage and delete

```bash
virsh -c qemu:///system shutdown test1      # ACPI shutdown
virsh -c qemu:///system start test1
virsh -c qemu:///system destroy test1       # pull the plug
virsh -c qemu:///system undefine test1 --remove-all-storage
```

## The same with one command

```bash
scripts/manual-vm.sh create cm-manual    # downloads the image if needed
scripts/manual-vm.sh ip cm-manual
scripts/manual-vm.sh delete cm-manual
```

The script creates the disk in libvirt's `default` pool
(`--disk size=10,backing_store=noble-base.img`), so it does not need `sudo`.
