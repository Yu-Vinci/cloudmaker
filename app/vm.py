import ipaddress
import json
import os
import shutil
import subprocess
import tempfile

import libvirt
import yaml

LIBVIRT_URI = os.environ.get("LIBVIRT_URI", "qemu:///system")
DOMAIN_TYPE = os.environ.get("DOMAIN_TYPE", "kvm")
VM_DIR = "/var/lib/libvirt/images/cloudmaker"

_conn = None


def conn():
    global _conn
    if _conn is None or not _conn.isAlive():
        _conn = libvirt.open(LIBVIRT_URI)
    return _conn


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result.stdout


def image_format(path):
    info = json.loads(run(["qemu-img", "info", "-U", "--output=json", path]))
    return info["format"]


def create_disk(name, image_path, image_fmt, size_gb):
    os.makedirs(f"{VM_DIR}/{name}", exist_ok=True)
    run(["qemu-img", "create", "-f", "qcow2", "-F", image_fmt, "-b", image_path,
         f"{VM_DIR}/{name}/disk.qcow2", f"{size_gb}G"])


def create_seed_iso(name, hostname, username, ssh_keys, password, user_data):
    user = {"name": username, "sudo": "ALL=(ALL) NOPASSWD:ALL", "shell": "/bin/bash"}
    if ssh_keys:
        user["ssh_authorized_keys"] = ssh_keys
    if password:
        user["lock_passwd"] = False
        user["plain_text_passwd"] = password

    config = {
        "hostname": hostname,
        "users": [user],
        "ssh_pwauth": bool(password),
        "packages": ["qemu-guest-agent"],
        "runcmd": ["systemctl start qemu-guest-agent"],
    }
    if user_data:
        extra = yaml.safe_load(user_data) or {}
        if not isinstance(extra, dict):
            raise ValueError("user_data must be a cloud-config dictionary")
        config.update(extra)

    network = {"version": 2, "ethernets": {"all": {"match": {"name": "en*"}, "dhcp4": True}}}
    files = {
        "user-data": "#cloud-config\n" + yaml.safe_dump(config),
        "meta-data": f"instance-id: {name}\nlocal-hostname: {hostname}\n",
        "network-config": yaml.safe_dump(network),
    }
    with tempfile.TemporaryDirectory() as tmp:
        for filename, content in files.items():
            with open(f"{tmp}/{filename}", "w") as f:
                f.write(content)
        run(["genisoimage", "-output", f"{VM_DIR}/{name}/seed.iso", "-volid", "cidata",
             "-joliet", "-rock", f"{tmp}/user-data", f"{tmp}/meta-data", f"{tmp}/network-config"])


def domain_xml(name, vcpus, memory_mb, networks):
    interfaces = ""
    for net in networks:
        interfaces += f"""
    <interface type='network'>
      <source network='{net}'/>
      <model type='virtio'/>
    </interface>"""

    return f"""<domain type='{DOMAIN_TYPE}'>
  <name>{name}</name>
  <memory unit='MiB'>{memory_mb}</memory>
  <vcpu>{vcpus}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='{VM_DIR}/{name}/disk.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='{VM_DIR}/{name}/seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>{interfaces}
    <serial type='pty'/>
    <console type='pty'/>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
  </devices>
</domain>"""


def find_domain(name):
    try:
        return conn().lookupByName(name)
    except libvirt.libvirtError:
        return None


def define_vm(name, vcpus, memory_mb, networks):
    return conn().defineXML(domain_xml(name, vcpus, memory_mb, networks))


def delete_vm(name):
    dom = find_domain(name)
    if dom:
        if dom.isActive():
            dom.destroy()
        dom.undefine()
    shutil.rmtree(f"{VM_DIR}/{name}", ignore_errors=True)


def get_ips(dom):
    if not dom.isActive():
        return []
    ips = []
    sources = [libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT]
    for source in sources:
        try:
            interfaces = dom.interfaceAddresses(source)
        except libvirt.libvirtError:
            continue
        for iface in interfaces.values():
            for addr in iface["addrs"] or []:
                ip = addr["addr"]
                if addr["type"] == libvirt.VIR_IP_ADDR_TYPE_IPV4 and not ip.startswith("127.") and ip not in ips:
                    ips.append(ip)
    return ips


def network_xml(name, mode, subnet, bridge):
    if mode == "bridge":
        return f"<network><name>{name}</name><forward mode='bridge'/><bridge name='{bridge}'/></network>"

    net = ipaddress.ip_network(subnet)
    hosts = list(net.hosts())
    forward = "<forward mode='nat'/>" if mode == "nat" else ""
    return f"""<network>
  <name>{name}</name>
  {forward}
  <ip address='{hosts[0]}' netmask='{net.netmask}'>
    <dhcp>
      <range start='{hosts[1]}' end='{hosts[-1]}'/>
    </dhcp>
  </ip>
</network>"""


def network_exists(name):
    try:
        conn().networkLookupByName(name)
        return True
    except libvirt.libvirtError:
        return False


def create_network(name, mode, subnet, bridge):
    net = conn().networkDefineXML(network_xml(name, mode, subnet, bridge))
    net.setAutostart(1)
    net.create()


def delete_network(name):
    net = conn().networkLookupByName(name)
    if net.isActive():
        net.destroy()
    net.undefine()
