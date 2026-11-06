#!/usr/bin/env bash
# pvedash command-line tool. Written by the pvedash installer.
set -euo pipefail

NAME=__NAME__
VERSION=@@VERSION@@
REPO=@@REPO@@
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
