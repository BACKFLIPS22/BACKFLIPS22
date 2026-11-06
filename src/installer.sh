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
#     curl -fsSL https://raw.githubusercontent.com/@@REPO@@/main/install-pvedash.sh | bash
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

VERSION=@@VERSION@@
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
@@CLI@@
PVEDASH_FILE_END
}

write_collector() {
cat <<'PVEDASH_FILE_END'
@@COLLECTOR@@
PVEDASH_FILE_END
}

write_server() {
cat <<'PVEDASH_FILE_END'
@@SERVER@@
PVEDASH_FILE_END
}

write_page() {
cat <<'PVEDASH_FILE_END'
@@PAGE@@
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
