#!/usr/bin/env bash
#
# pvedash: a small, read-only status dashboard for a Proxmox VE server.
#
# Shows CPU, memory, disk and network use, every VM and container on this node,
# CPU and drive temperatures, SMART health, ZFS pools, storage, and backup status.
# It detects what your server has, and leaves out whatever it doesn't.
#
# Run on the Proxmox host's shell, as root:
#
#     curl -fsSL https://raw.githubusercontent.com/BACKFLIPS22/BACKFLIPS22/main/install-pvedash.sh | bash
#
# or, with a downloaded copy:
#
#     bash install-pvedash.sh               install, or update an existing install
#     bash install-pvedash.sh --help        all options
#
# Afterwards, 'pvedash help' lists everything the installed command can do.
#
# What it does:
#   - Writes files to /opt/pvedash, /etc/pvedash.conf and /usr/local/bin/pvedash, and
#     adds two systemd services: pvedash-collector and pvedash-web. Nothing else on
#     the system changes.
#   - Installs no packages and downloads nothing. It uses what Proxmox already has.
#   - The collector runs as root, because SMART data needs it, but it only reads.
#     The web server runs as an unprivileged user and has no way to change anything.
#   - The page has no login. It only answers devices on this server's own network.
#
set -euo pipefail

VERSION=1.0.0
NAME=pvedash
PORT=
BIND=
EXTRA_ALLOW=
ACTION=install
FORCE=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

usage() {
    cat <<'USAGE'
Usage: bash install-pvedash.sh [options]

  --uninstall       Remove the dashboard and everything it installed
  --port N          Port for the page (default: 8090, or the next free one)
  --bind IP         Address to listen on (default: this server's main LAN address)
  --allow CIDR,...  Also allow these networks, for example a VPN: 10.8.0.0/24
  --name NAME       Install under another name, to run a separate copy
  --force           Replace or remove a customised install
  --help            Show this help

Run it again at any time to update. The port and any extra networks are kept.
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --uninstall) ACTION=uninstall ;;
            --force)     FORCE=1 ;;
            --port)      [ $# -ge 2 ] || die "--port needs a value";  PORT=$2;        shift ;;
            --bind)      [ $# -ge 2 ] || die "--bind needs a value";  BIND=$2;        shift ;;
            --allow)     [ $# -ge 2 ] || die "--allow needs a value"; EXTRA_ALLOW=$2; shift ;;
            --name)      [ $# -ge 2 ] || die "--name needs a value";  NAME=$2;        shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done
    [[ $NAME =~ ^[a-z][a-z0-9-]*$ ]] || die "--name may only use lowercase letters, digits and dashes"
    DIR=/opt/$NAME
    CONF=/etc/$NAME.conf
    COLLECTOR_UNIT=/etc/systemd/system/$NAME-collector.service
    WEB_UNIT=/etc/systemd/system/$NAME-web.service
    CLI=/usr/local/bin/$NAME
}

check_host() {
    [ "$(id -u)" -eq 0 ] || die "run this as root, on the Proxmox host's shell"
    command -v pvesh >/dev/null 2>&1 || die "pvesh not found. Run this on a Proxmox VE host, not inside a VM or container."
    command -v systemctl >/dev/null 2>&1 || die "systemd is required"
    command -v python3 >/dev/null 2>&1 || die "python3 not found. Install it with: apt install python3"
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 7))' || die "Python 3.7 or newer is required"
}

# Never replace somebody else's command that happens to have the same name.
check_cli_is_ours() {
    if [ -e "$CLI" ] && ! grep -q '^# pvedash command-line tool' "$CLI"; then
        die "$CLI already exists and isn't part of this dashboard. Use --name to install under another name."
    fi
}

# A customised copy has extra files; replacing it would silently drop those features.
check_not_customised() {
    if [ "$FORCE" -eq 0 ] && [ -d "$DIR" ] && [ -n "$(find "$DIR" -type f ! -name collector.py ! -name server.py ! -name index.html -print -quit)" ]; then
        die "$DIR holds files this installer didn't create, so it looks like a customised install. Use --name to install alongside it, or --force to $ACTION anyway."
    fi
}

conf_value() {
    [ -f "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | head -1 || true
}

port_in_use() {
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
}

stop_services() {
    systemctl stop "$NAME-web" "$NAME-collector" 2>/dev/null || true
}

detect_network() {
    local route
    IFACE=
    route=$(ip -o -4 route get 1.1.1.1 2>/dev/null || true)
    if [ -z "$BIND" ]; then
        BIND=$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$route")
    fi
    if [ -z "$BIND" ]; then
        # No default route: fall back to the first global address.
        BIND=$(ip -o -4 addr show scope global | awk '{split($4, a, "/"); print a[1]; exit}')
    fi
    [ -n "$BIND" ] || die "couldn't find an IPv4 address on this server. Choose one with --bind."

    local line
    line=$(ip -o -4 addr show | awk -v ip="$BIND" '{split($4, a, "/"); if (a[1] == ip) {print $2, $4; exit}}')
    [ -n "$line" ] || die "$BIND isn't an address on this server"
    IFACE=${line%% *}
    SUBNET=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "${line##* }")

    [ -n "$EXTRA_ALLOW" ] || EXTRA_ALLOW=$(conf_value PVEDASH_EXTRA_ALLOW)
    if [ -n "$EXTRA_ALLOW" ]; then
        python3 -c '
import ipaddress, sys
for n in sys.argv[1].split(","):
    ipaddress.ip_network(n)' "$EXTRA_ALLOW" 2>/dev/null || die "--allow must be a comma-separated list of networks, like 10.8.0.0/24"
    fi
    ALLOW=$SUBNET${EXTRA_ALLOW:+,$EXTRA_ALLOW}
}

# Runs while any existing install is still up, so a bad choice can't take it down.
check_port_option() {
    [ -n "$PORT" ] || return 0
    [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port must be a number from 1 to 65535"
    if [ "$PORT" != "$(conf_value PVEDASH_PORT)" ] && port_in_use "$PORT"; then
        die "port $PORT is already in use"
    fi
}

pick_port() {
    [ -z "$PORT" ] || return 0
    PORT=$(conf_value PVEDASH_PORT)
    [ -n "$PORT" ] && ! port_in_use "$PORT" && return
    PORT=8090
    while port_in_use "$PORT"; do
        PORT=$((PORT + 1))
        [ "$PORT" -lt 8200 ] || die "no free port found near 8090. Choose one with --port."
    done
}

write_files() {
    mkdir -p "$DIR"
    write_collector > "$DIR/collector.py"
    write_server > "$DIR/server.py"
    write_page > "$DIR/index.html"
    chmod 755 "$DIR"
    chmod 644 "$DIR/collector.py" "$DIR/server.py" "$DIR/index.html"

    cat > "$CONF" <<EOF
# Written by the pvedash installer. Run it again to change these.
PVEDASH_BIND=$BIND
PVEDASH_PORT=$PORT
PVEDASH_SUBNET=$SUBNET
PVEDASH_ALLOW=$ALLOW
PVEDASH_EXTRA_ALLOW=$EXTRA_ALLOW
PVEDASH_IFACE=$IFACE
PVEDASH_STATS=/run/$NAME/stats.json
EOF
    chmod 644 "$CONF"

    # Swap the file rather than overwrite it: 'pvedash update' is running from it right now.
    cli_source > "$CLI.new"
    chmod 755 "$CLI.new"
    mv -f "$CLI.new" "$CLI"

    cat > "$COLLECTOR_UNIT" <<EOF
[Unit]
Description=pvedash stats collector
After=pve-cluster.service pvedaemon.service

[Service]
EnvironmentFile=$CONF
ExecStart=/usr/bin/env python3 $DIR/collector.py
Restart=always
RestartSec=5
Nice=10
RuntimeDirectory=$NAME
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes

[Install]
WantedBy=multi-user.target
EOF

    cat > "$WEB_UNIT" <<EOF
[Unit]
Description=pvedash web server
After=network-online.target $NAME-collector.service
Wants=network-online.target

[Service]
EnvironmentFile=$CONF
ExecStart=/usr/bin/env python3 $DIR/server.py
Restart=always
RestartSec=5
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ReadOnlyPaths=-/run/$NAME
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6
IPAddressDeny=any
IPAddressAllow=${ALLOW//,/ } localhost

[Install]
WantedBy=multi-user.target
EOF
}

wait_until_serving() {
    local i
    for i in $(seq 1 30); do
        if python3 - "http://$BIND:$PORT/stats.json" 2>/dev/null <<'EOF'
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=3) as r:
    json.load(r)
EOF
        then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Reads what the running collector found, so the summary matches the page. Slow
# checks finish after the first reading, so wait for them (but not for ever).
print_summary() {
    python3 - "/run/$NAME/stats.json" <<'EOF' || true
import json, sys, time
for _ in range(45):
    d = json.load(open(sys.argv[1]))
    if d["disks"] and "tasks" in d["backups"]:
        break
    time.sleep(2)
pending = "still checking"
jobs = d["backups"].get("jobs")
print(f"  Node:          {d['host']['node']}")
print(f"  Guests:        {len(d['guests'])}")
print(f"  CPU temps:     {'yes' if d['temps']['cpu'] else 'none found'}")
print(f"  Drives:        {len(d['disks']) or pending}")
print(f"  ZFS pools:     {len(d['zfs'])}")
print(f"  Backup jobs:   {pending if jobs is None else len(jobs)}")
EOF
}

warn_about_limits() {
    if ! command -v smartctl >/dev/null 2>&1; then
        echo
        echo "NOTE: smartctl isn't installed, so drive health won't show. To add it: apt install smartmontools"
    fi
    if pve-firewall status 2>/dev/null | grep -q 'enabled'; then
        echo
        echo "NOTE: the Proxmox firewall is enabled and may block the page. If it won't load,"
        echo "      allow TCP port $PORT from $SUBNET under Datacenter or Node > Firewall."
    fi
    if pvesh get /cluster/status --output-format json 2>/dev/null | grep -q '"type":"cluster"'; then
        echo
        echo "NOTE: this node is in a cluster. The dashboard only covers this node, so install it on each one."
    fi
}

do_install() {
    check_not_customised
    check_cli_is_ours
    echo "Installing $NAME $VERSION..."
    detect_network
    check_port_option
    stop_services
    pick_port
    info "Listening on $BIND:$PORT ($IFACE)"
    info "Allowing $ALLOW"
    write_files
    systemctl daemon-reload
    systemctl enable --now "$NAME-collector" "$NAME-web" >/dev/null 2>&1
    info "Waiting for the first reading..."
    if ! wait_until_serving; then
        echo
        systemctl --no-pager --lines=10 status "$NAME-collector" "$NAME-web" || true
        die "the dashboard didn't come up. See the service status above. To remove it, run: $NAME uninstall --yes"
    fi
    echo
    print_summary
    warn_about_limits
    echo
    echo "Done. Open this from a device on the same network:"
    echo
    echo "    http://$BIND:$PORT"
    echo
    echo "Run '$NAME help' on this server to see what else you can do."
    echo
}

do_uninstall() {
    check_not_customised
    check_cli_is_ours
    bash -c "$(cli_source)" "$NAME" uninstall --yes
}

# The installed command, also used here so uninstalling has one implementation.
cli_source() {
    write_cli | sed "s/^NAME=__NAME__\$/NAME=$NAME/"
}

write_cli() {
cat <<'PVEDASH_FILE_END'
#!/usr/bin/env bash
# pvedash command-line tool. Written by the pvedash installer.
set -euo pipefail

NAME=__NAME__
VERSION=1.0.0
REPO=BACKFLIPS22/BACKFLIPS22
DIR=/opt/$NAME
CONF=/etc/$NAME.conf
COLLECTOR_UNIT=/etc/systemd/system/$NAME-collector.service
WEB_UNIT=/etc/systemd/system/$NAME-web.service
SELF=/usr/local/bin/$NAME

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "this command needs root"; }
conf() { [ -f "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | head -1 || true; }
url() { echo "http://$(conf PVEDASH_BIND):$(conf PVEDASH_PORT)"; }
need_installed() { [ -f "$CONF" ] || die "$NAME isn't installed (no $CONF)"; }

cmd_help() {
    local page
    page=$(cat <<EOF
$NAME $VERSION: a read-only status dashboard for this Proxmox VE server

USAGE
    $NAME <command>

COMMANDS
    help                 Show this page
    status               Check that it's working, and list what it found
    url                  Print the address of the page
    logs [-f]            Show recent service logs (-f keeps following)
    start, stop          Start or stop the dashboard
    restart              Restart it, for example after a problem
    config               Show the current settings
    set port <N>         Move the page to another port
    set allow <CIDR,...> Also allow other networks, like a VPN: 10.8.0.0/24
    set allow none       Go back to allowing only this server's own network
    update [--force]     Install the latest version from GitHub
    uninstall [--yes]    Remove the dashboard and this command
    version              Show the installed version

OPENING THE PAGE
    Run '$NAME url' and open that address on a device on the same network.
    There's no login. Any device on an allowed network can view the page, which
    shows server names, the VM list and backup status. Nothing on it can change
    your server.

WHAT IT SHOWS
    CPU, memory, disk and network use; every VM and container on this node;
    CPU and drive temperatures; SMART health; ZFS pools; storage; and backup
    jobs and results. Whatever the server doesn't have is left out. In a cluster,
    each node needs its own install.

TROUBLESHOOTING
    Page won't load        Run '$NAME status'. If it's working, check the device
                           is on the same network, then the Proxmox firewall:
                           allow the port under Datacenter or Node > Firewall.
    Reaching it over a VPN Run '$NAME set allow' with the VPN's network.
    No CPU temperatures    Common inside a VM, or on hardware without sensors.
    No drive health        Install smartmontools: apt install smartmontools
                           Drives behind a hardware RAID card can't be read.
    Drive temp is blank    The drive is asleep. It isn't woken up just to check.
    Server's IP changed    Run the installer again to pick up the new address.

FILES
    Program    $DIR
    Settings   $CONF
    Command    $SELF
    Services   $COLLECTOR_UNIT
               $WEB_UNIT

PROJECT
    https://github.com/$REPO
EOF
)
    if [ -t 1 ] && command -v less >/dev/null 2>&1; then
        less -FX <<<"$page"
    else
        echo "$page"
    fi
}

cmd_status() {
    need_installed
    local bad=0 collector web
    collector=$(systemctl is-active "$NAME-collector" 2>/dev/null || true)
    web=$(systemctl is-active "$NAME-web" 2>/dev/null || true)
    [ "$collector" = active ] || bad=1
    [ "$web" = active ] || bad=1
    echo "$NAME $VERSION"
    echo "  Collector:    $collector"
    echo "  Web server:   $web"
    echo "  Address:      $(url)"
    python3 - "$(url)/stats.json" <<'EOF' || bad=1
import json, sys, time, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=5) as r:
        d = json.load(r)
except Exception as e:
    print(f"  Page:         NOT RESPONDING ({e})")
    sys.exit(1)
age = time.time() - d["generated"]
print("  Page:         responding")
print(f"  Last reading: {age:.0f}s ago" + ("  (STALE: the collector may be stuck)" if age > 60 else ""))
guests = d["guests"]
disks = d["disks"]
health = [x for x in disks if x.get("passed") is not None]
jobs = d["backups"].get("jobs")
print()
print("  Found on this server:")
print(f"    Guests:     {len(guests)} ({sum(g['status'] == 'running' for g in guests)} running)")
print(f"    CPU temps:  {'yes' if d['temps']['cpu'] else 'none found'}")
print(f"    Drives:     {len(disks) or 'still checking'}" + (f" ({len(health)} with health data)" if disks else ""))
print(f"    ZFS pools:  {len(d['zfs'])}")
print(f"    Storage:    {sum(s['active'] for s in d['storage'])} of {len(d['storage'])} online")
print(f"    Backup jobs: {'still checking' if jobs is None else len(jobs)}")
if age > 60:
    sys.exit(1)
EOF
    if ! ip -o -4 addr show | grep -q " $(conf PVEDASH_BIND)/"; then
        echo; echo "  PROBLEM: $(conf PVEDASH_BIND) is no longer an address on this server. Run the installer again."
        bad=1
    fi
    if ! command -v smartctl >/dev/null 2>&1; then
        echo; echo "  NOTE: smartctl isn't installed, so drive health won't show: apt install smartmontools"
    fi
    if pve-firewall status 2>/dev/null | grep -q enabled; then
        echo; echo "  NOTE: the Proxmox firewall is enabled. It may need to allow TCP port $(conf PVEDASH_PORT)."
    fi
    return "$bad"
}

cmd_logs() {
    need_root; need_installed
    case "${1:-}" in
        "")        journalctl -u "$NAME-collector" -u "$NAME-web" -n 50 --no-pager ;;
        -f)        journalctl -u "$NAME-collector" -u "$NAME-web" -n 20 -f ;;
        *)         die "usage: $NAME logs [-f]" ;;
    esac
}

cmd_service() {
    need_root; need_installed
    systemctl "$1" "$NAME-collector" "$NAME-web"
    if [ "$1" = stop ]; then
        echo "Stopped. It starts again at the next boot, or with: $NAME start"
    else
        echo "Running at $(url)"
    fi
}

cmd_config() {
    need_installed
    echo "Address:   $(url)"
    echo "Interface: $(conf PVEDASH_IFACE)"
    echo "Allowed:   $(conf PVEDASH_ALLOW)"
}

cmd_set() {
    need_root; need_installed
    [ $# -eq 2 ] || die "usage: $NAME set port <N>  or  $NAME set allow <CIDR,...|none>"
    case "$1" in
        port)
            [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || die "the port must be a number from 1 to 65535"
            if [ "$2" != "$(conf PVEDASH_PORT)" ] && ss -ltnH "sport = :$2" 2>/dev/null | grep -q .; then
                die "port $2 is already in use"
            fi
            sed -i "s/^PVEDASH_PORT=.*/PVEDASH_PORT=$2/" "$CONF"
            ;;
        allow)
            local extra=$2 allow
            [ "$extra" != none ] || extra=
            if [ -n "$extra" ]; then
                python3 -c '
import ipaddress, sys
for n in sys.argv[1].split(","):
    ipaddress.ip_network(n)' "$extra" 2>/dev/null || die "that must be a comma-separated list of networks, like 10.8.0.0/24"
            fi
            allow=$(conf PVEDASH_SUBNET)${extra:+,$extra}
            sed -i -e "s|^PVEDASH_ALLOW=.*|PVEDASH_ALLOW=$allow|" -e "s|^PVEDASH_EXTRA_ALLOW=.*|PVEDASH_EXTRA_ALLOW=$extra|" "$CONF"
            sed -i "s|^IPAddressAllow=.*|IPAddressAllow=${allow//,/ } localhost|" "$WEB_UNIT"
            systemctl daemon-reload
            ;;
        *) die "usage: $NAME set port <N>  or  $NAME set allow <CIDR,...|none>" ;;
    esac
    systemctl restart "$NAME-web"
    cmd_config
}

cmd_update() {
    need_root; need_installed
    local force=${1:-} url latest
    url=${PVEDASH_UPDATE_URL:-}
    if [ -z "$url" ]; then
        case "$REPO" in
            YOUR-USERNAME/*) die "this copy was built without a GitHub repo, so it can't update itself" ;;
        esac
        url="https://raw.githubusercontent.com/$REPO/main/install-pvedash.sh"
    fi
    command -v curl >/dev/null 2>&1 || die "curl is required: apt install curl"
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    curl -fsSL "$url" -o "$TMP" || die "couldn't download $url"
    bash -n "$TMP" 2>/dev/null && [ "$(tail -n 1 "$TMP")" = 'main "$@"' ] || die "the download looks damaged, so nothing was changed"
    latest=$(sed -n 's/^VERSION=//p' "$TMP" | head -1)
    if [ "$latest" = "$VERSION" ] && [ "$force" != --force ]; then
        echo "Already up to date ($VERSION). Use '$NAME update --force' to reinstall anyway."
        return 0
    fi
    echo "Updating $VERSION to $latest..."
    bash "$TMP" --name "$NAME"
}

cmd_uninstall() {
    need_root
    if [ "${1:-}" != --yes ]; then
        [ -t 0 ] || die "run '$NAME uninstall --yes' to confirm"
        read -r -p "Remove $NAME from this server? [y/N] " answer
        case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing was changed."; return 0 ;; esac
    fi
    echo "Removing $NAME..."
    systemctl disable --now "$NAME-web" "$NAME-collector" >/dev/null 2>&1 || true
    rm -f "$COLLECTOR_UNIT" "$WEB_UNIT" "$CONF" "$SELF"
    rm -rf "${DIR:?}" "/run/${NAME:?}"
    systemctl daemon-reload
    systemctl reset-failed "$NAME-web" "$NAME-collector" 2>/dev/null || true
    echo "Done. Nothing from $NAME is left on this server."
}

main() {
    local cmd=${1:-help}
    [ $# -eq 0 ] || shift
    case "$cmd" in
        help|-h|--help)       cmd_help ;;
        status)               cmd_status ;;
        url)                  need_installed; url ;;
        logs)                 cmd_logs "$@" ;;
        start|stop|restart)   cmd_service "$cmd" ;;
        config)               cmd_config ;;
        set)                  cmd_set "$@" ;;
        update)               cmd_update "$@" ;;
        uninstall)            cmd_uninstall "$@" ;;
        version|-v|--version) echo "$NAME $VERSION" ;;
        *)                    echo "Unknown command: $cmd. Run '$NAME help' for the list." >&2; exit 2 ;;
    esac
}

main "$@"
PVEDASH_FILE_END
}

write_collector() {
cat <<'PVEDASH_FILE_END'
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
PVEDASH_FILE_END
}

write_server() {
cat <<'PVEDASH_FILE_END'
#!/usr/bin/env python3
"""pvedash web server: serves the dashboard page and stats.json, read-only, to the
local network only. Runs unprivileged."""
import ipaddress
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ["PVEDASH_BIND"]
PORT = int(os.environ["PVEDASH_PORT"])
ALLOWED = [ipaddress.ip_network(n) for n in os.environ["PVEDASH_ALLOW"].split(",")]
STATS = os.environ["PVEDASH_STATS"]
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")


class Handler(BaseHTTPRequestHandler):
    server_version = "pvedash"
    sys_version = ""

    def do_GET(self):
        ip = ipaddress.ip_address(self.client_address[0])
        if not any(ip in n for n in ALLOWED):
            return self.send_error(403)
        # Never answer a request forwarded from a Cloudflare public hostname.
        if any(h.lower().startswith("cf-") for h in self.headers.keys()):
            return self.send_error(403)

        path = self.path.split("?", 1)[0]
        if path == "/stats.json":
            src, ctype = STATS, "application/json"
        elif path in ("/", "/index.html"):
            src, ctype = PAGE, "text/html; charset=utf-8"
        else:
            return self.send_error(404)
        try:
            with open(src, "rb") as f:
                body = f.read()
        except OSError:
            return self.send_error(503, "stats not ready")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
PVEDASH_FILE_END
}

write_page() {
cat <<'PVEDASH_FILE_END'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Proxmox Dashboard</title>
<style>
:root {
  --bg: #f4f5f7; --panel: #ffffff; --panel-2: #f8f9fb; --border: #e3e6eb;
  --text: #1b1f24; --muted: #66707c; --faint: #9aa3ad;
  --accent: #e57000; --ok: #1f9d55; --warn: #c98a00; --bad: #d64545; --info: #2f6fde;
  --track: #e8ebef;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1216; --panel: #171b21; --panel-2: #1c2128; --border: #262c35;
    --text: #e6e9ed; --muted: #8c96a3; --faint: #5d6672;
    --accent: #ff8a1f; --ok: #3ccf7a; --warn: #f0b429; --bad: #ff5c5c; --info: #5b9cff;
    --track: #252b33;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
.wrap { max-width: 1400px; margin: 0 auto; padding: 20px 16px 48px; }
header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 18px; margin-bottom: 16px; }
header h1 { margin: 0; font-size: 22px; letter-spacing: -0.01em; }
header h1 span { color: var(--accent); }
header .meta { color: var(--muted); font-size: 13px; }
.live { margin-left: auto; display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 13px; }
.dot { width: 9px; height: 9px; border-radius: 50%; background: var(--ok); display: inline-block; }
.dot.stale { background: var(--bad); }
.dot.off { background: var(--faint); }

.alerts { display: grid; gap: 8px; margin-bottom: 16px; }
.alert { display: flex; gap: 10px; align-items: flex-start; padding: 10px 14px; border-radius: 8px;
  border: 1px solid var(--border); background: var(--panel); border-left: 4px solid var(--warn); }
.alert.bad { border-left-color: var(--bad); }
.alert b { white-space: nowrap; }
.alert .msg { color: var(--muted); word-break: break-word; }

.grid { display: grid; gap: 16px; grid-template-columns: repeat(12, 1fr); }
.card { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 16px; min-width: 0; }
.card h2 { margin: 0 0 12px; font-size: 13px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.06em; color: var(--muted); display: flex; justify-content: space-between; gap: 8px; }
.card h2 small { text-transform: none; letter-spacing: 0; font-weight: 400; color: var(--faint); }
.span-12 { grid-column: span 12; } .span-8 { grid-column: span 8; } .span-6 { grid-column: span 6; }
.span-4 { grid-column: span 4; } .span-3 { grid-column: span 3; }
@media (max-width: 1100px) { .span-3 { grid-column: span 6; } .span-8, .span-4 { grid-column: span 12; } }
@media (max-width: 700px) { .span-3, .span-6 { grid-column: span 12; } }

.tile .big { font-size: 30px; font-weight: 650; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
.tile .sub { color: var(--muted); font-size: 13px; font-variant-numeric: tabular-nums; }
.bar { height: 6px; background: var(--track); border-radius: 3px; overflow: hidden; margin: 10px 0 6px; }
.bar > i { display: block; height: 100%; background: var(--info); border-radius: 3px; transition: width .4s; }
.bar.sm { height: 4px; margin: 4px 0 0; }
.spark { width: 100%; height: 36px; display: block; margin-top: 8px; }

.temps { display: grid; gap: 14px; }
.sock { display: grid; grid-template-columns: auto 1fr; gap: 6px 14px; align-items: center; }
.sock .pkg { font-size: 26px; font-weight: 650; font-variant-numeric: tabular-nums; }
.sock .lbl { color: var(--muted); font-size: 12px; }
.cores { display: grid; grid-template-columns: repeat(auto-fill, minmax(46px, 1fr)); gap: 4px; }
.core { text-align: center; padding: 4px 0; border-radius: 5px; background: var(--panel-2);
  font: 12px var(--mono); border: 1px solid var(--border); }
.core small { display: block; color: var(--faint); font-size: 10px; font-family: system-ui, sans-serif; }

table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th { text-align: left; font-weight: 500; color: var(--muted); font-size: 12px; padding: 6px 10px;
  border-bottom: 1px solid var(--border); white-space: nowrap; }
td { padding: 8px 10px; border-bottom: 1px solid var(--border); vertical-align: middle; }
tr:last-child td { border-bottom: 0; }
td.num, th.num { text-align: right; white-space: nowrap; }
.scroll { overflow-x: auto; margin: 0 -16px; padding: 0 16px; }
.name { font-weight: 600; }
.mono { font-family: var(--mono); font-size: 12.5px; }
.muted { color: var(--muted); } .faint { color: var(--faint); }
.pill { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 12px;
  border: 1px solid currentColor; white-space: nowrap; }
.ok { color: var(--ok); } .warn { color: var(--warn); } .bad { color: var(--bad); }
.cell-bar { min-width: 110px; }
.cell-bar .v { font-size: 12.5px; }
.type { font-size: 11px; text-transform: uppercase; letter-spacing: .05em; color: var(--faint); }
.kv { display: grid; grid-template-columns: auto 1fr; gap: 6px 14px; }
.kv dt { color: var(--muted); } .kv dd { margin: 0; }
.backup-hero { display: flex; gap: 12px; align-items: center; padding: 12px 14px; border-radius: 8px;
  background: var(--panel-2); border: 1px solid var(--border); margin-bottom: 14px; }
.backup-hero .big { font-size: 18px; font-weight: 650; }
.err { color: var(--bad); font-size: 12px; word-break: break-word; display: -webkit-box;
  -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
td.when { white-space: nowrap; }
.empty { color: var(--faint); padding: 8px 0; }
footer { margin-top: 24px; color: var(--faint); font-size: 12px; text-align: center; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1><span>▲</span> <span id="node" style="color:inherit">Proxmox</span></h1>
    <div class="meta" id="hostmeta">loading…</div>
    <div class="live"><i class="dot off" id="dot"></i><span id="updated">waiting for data</span></div>
  </header>

  <div class="alerts" id="alerts"></div>

  <div class="grid">
    <div class="card tile span-3"><h2>CPU <small id="cpu-model"></small></h2>
      <div class="big" id="cpu-pct">–</div><div class="bar"><i id="cpu-bar"></i></div>
      <div class="sub" id="cpu-sub"></div><svg class="spark" id="cpu-spark" preserveAspectRatio="none"></svg></div>
    <div class="card tile span-3"><h2>Memory</h2>
      <div class="big" id="mem-pct">–</div><div class="bar"><i id="mem-bar"></i></div>
      <div class="sub" id="mem-sub"></div><svg class="spark" id="mem-spark" preserveAspectRatio="none"></svg></div>
    <div class="card tile span-3"><h2>Root disk</h2>
      <div class="big" id="root-pct">–</div><div class="bar"><i id="root-bar"></i></div>
      <div class="sub" id="root-sub"></div>
      <div class="sub" style="margin-top:10px" id="swap-sub"></div></div>
    <div class="card tile span-3"><h2>Network <small id="net-iface"></small></h2>
      <div class="sub">↓ in</div><div class="big" id="net-rx" style="font-size:22px">–</div>
      <div class="sub" style="margin-top:6px">↑ out</div><div class="big" id="net-tx" style="font-size:22px">–</div>
      <svg class="spark" id="net-spark" preserveAspectRatio="none"></svg></div>

    <div class="card span-8"><h2>Virtual machines &amp; containers <small id="guest-count"></small></h2>
      <div class="scroll"><table>
        <thead><tr><th>ID</th><th>Name</th><th>Status</th><th class="num">CPU</th><th>Memory</th><th>Disk</th>
          <th class="num">Net in / out</th><th class="num">Disk r / w</th><th class="num">Uptime</th></tr></thead>
        <tbody id="guests"></tbody></table></div></div>

    <div class="card span-4"><h2>Temperatures</h2><div class="temps" id="temps"></div></div>

    <div class="card span-6"><h2>Backups</h2>
      <div class="backup-hero" id="backup-hero"></div>
      <div id="backup-jobs"></div>
      <h2 style="margin-top:16px">Recent runs</h2>
      <div class="scroll"><table><thead><tr><th>Started</th><th>Target</th><th class="num">Took</th><th>Result</th></tr></thead>
        <tbody id="backup-tasks"></tbody></table></div>
      <h2 style="margin-top:16px">Latest backup per guest</h2>
      <div class="scroll"><table><thead><tr><th>Guest</th><th>Last backup</th><th>Storage</th><th class="num">Size</th></tr></thead>
        <tbody id="backup-guests"></tbody></table></div></div>

    <div class="span-6" style="display:grid;gap:16px;align-content:start">
      <div class="card"><h2>Drives</h2>
        <div class="scroll"><table><thead><tr><th>Device</th><th class="num">Temp</th><th>Health</th>
          <th class="num">Power-on</th><th class="num">Realloc / pending</th></tr></thead>
          <tbody id="disks"></tbody></table></div></div>
      <div class="card" id="zfs-card" hidden><h2>ZFS pools</h2>
        <div class="scroll"><table><thead><tr><th>Pool</th><th>Health</th><th>Usage</th><th class="num">Frag</th></tr></thead>
          <tbody id="zfs"></tbody></table></div></div>
      <div class="card"><h2>Storage</h2>
        <div class="scroll"><table><thead><tr><th>Name</th><th>Type</th><th>Status</th><th>Usage</th></tr></thead>
          <tbody id="storage"></tbody></table></div></div>
    </div>
  </div>
  <footer>Read-only dashboard · LAN only · refreshes every 10s</footer>
</div>

<script>
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const HIST = 60; // points kept for sparklines (~10 min)
const hist = { cpu: [], mem: [], rx: [], tx: [] };
let lastGen = 0;

function bytes(n, d = 1) {
  if (n == null || isNaN(n)) return "–";
  const u = ["B", "KB", "MB", "GB", "TB", "PB"]; let i = 0;
  while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i === 0 ? 0 : d) + " " + u[i];
}
const rate = n => n == null ? "–" : bytes(n) + "/s";
function dur(s) {
  if (!s && s !== 0) return "–"; s = Math.floor(s);
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  if (d) return `${d}d ${h}h`; if (h) return `${h}h ${m}m`; if (m) return `${m}m`; return `${s}s`;
}
function ago(ts) {
  if (!ts) return "never";
  const s = Date.now() / 1000 - ts;
  return s < 0 ? "in " + dur(-s) : dur(s) + " ago";
}
const dt = ts => ts ? new Date(ts * 1000).toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "–";
const pct = (a, b) => b ? 100 * a / b : 0;
const level = (p, w = 75, b = 90) => p >= b ? "bad" : p >= w ? "warn" : "ok";
const lvlColor = l => `var(--${l === "ok" ? "info" : l})`;
const PKG = /^(Package|Tctl|Tdie)/;
const driveHigh = x => x.rotational ? 50 : x.nvme ? 80 : 65;
function tempLevel(t, high) { high = high || 85; return t >= high ? "bad" : t >= high - 15 ? "warn" : "ok"; }
function setBar(el, p, l) { el.style.width = Math.min(100, Math.max(0, p)) + "%"; el.style.background = lvlColor(l || level(p)); }
function miniBar(used, total) {
  if (!total) return '<span class="faint">–</span>';
  const p = pct(used, total), l = level(p);
  return `<div class="cell-bar"><div class="v">${bytes(used)} <span class="faint">/ ${bytes(total)}</span></div>
    <div class="bar sm"><i style="width:${Math.min(p, 100)}%;background:${lvlColor(l)}"></i></div></div>`;
}
function push(arr, v) { arr.push(v); if (arr.length > HIST) arr.shift(); }
function spark(svg, series, max) {
  const w = 300, h = 36; svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
  const m = max || Math.max(1, ...series.flatMap(s => s.data));
  svg.innerHTML = series.map(s => {
    if (s.data.length < 2) return "";
    const pts = s.data.map((v, i) => `${(i / (HIST - 1)) * w},${h - 2 - (v / m) * (h - 4)}`);
    const off = w - (s.data.length - 1) / (HIST - 1) * w;
    return `<polyline transform="translate(${off},0)" fill="none" stroke="${s.color}" stroke-width="1.5"
      vector-effect="non-scaling-stroke" points="${pts.join(" ")}"/>`;
  }).join("");
}

function render(d) {
  const h = d.host;
  $("node").textContent = h.node;
  document.title = `${h.node} · Proxmox`;
  $("hostmeta").textContent = `${(h.pveversion || "").split(" ")[0]} · ${h.kernel} · up ${dur(h.uptime)}`;

  // host tiles
  $("cpu-model").textContent = `${h.cpus} threads`;
  $("cpu-model").title = h.cpu_model;
  $("cpu-pct").textContent = h.cpu_pct.toFixed(1) + "%";
  setBar($("cpu-bar"), h.cpu_pct);
  $("cpu-sub").textContent = `load ${h.loadavg.map(x => x.toFixed(2)).join(" · ")} · iowait ${h.iowait_pct.toFixed(1)}%`;
  const mp = pct(h.mem_used, h.mem_total);
  $("mem-pct").textContent = mp.toFixed(1) + "%"; setBar($("mem-bar"), mp);
  $("mem-sub").textContent = `${bytes(h.mem_used)} of ${bytes(h.mem_total)}`;
  const rp = pct(h.rootfs_used, h.rootfs_total);
  $("root-pct").textContent = rp.toFixed(1) + "%"; setBar($("root-bar"), rp);
  $("root-sub").textContent = `${bytes(h.rootfs_used)} of ${bytes(h.rootfs_total)}`;
  $("swap-sub").textContent = h.swap_total ? `Swap: ${bytes(h.swap_used)} of ${bytes(h.swap_total)}` : "No swap";
  $("net-iface").textContent = h.net.iface;
  $("net-rx").textContent = rate(h.net.rx_rate); $("net-tx").textContent = rate(h.net.tx_rate);

  if (d.generated !== lastGen) {
    push(hist.cpu, h.cpu_pct); push(hist.mem, mp); push(hist.rx, h.net.rx_rate); push(hist.tx, h.net.tx_rate);
    lastGen = d.generated;
  }
  spark($("cpu-spark"), [{ data: hist.cpu, color: "var(--info)" }], 100);
  spark($("mem-spark"), [{ data: hist.mem, color: "var(--info)" }], 100);
  spark($("net-spark"), [{ data: hist.rx, color: "var(--ok)" }, { data: hist.tx, color: "var(--accent)" }]);

  // guests
  const running = d.guests.filter(g => g.status === "running").length;
  $("guest-count").textContent = `${running} of ${d.guests.length} running`;
  $("guests").innerHTML = d.guests.map(g => {
    const on = g.status === "running";
    const st = on ? "ok" : g.status === "paused" ? "warn" : "faint";
    return `<tr>
      <td class="mono">${g.vmid}</td>
      <td><div class="name">${esc(g.name)}</div><div class="type">${g.type === "qemu" ? "VM" : "Container"}${g.lock ? " · 🔒 " + esc(g.lock) : ""}</div></td>
      <td><span class="pill ${st}">${esc(g.status)}</span></td>
      <td class="num">${on ? g.cpu_pct.toFixed(1) + "%" : "–"}<div class="faint" style="font-size:11px">${g.maxcpu} vCPU</div></td>
      <td>${on ? miniBar(g.mem, g.maxmem) : `<span class="faint">${bytes(g.maxmem)}</span>`}</td>
      <td>${g.disk ? miniBar(g.disk, g.maxdisk) : `<span class="faint">${bytes(g.maxdisk)}</span>`}</td>
      <td class="num mono">${on ? rate(g.netin_rate) + "<br>" + rate(g.netout_rate) : "–"}</td>
      <td class="num mono">${on ? rate(g.diskread_rate) + "<br>" + rate(g.diskwrite_rate) : "–"}</td>
      <td class="num">${on ? dur(g.uptime) : "–"}</td></tr>`;
  }).join("") || `<tr><td colspan="9" class="empty">No guests</td></tr>`;

  // temperatures
  const sockets = {};
  d.temps.cpu.forEach(t => (sockets[t.socket] ??= []).push(t));
  let th = Object.keys(sockets).sort().map(s => {
    const list = sockets[s];
    const pkg = list.find(t => PKG.test(t.label)) || list[0];
    const cores = list.filter(t => t !== pkg && !PKG.test(t.label));
    const name = Object.keys(sockets).length > 1 ? `CPU ${s}` : "CPU";
    return `<div class="sock"><div><div class="lbl">${name}</div>
        <div class="pkg ${tempLevel(pkg.temp, pkg.high)}">${pkg.temp.toFixed(0)}°C</div></div>
      <div class="cores">${cores.map(c => `<div class="core ${tempLevel(c.temp, c.high)}"><small>${esc(c.label.replace("Core ", "C").replace("Tccd", "CCD"))}</small>${c.temp.toFixed(0)}°</div>`).join("")}</div></div>`;
  }).join("");
  const others = [
    ...d.disks.filter(x => x.temp != null).map(x => ({ label: x.model ? `${x.dev} · ${x.model}` : x.dev, temp: x.temp, high: driveHigh(x) })),
    ...d.temps.other,
  ];
  if (others.length) th += `<dl class="kv">${others.map(o =>
    `<dt>${esc(o.label)}</dt><dd class="${tempLevel(o.temp, o.high)}" style="text-align:right;font-variant-numeric:tabular-nums">${o.temp.toFixed(0)}°C</dd>`).join("")}</dl>`;
  $("temps").innerHTML = th || `<div class="empty">No temperature sensors found on this server</div>`;

  // drives
  $("disks").innerHTML = d.disks.map(x => {
    const health = x.passed == null ? (x.standby ? '<span class="pill faint">standby</span>' : '<span class="faint">unknown</span>')
      : x.passed ? '<span class="pill ok">passed</span>' : '<span class="pill bad">FAILING</span>';
    const yrs = x.power_on_hours != null ? (x.power_on_hours / 8766).toFixed(1) + " yrs" : "–";
    const ageCls = x.power_on_hours > 50000 ? "warn" : "";
    const rp = [x.reallocated, x.pending].map(v => v == null ? "–" : v).join(" / ");
    const rpCls = (x.reallocated > 0 || x.pending > 0) ? "warn" : "";
    return `<tr><td><div class="name mono">${esc(x.dev)}</div><div class="faint" style="font-size:12px">${[esc(x.model), bytes(x.size, 0), x.nvme ? "NVMe" : x.rotational ? "HDD" : "SSD", x.wear_used_pct != null ? x.wear_used_pct + "% worn" : ""].filter(Boolean).join(" · ")}</div></td>
      <td class="num ${x.temp != null ? tempLevel(x.temp, driveHigh(x)) : ""}">${x.temp != null ? x.temp.toFixed(0) + "°C" : "–"}</td>
      <td>${health}</td>
      <td class="num ${ageCls}" title="${x.power_on_hours ?? ""} hours">${yrs}</td>
      <td class="num ${rpCls}">${rp}</td></tr>`;
  }).join("") || `<tr><td colspan="5" class="empty">No drive data yet (refreshes every 5 min)</td></tr>`;

  // ZFS, only on servers that have pools
  const zfs = d.zfs || [];
  $("zfs-card").hidden = !zfs.length;
  $("zfs").innerHTML = zfs.map(p => `<tr>
      <td><div class="name">${esc(p.name)}</div>${p.scan ? `<div class="faint" style="font-size:12px">${esc(p.scan)}</div>` : ""}</td>
      <td><span class="pill ${p.health === "ONLINE" ? "ok" : "bad"}">${esc(p.health)}</span></td>
      <td>${miniBar(p.alloc, p.size)}</td><td class="num">${p.frag === "-" ? "–" : esc(p.frag) + "%"}</td></tr>`).join("");

  // storage
  $("storage").innerHTML = d.storage.map(s => `<tr>
      <td class="name">${esc(s.storage)}</td><td class="muted">${esc(s.type)}</td>
      <td>${!s.enabled ? '<span class="pill faint">disabled</span>' : s.active ? '<span class="pill ok">active</span>' : '<span class="pill bad">offline</span>'}</td>
      <td>${s.active ? miniBar(s.used, s.total) : '<span class="faint">–</span>'}</td></tr>`).join("")
    || `<tr><td colspan="4" class="empty">Loading…</td></tr>`;

  // backups
  const b = d.backups || {};
  const tasks = b.tasks || [];
  const last = b.last_success, latest = tasks[0];
  const nameOf = id => (d.guests.find(g => String(g.vmid) === String(id)) || {}).name;
  let heroCls, heroText, heroSub;
  if (!b.tasks) {
    heroCls = "warn"; heroText = "Checking backups…"; heroSub = "";
  } else if (latest && !latest.ok && latest.status !== "running") {
    heroCls = "bad"; heroText = "Last backup run FAILED";
    heroSub = last ? `Last successful backup: ${dt(last.start)} (${ago(last.end)})`
                   : `No successful backup in the last ${b.tasks_scanned} runs on record`;
  } else if (latest && latest.status === "running") {
    heroCls = "warn"; heroText = "Backup running now"; heroSub = `Started ${ago(latest.start)}`;
  } else if (last) {
    const age = Date.now() / 1000 - last.end;
    heroCls = age > 8 * 86400 ? "warn" : "ok";
    heroText = `Last backup succeeded ${ago(last.end)}`; heroSub = dt(last.start);
  } else {
    heroCls = "warn"; heroText = "No backups on record"; heroSub = "";
  }
  $("backup-hero").innerHTML = `<i class="dot" style="background:var(--${heroCls === "ok" ? "ok" : heroCls})"></i>
    <div><div class="big ${heroCls}">${heroText}</div><div class="muted">${esc(heroSub)}</div></div>`;

  $("backup-jobs").innerHTML = (b.jobs || []).map(j => `<dl class="kv">
      <dt>Schedule</dt><dd><b>${esc(j.schedule)}</b>${j.enabled ? "" : ' <span class="pill faint">disabled</span>'}</dd>
      <dt>Next run</dt><dd>${j.next_run ? `${dt(j.next_run)} <span class="faint">(${ago(j.next_run)})</span>` : "–"}</dd>
      <dt>Target</dt><dd>${esc(j.storage)} · ${esc(j.selection)}${(() => { const s = d.storage.find(x => x.storage === j.storage); return s && !s.active ? ' <span class="pill bad">storage offline</span>' : ""; })()}</dd>
    </dl>`).join('<hr style="border:0;border-top:1px solid var(--border);margin:10px 0">')
    || `<div class="empty">No scheduled backup jobs</div>`;

  $("backup-tasks").innerHTML = tasks.slice(0, 8).map(t => `<tr>
      <td class="when">${dt(t.start)}</td>
      <td>${t.vmid ? esc(t.vmid + (nameOf(t.vmid) ? " · " + nameOf(t.vmid) : "")) : '<span class="muted">job</span>'}</td>
      <td class="num">${t.end ? dur(t.end - t.start) : "…"}</td>
      <td>${t.status === "running" ? '<span class="pill warn">running</span>'
            : t.ok ? `<span class="pill ok">${t.status === "OK" ? "OK" : esc(t.status)}</span>`
            : `<span class="pill bad">failed</span><div class="err" title="${esc(t.status)}">${esc(t.status)}</div>`}</td></tr>`).join("")
    || `<tr><td colspan="4" class="empty">No backup runs recorded</td></tr>`;

  const per = b.per_guest;
  $("backup-guests").innerHTML = !per ? `<tr><td colspan="4" class="empty">Checking…</td></tr>` : d.guests.map(g => {
    const p = per[String(g.vmid)];
    const age = p ? Date.now() / 1000 - p.ctime : Infinity;
    const cls = !p ? "bad" : age > 8 * 86400 ? "warn" : "ok";
    return `<tr><td><span class="mono faint">${g.vmid}</span> ${esc(g.name)}</td>
      <td class="${cls} when">${p ? `${dt(p.ctime)} <span class="faint">(${ago(p.ctime)})</span>` : "none found"}</td>
      <td class="muted">${p ? esc(p.storage) : "–"}</td><td class="num">${p ? bytes(p.size) : "–"}</td></tr>`;
  }).join("") || `<tr><td colspan="4" class="empty">–</td></tr>`;

  // alerts
  const alerts = [];
  if (latest && !latest.ok && latest.status !== "running")
    alerts.push(["bad", "Backups failing", `Last run ${ago(latest.start)}: ${latest.status}` +
      (last ? ` · last success ${ago(last.end)}` : ` · no success in last ${b.tasks_scanned} runs`)]);
  else if (last && Date.now() / 1000 - last.end > 8 * 86400)
    alerts.push(["warn", "Backups stale", `Last successful backup was ${ago(last.end)}`]);
  d.storage.filter(s => s.enabled && !s.active).forEach(s =>
    alerts.push(["warn", "Storage offline", `${s.storage} (${s.type}) is not reachable`]));
  d.storage.filter(s => s.active && pct(s.used, s.total) >= 90).forEach(s =>
    alerts.push(["bad", "Storage nearly full", `${s.storage} is ${pct(s.used, s.total).toFixed(0)}% used`]));
  d.disks.forEach(x => {
    if (x.passed === false) alerts.push(["bad", "Drive failing", `${x.model ? `${x.dev} (${x.model})` : x.dev} failed its SMART check`]);
    if (x.reallocated > 0 || x.pending > 0) alerts.push(["warn", "Drive wear", `${x.dev} has ${x.reallocated || 0} reallocated / ${x.pending || 0} pending sectors`]);
    if (x.power_on_hours > 50000) alerts.push(["warn", "Aging drive", `${x.model ? `${x.dev} (${x.model})` : x.dev} has run ${(x.power_on_hours / 8766).toFixed(1)} years`]);
  });
  [...d.temps.cpu.filter(t => PKG.test(t.label)).map(t => ({ ...t, label: "CPU " + t.socket })), ...others]
    .filter(t => tempLevel(t.temp, t.high) === "bad")
    .forEach(t => alerts.push(["bad", "Running hot", `${t.label} at ${t.temp.toFixed(0)}°C`]));
  zfs.filter(p => p.health !== "ONLINE").forEach(p =>
    alerts.push(["bad", "ZFS pool degraded", `${p.name} is ${p.health}`]));
  zfs.filter(p => pct(p.alloc, p.size) >= 85).forEach(p =>
    alerts.push(["warn", "ZFS pool filling up", `${p.name} is ${pct(p.alloc, p.size).toFixed(0)}% used`]));
  if (mp >= 90) alerts.push(["bad", "Memory pressure", `${mp.toFixed(0)}% RAM used`]);
  if (rp >= 90) alerts.push(["bad", "Root disk nearly full", `${rp.toFixed(0)}% used`]);
  $("alerts").innerHTML = alerts.map(([l, t, m]) =>
    `<div class="alert ${l}"><b class="${l}">${esc(t)}</b><span class="msg">${esc(m)}</span></div>`).join("");
}

let data = null;
function tick() {
  if (!data) return;
  const age = Date.now() / 1000 - data.generated;
  $("dot").className = "dot" + (age > 3 * data.interval ? " stale" : "");
  $("updated").textContent = age > 3 * data.interval ? `stale · updated ${ago(data.generated)}` : `live · updated ${Math.max(0, Math.round(age))}s ago`;
}
async function load() {
  try {
    const r = await fetch("stats.json", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    data = await r.json();
    render(data);
  } catch (e) {
    $("dot").className = "dot stale";
    $("updated").textContent = "cannot reach server";
  }
  tick();
}
load();
setInterval(load, 10000);
setInterval(tick, 1000);
</script>
</body>
</html>
PVEDASH_FILE_END
}

main() {
    parse_args "$@"
    check_host
    case "$ACTION" in
        install)   do_install ;;
        uninstall) do_uninstall ;;
    esac
}

# Last line on purpose: a partly copied or downloaded script does nothing at all.
main "$@"
