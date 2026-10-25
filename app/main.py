import ipaddress
import os
import re
import sqlite3
from typing import List, Optional

import libvirt
import yaml
from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from . import vm

DB_PATH = os.environ.get("DB_PATH", "/var/lib/cloudmaker/cloudmaker.db")
QUOTA = {
    "vcpus": int(os.environ.get("QUOTA_VCPUS", "8")),
    "memory_mb": int(os.environ.get("QUOTA_MEMORY_MB", "8192")),
    "disk_gb": int(os.environ.get("QUOTA_DISK_GB", "100")),
}
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")

app = FastAPI(title="CloudMaker")
restore_log = []


class ImageIn(BaseModel):
    name: str
    path: str
    description: str = ""


class NetworkIn(BaseModel):
    name: str
    mode: str = "nat"
    subnet: Optional[str] = None
    bridge: Optional[str] = None


class VmIn(BaseModel):
    name: str
    image: str
    vcpus: int = 1
    memory_mb: int = 1024
    disk_gb: int = 10
    networks: List[str] = ["default"]
    hostname: Optional[str] = None
    username: str = "cloud"
    ssh_keys: List[str] = []
    password: Optional[str] = None
    user_data: Optional[str] = None


def db(sql, args=()):
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        rows = [dict(row) for row in con.execute(sql, args)]
        con.commit()
        return rows
    finally:
        con.close()


def check_name(name):
    if not NAME_RE.match(name):
        raise HTTPException(422, f"invalid name '{name}': use a-z, 0-9 and '-'")


def restore_vms():
    restore_log.clear()
    for row in db("SELECT * FROM vms"):
        name = row["name"]
        try:
            dom = vm.find_domain(name)
            if dom is None:
                dom = vm.define_vm(name, row["vcpus"], row["memory_mb"], row["networks"].split(","))
                restore_log.append(f"{name}: redefined")
            if row["state"] == "running" and not dom.isActive():
                dom.create()
                restore_log.append(f"{name}: started")
        except libvirt.libvirtError as e:
            restore_log.append(f"{name}: error {e}")


@app.on_event("startup")
def startup():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db("CREATE TABLE IF NOT EXISTS images (name TEXT PRIMARY KEY, path TEXT, format TEXT, description TEXT)")
    db("CREATE TABLE IF NOT EXISTS networks (name TEXT PRIMARY KEY, mode TEXT, subnet TEXT, bridge TEXT)")
    db("CREATE TABLE IF NOT EXISTS vms (name TEXT PRIMARY KEY, image TEXT, vcpus INTEGER, memory_mb INTEGER, "
       "disk_gb INTEGER, networks TEXT, hostname TEXT, username TEXT, state TEXT)")
    restore_vms()


@app.exception_handler(libvirt.libvirtError)
async def libvirt_error(request, exc):
    return JSONResponse(status_code=500, content={"detail": f"libvirt: {exc}"})


@app.get("/health")
def health():
    return {"status": "ok", "restore": restore_log}


def used_resources():
    return db("SELECT COUNT(*) AS vms, COALESCE(SUM(vcpus), 0) AS vcpus, COALESCE(SUM(memory_mb), 0) AS memory_mb, "
              "COALESCE(SUM(disk_gb), 0) AS disk_gb FROM vms")[0]


@app.get("/quota")
def get_quota():
    return {"limits": QUOTA, "used": used_resources()}


@app.get("/images")
def list_images():
    return db("SELECT * FROM images")


@app.get("/images/{name}")
def get_image(name: str):
    rows = db("SELECT * FROM images WHERE name = ?", (name,))
    if not rows:
        raise HTTPException(404, f"image '{name}' not found")
    return rows[0]


@app.post("/images", status_code=201)
def add_image(image: ImageIn):
    check_name(image.name)
    path = os.path.realpath(image.path)
    if not path.startswith("/var/lib/libvirt/images/") or not os.path.isfile(path):
        raise HTTPException(422, "image must be an existing file in /var/lib/libvirt/images")
    if db("SELECT name FROM images WHERE name = ?", (image.name,)):
        raise HTTPException(409, f"image '{image.name}' already exists")
    fmt = vm.image_format(path)
    db("INSERT INTO images VALUES (?, ?, ?, ?)", (image.name, path, fmt, image.description))
    return get_image(image.name)


@app.delete("/images/{name}", status_code=204)
def delete_image(name: str):
    get_image(name)
    db("DELETE FROM images WHERE name = ?", (name,))
    return Response(status_code=204)


@app.get("/networks")
def list_networks():
    return db("SELECT * FROM networks")


@app.get("/networks/{name}")
def get_network(name: str):
    rows = db("SELECT * FROM networks WHERE name = ?", (name,))
    if not rows:
        raise HTTPException(404, f"network '{name}' not found")
    return rows[0]


@app.post("/networks", status_code=201)
def add_network(net: NetworkIn):
    check_name(net.name)
    if vm.network_exists(net.name):
        raise HTTPException(409, f"network '{net.name}' already exists")
    if net.mode in ("nat", "isolated"):
        try:
            subnet = ipaddress.ip_network(net.subnet)
        except ValueError:
            raise HTTPException(422, "subnet must look like 10.0.0.0/24")
        if subnet.version != 4 or not 16 <= subnet.prefixlen <= 29:
            raise HTTPException(422, "subnet must be IPv4 between /16 and /29")
    elif net.mode == "bridge":
        if not net.bridge or not NAME_RE.match(net.bridge):
            raise HTTPException(422, "bridge must be the name of a host bridge, e.g. br0")
    else:
        raise HTTPException(422, "mode must be nat, isolated or bridge")

    vm.create_network(net.name, net.mode, net.subnet, net.bridge)
    db("INSERT INTO networks VALUES (?, ?, ?, ?)", (net.name, net.mode, net.subnet, net.bridge))
    return get_network(net.name)


@app.delete("/networks/{name}", status_code=204)
def delete_network(name: str):
    get_network(name)
    if vm.network_exists(name):
        vm.delete_network(name)
    db("DELETE FROM networks WHERE name = ?", (name,))
    return Response(status_code=204)


def get_row(name):
    rows = db("SELECT * FROM vms WHERE name = ?", (name,))
    if not rows:
        raise HTTPException(404, f"vm '{name}' not found")
    return rows[0]


def vm_info(row):
    dom = vm.find_domain(row["name"])
    info = dict(row)
    info["networks"] = row["networks"].split(",")
    info["desired_state"] = row["state"]
    if dom is None:
        info["state"] = "missing"
        info["ips"] = []
    else:
        info["state"] = "running" if dom.isActive() else "stopped"
        info["ips"] = vm.get_ips(dom)
    return info


@app.get("/vms")
def list_vms():
    return [vm_info(row) for row in db("SELECT * FROM vms")]


@app.get("/vms/{name}")
def get_vm(name: str):
    return vm_info(get_row(name))


@app.post("/vms", status_code=201)
def create_vm(req: VmIn):
    check_name(req.name)
    hostname = req.hostname or req.name
    check_name(hostname)
    if req.vcpus < 1 or req.memory_mb < 256 or req.disk_gb < 5:
        raise HTTPException(422, "need vcpus >= 1, memory_mb >= 256, disk_gb >= 5")
    if db("SELECT name FROM vms WHERE name = ?", (req.name,)) or vm.find_domain(req.name):
        raise HTTPException(409, f"vm '{req.name}' already exists")
    images = db("SELECT * FROM images WHERE name = ?", (req.image,))
    if not images:
        raise HTTPException(422, f"unknown image '{req.image}'")
    for net in req.networks:
        if not vm.network_exists(net):
            raise HTTPException(422, f"unknown network '{net}'")

    used = used_resources()
    for key, value in [("vcpus", req.vcpus), ("memory_mb", req.memory_mb), ("disk_gb", req.disk_gb)]:
        if used[key] + value > QUOTA[key]:
            raise HTTPException(409, f"quota exceeded: {key} {used[key]} + {value} > {QUOTA[key]}")

    try:
        vm.create_disk(req.name, images[0]["path"], images[0]["format"], req.disk_gb)
        vm.create_seed_iso(req.name, hostname, req.username, req.ssh_keys, req.password, req.user_data)
        dom = vm.define_vm(req.name, req.vcpus, req.memory_mb, req.networks)
        dom.create()
    except (ValueError, yaml.YAMLError) as e:
        vm.delete_vm(req.name)
        raise HTTPException(422, f"bad user_data: {e}")
    except Exception:
        vm.delete_vm(req.name)
        raise

    db("INSERT INTO vms VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
       (req.name, req.image, req.vcpus, req.memory_mb, req.disk_gb, ",".join(req.networks),
        hostname, req.username, "running"))
    return get_vm(req.name)


@app.post("/vms/{name}/start")
def start_vm(name: str):
    get_row(name)
    dom = vm.find_domain(name)
    if dom is None:
        raise HTTPException(409, "domain is missing, restart the service to restore it")
    if not dom.isActive():
        dom.create()
    db("UPDATE vms SET state = 'running' WHERE name = ?", (name,))
    return get_vm(name)


@app.post("/vms/{name}/stop")
def stop_vm(name: str, force: bool = False):
    get_row(name)
    dom = vm.find_domain(name)
    if dom is not None and dom.isActive():
        if force:
            dom.destroy()
        else:
            dom.shutdown()
    db("UPDATE vms SET state = 'stopped' WHERE name = ?", (name,))
    return get_vm(name)


@app.delete("/vms/{name}", status_code=204)
def delete_vm(name: str):
    get_row(name)
    vm.delete_vm(name)
    db("DELETE FROM vms WHERE name = ?", (name,))
    return Response(status_code=204)
