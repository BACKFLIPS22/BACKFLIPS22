#!/usr/bin/env python3
"""pvedash collector: gathers Proxmox host, guest, sensor, disk and backup stats
and writes them atomically to stats.json. Runs as root, and only reads: it never
changes guests, storage or backups. Everything is detected at runtime, and
anything this server doesn't have is simply left out."""
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time

OUT_DIR = os.environ.get("RUNTIME_DIRECTORY", "/run/pvedash")
OUT_FILE = os.path.join(OUT_DIR, "stats.json")
INTERVAL = 10
NODE = socket.gethostname().split(".")[0]
IFACE = os.environ.get("PVEDASH_IFACE", "vmbr0")

# How often (seconds) to refresh the slower data sources.
SLOW = {"storage": 60, "backups": 60, "zfs": 60, "backup_content": 300, "smart": 300, "version": 3600}

CPU_CHIPS = ("coretemp", "k10temp", "zenpower", "cpu_thermal")
DRIVE_CHIPS = ("drivetemp", "nvme")
SKIP_DISKS = ("loop", "ram", "zram", "zd", "dm-", "sr", "md", "nbd", "rbd", "fd", "drbd")


def run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def pvesh(path, *args, timeout=30):
    try:
        return json.loads(run(["pvesh", "get", path, "--output-format", "json", *args], timeout=timeout))
    except Exception:
        return None


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return default


def natural(s):
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", s)]


# ---------- host ----------

def cpu_times():
    vals = list(map(int, read("/proc/stat").splitlines()[0].split()[1:]))
    return sum(vals), vals[3] + vals[4], vals[4]  # total, idle + iowait, iowait


def meminfo():
    m = {}
    for line in read("/proc/meminfo").splitlines():
        k, v = line.split(":", 1)
        m[k] = int(v.split()[0]) * 1024
    return m


def host_net():
    base = f"/sys/class/net/{IFACE}/statistics/"
    try:
        return int(read(base + "rx_bytes")), int(read(base + "tx_bytes"))
    except ValueError:
        return 0, 0


def cpu_model():
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            return line.split(":", 1)[1].strip()
    return ""


# ---------- temperatures (read from the kernel, so lm-sensors isn't needed) ----------

def milli(path):
    try:
        v = int(read(path).strip()) / 1000
    except ValueError:
        return None
    return v if v > 0 else None


def read_temps(root="/sys/class/hwmon"):
    """Returns (cpu readings, other readings, {block device: temperature})."""
    cpus, other, drives = [], [], {}
    sockets = 0
    for hw in sorted(glob.glob(f"{root}/hwmon*"), key=natural):
        chip = read(f"{hw}/name").strip()
        sock = None
        if chip in CPU_CHIPS:
            m = re.search(r"coretemp\.(\d+)$", os.path.realpath(f"{hw}/device"))
            sock = int(m.group(1)) if m else sockets
            sockets += 1
        for inp in sorted(glob.glob(f"{hw}/temp*_input"), key=natural):
            base = inp[: -len("_input")]
            temp = milli(inp)
            if temp is None or temp >= 200:
                continue
            label = read(f"{base}_label").strip() or os.path.basename(base)
            entry = {"label": label, "temp": temp, "high": milli(f"{base}_max") or milli(f"{base}_crit")}
            if chip in CPU_CHIPS:
                cpus.append({**entry, "socket": sock})
            elif chip == "drivetemp":
                for dev in glob.glob(f"{hw}/device/block/*"):
                    drives[os.path.basename(dev)] = temp
            elif chip not in DRIVE_CHIPS:
                other.append({**entry, "label": f"{chip} {label}"})
    return cpus, other, drives


def nvme_temp(dev, sys_block="/sys/block"):
    # Where the sensor sits depends on the kernel version.
    for pat in ("device/hwmon*/temp1_input", "device/hwmon/hwmon*/temp1_input", "device/device/hwmon/hwmon*/temp1_input"):
        for path in glob.glob(f"{sys_block}/{dev}/{pat}"):
            temp = milli(path)
            if temp is not None:
                return temp
    return None


# ---------- disks ----------

def list_disks(sys_block="/sys/block"):
    disks = []
    for dev in sorted(os.listdir(sys_block), key=natural):
        if dev.startswith(SKIP_DISKS):
            continue
        try:
            size = int(read(f"{sys_block}/{dev}/size", "0").strip()) * 512
        except ValueError:
            size = 0
        if size:
            disks.append({"dev": dev, "size": size, "model": read(f"{sys_block}/{dev}/device/model").strip(),
                          "rotational": read(f"{sys_block}/{dev}/queue/rotational").strip() == "1",
                          "nvme": dev.startswith("nvme"), "standby": False, "passed": None, "temp": None,
                          "power_on_hours": None, "reallocated": None, "pending": None, "wear_used_pct": None})
    return disks


def smart_info(disk):
    try:
        d = json.loads(run(["smartctl", "-j", "-n", "standby", "-a", f"/dev/{disk['dev']}"], timeout=30))
    except Exception:
        return disk
    attrs = {a["name"]: a.get("raw", {}).get("value") for a in d.get("ata_smart_attributes", {}).get("table", [])}
    nvme = d.get("nvme_smart_health_information_log", {})
    realloc = attrs.get("Reallocated_Sector_Ct")
    if realloc is None:
        realloc = d.get("scsi_grown_defect_list", nvme.get("media_errors"))
    disk.update(
        model=d.get("model_name") or d.get("scsi_model_name") or disk["model"],
        standby="standby" in json.dumps(d.get("smartctl", {}).get("messages", [])).lower(),
        passed=d.get("smart_status", {}).get("passed"),
        temp=d.get("temperature", {}).get("current"),
        power_on_hours=d.get("power_on_time", {}).get("hours"),
        reallocated=realloc,
        pending=attrs.get("Current_Pending_Sector"),
        wear_used_pct=nvme.get("percentage_used"),
    )
    return disk


def disks_info():
    disks = list_disks()
    if shutil.which("smartctl"):
        disks = [smart_info(d) for d in disks]
    return disks


def zfs_pools():
    if not shutil.which("zpool"):
        return []
    pools = []
    for line in run(["zpool", "list", "-Hp", "-o", "name,size,alloc,health,frag,cap"]).splitlines():
        f = line.split("\t")
        if len(f) != 6:
            continue
        status = run(["zpool", "status", f[0]])
        scan = re.search(r"^\s*scan:\s*(.+)$", status, re.M)
        pools.append({"name": f[0], "size": int(f[1]), "alloc": int(f[2]), "health": f[3],
                      "frag": f[4], "cap": f[5], "scan": scan.group(1).strip() if scan else None})
    return pools


# ---------- storage and backups ----------

def storage_info():
    out = []
    for s in pvesh(f"/nodes/{NODE}/storage", timeout=60) or []:
        out.append({"storage": s.get("storage"), "type": s.get("type"), "active": bool(s.get("active")),
                    "enabled": bool(s.get("enabled", 1)), "content": s.get("content", ""),
                    "total": s.get("total", 0), "used": s.get("used", 0)})
    return sorted(out, key=lambda s: s["storage"] or "")


def backups():
    jobs = []
    for j in pvesh("/cluster/backup") or []:
        if j.get("node") not in (None, NODE):
            continue
        jobs.append({
            "id": j.get("id"),
            "schedule": j.get("schedule") or f"{j.get('dow', '')} {j.get('starttime', '')}".strip(),
            "storage": j.get("storage"),
            "enabled": bool(int(j.get("enabled", 1))),
            "next_run": j.get("next-run"),
            "selection": "all guests" if j.get("all") else (j.get("vmid") or j.get("pool") or ""),
        })
    tasks = []
    for t in pvesh(f"/nodes/{NODE}/tasks", "--typefilter", "vzdump", "--limit", "50") or []:
        status = t.get("status")
        tasks.append({"start": t.get("starttime"), "end": t.get("endtime"), "status": status or "running",
                      "ok": status == "OK" or (status or "").startswith("WARNINGS"), "vmid": t.get("id") or ""})
    tasks.sort(key=lambda t: t["start"] or 0, reverse=True)
    return {"jobs": jobs, "tasks": tasks[:15], "last_success": next((t for t in tasks if t["ok"]), None),
            "tasks_scanned": len(tasks)}


def backup_content(storages):
    """Newest backup per guest across active storages that hold backups."""
    latest = {}
    for s in storages:
        if not s.get("active") or "backup" not in s.get("content", ""):
            continue
        for it in pvesh(f"/nodes/{NODE}/storage/{s['storage']}/content", "--content", "backup", timeout=60) or []:
            vmid = str(it.get("vmid", ""))
            if vmid and (vmid not in latest or it.get("ctime", 0) > latest[vmid]["ctime"]):
                latest[vmid] = {"ctime": it.get("ctime", 0), "storage": s["storage"], "size": it.get("size")}
    return latest


# ---------- background refresh of the slow sources ----------

state = {"storage": [], "backups": None, "backup_content": None, "disks": [], "zfs": [], "version": ""}


def refresh(key, fn):
    try:
        state[key] = fn()
    except Exception as e:
        print(f"refreshing {key} failed: {e}", flush=True)


def slow_loop():
    # A hung network storage can block pvesh for a long time, so none of this runs
    # on the main loop, and the host and guest figures keep updating regardless.
    last = {k: 0 for k in SLOW}
    jobs = (("version", "version", lambda: run(["pveversion"]).strip()),
            ("storage", "storage", storage_info),
            ("backups", "backups", backups),
            ("backup_content", "backup_content", lambda: backup_content(state["storage"])),
            ("smart", "disks", disks_info),
            ("zfs", "zfs", zfs_pools))
    while True:
        for name, key, fn in jobs:
            if time.time() - last[name] > SLOW[name]:
                refresh(key, fn)
                last[name] = time.time()
        time.sleep(2)


# ---------- main loop ----------

def collect(prev):
    now = time.time()
    dt = max(now - prev["t"], 0.001)

    cur_cpu = cpu_times()
    dtot = cur_cpu[0] - prev["cpu"][0] or 1
    cpu_pct = 100 * (1 - (cur_cpu[1] - prev["cpu"][1]) / dtot)
    iowait_pct = 100 * (cur_cpu[2] - prev["cpu"][2]) / dtot

    m = meminfo()
    st = os.statvfs("/")
    rx, tx = host_net()
    host = {
        "node": NODE,
        "pveversion": state["version"],
        "kernel": os.uname().release,
        "cpu_model": prev["model"],
        "cpus": os.cpu_count(),
        "uptime": float(read("/proc/uptime", "0").split()[0]),
        "loadavg": [float(x) for x in read("/proc/loadavg").split()[:3]],
        "cpu_pct": round(cpu_pct, 1),
        "iowait_pct": round(iowait_pct, 1),
        "mem_total": m.get("MemTotal", 0),
        "mem_used": m.get("MemTotal", 0) - m.get("MemAvailable", 0),
        "swap_total": m.get("SwapTotal", 0),
        "swap_used": m.get("SwapTotal", 0) - m.get("SwapFree", 0),
        "rootfs_total": st.f_blocks * st.f_frsize,
        "rootfs_used": (st.f_blocks - st.f_bfree) * st.f_frsize,
        "net": {"iface": IFACE, "rx_rate": (rx - prev["net"][0]) / dt, "tx_rate": (tx - prev["net"][1]) / dt},
    }

    # guests on this node (in a cluster, each node runs its own dashboard), with I/O rates from deltas
    guests = []
    for g in pvesh("/cluster/resources", "--type", "vm") or []:
        if g.get("template") or g.get("node") != NODE:
            continue
        p = prev["guests"].get(g["id"])
        rates = {}
        for f in ("netin", "netout", "diskread", "diskwrite"):
            cur = g.get(f, 0) or 0
            rates[f + "_rate"] = max((cur - p[f]) / dt, 0) if p and cur >= p[f] else None
        prev["guests"][g["id"]] = {f: g.get(f, 0) or 0 for f in ("netin", "netout", "diskread", "diskwrite")}
        guests.append({
            "vmid": g.get("vmid"), "name": g.get("name"), "type": g.get("type"),
            "status": g.get("status"), "uptime": g.get("uptime", 0),
            "cpu_pct": round((g.get("cpu") or 0) * 100, 1), "maxcpu": g.get("maxcpu"),
            "mem": g.get("mem"), "maxmem": g.get("maxmem"),
            "disk": g.get("disk"), "maxdisk": g.get("maxdisk"), "lock": g.get("lock"),
            **rates,
        })
    guests.sort(key=lambda g: g["vmid"] or 0)

    cpus, other_temps, drive_temps = read_temps()

    # SMART only refreshes every few minutes, so overlay live temperatures where the kernel has them
    disks = []
    for d in state["disks"]:
        d = dict(d)
        live = drive_temps.get(d["dev"]) if not d["nvme"] else nvme_temp(d["dev"])
        if live is not None:
            d["temp"] = live
        disks.append(d)

    prev.update(t=now, cpu=cur_cpu, net=(rx, tx))
    backups_now = state["backups"] or {}
    return {
        "generated": now,
        "interval": INTERVAL,
        "host": host,
        "temps": {"cpu": cpus, "other": other_temps},
        "disks": disks,
        "zfs": state["zfs"],
        "guests": guests,
        "storage": state["storage"],
        "backups": {**backups_now, "per_guest": state["backup_content"]},
    }


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    threading.Thread(target=slow_loop, daemon=True).start()
    prev = {"t": time.time(), "cpu": cpu_times(), "net": host_net(), "guests": {}, "model": cpu_model()}
    time.sleep(1)
    while True:
        started = time.time()
        try:
            stats = collect(prev)
            tmp = OUT_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(stats, f)
            os.chmod(tmp, 0o644)
            os.replace(tmp, OUT_FILE)
        except Exception as e:
            print(f"collection failed: {e}", flush=True)
        time.sleep(max(INTERVAL - (time.time() - started), 1))


if __name__ == "__main__":
    main()
