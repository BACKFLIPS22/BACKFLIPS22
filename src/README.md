Hi I'm Saxon and this is my (very basic) GitHub.

I am currently working on a few things that will make this a bit better filled out.

My latest project was a collaboration and can been seen here: https://github.com/JordanNotAvailable/Rubber-Ducky-Script 

Cheers!
<!---
BACKFLIPS22/BACKFLIPS22 is a ✨ special ✨ repository because its `README.md` (this file) appears on your GitHub profile.
You can click the Preview link to take a look at your changes.
--->

---

# pvedash

A small, read-only status dashboard for a [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment) server. One command installs it, it works out what your server has, and nothing needs configuring.

![The dashboard, showing example data](docs/screenshot.jpg)

## What it shows

- **Server use:** CPU, memory, root disk, swap and network, with short history charts
- **VMs and containers:** status, CPU, memory, disk, network and disk activity, uptime
- **Temperatures:** Intel and AMD CPUs, drives, and other sensors the kernel exposes
- **Drive health:** SMART status, age, bad sectors and NVMe wear for SATA, SAS and NVMe drives
- **ZFS pools:** health, usage and last scrub, if you have any
- **Storage:** every storage and whether it's online
- **Backups:** last good backup, next scheduled run, recent results, and the latest backup of each guest
- **Alerts** at the top of the page for failing backups, offline storage, failing drives, high temperatures and full disks

Whatever your server doesn't have is left out.

## Install

Run this on the Proxmox host's shell, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/@@REPO@@/main/install-pvedash.sh | bash
```

It prints the address when it finishes, usually `http://<your-server>:8090`. Open that on a device on the same network.

Prefer to read it first? Download [`install-pvedash.sh`](install-pvedash.sh), look through it, then run `bash install-pvedash.sh`. To pass installer options with the one-liner, use `bash -s --`, for example:

```bash
curl -fsSL https://raw.githubusercontent.com/@@REPO@@/main/install-pvedash.sh | bash -s -- --port 9000
```

| Option | What it does |
|---|---|
| `--port N` | Use this port. By default it's 8090, or the next free port. |
| `--bind IP` | Listen on this address. By default it's the server's main LAN address. |
| `--allow CIDR,...` | Also allow these networks, such as a VPN: `10.8.0.0/24` |
| `--name NAME` | Install a separate copy under another name |
| `--force` | Replace a customised install |

### Requirements

Proxmox VE with Python 3.7 or newer, which Proxmox normally already has. Nothing else gets installed. Drive health needs `smartmontools`, which is included with Proxmox.

## Using it

Installing adds a `pvedash` command. Run `pvedash help` for the full help page.

| Command | What it does |
|---|---|
| `pvedash help` | Show the help page, including troubleshooting |
| `pvedash status` | Check that it's working, and list what it found |
| `pvedash url` | Print the address of the page |
| `pvedash logs [-f]` | Show recent service logs |
| `pvedash start`, `stop`, `restart` | Control the dashboard |
| `pvedash config` | Show the current settings |
| `pvedash set port <N>` | Move the page to another port |
| `pvedash set allow <CIDR,...\|none>` | Also allow other networks, or remove them |
| `pvedash update` | Install the latest version from GitHub |
| `pvedash uninstall` | Remove everything it installed |
| `pvedash version` | Show the installed version |

## Security

- **There's no login.** Any device on an allowed network can view the page, which shows server names, the VM list and backup status. Only the server's own subnet is allowed by default. Don't expose it to the internet.
- **It only listens on one address**, and refuses requests forwarded from a Cloudflare public hostname.
- **It's read-only.** The page has no controls, and the web server runs as an unprivileged, sandboxed user with no way to change anything.
- **The collector runs as root**, because reading SMART data requires it, but it only reads.

## What it installs

| Path | What it is |
|---|---|
| `/opt/pvedash/` | The program |
| `/etc/pvedash.conf` | Settings |
| `/usr/local/bin/pvedash` | The command |
| `/etc/systemd/system/pvedash-collector.service` | Gathers the stats |
| `/etc/systemd/system/pvedash-web.service` | Serves the page |

`pvedash uninstall` removes all of these.

## Limitations

- In a cluster, each dashboard covers only its own node, so install it on each one.
- Drives behind a hardware RAID card usually can't report health.
- If the Proxmox firewall is on, allow the port under Datacenter or Node > Firewall. The installer warns you about this.

## Development

The installer is one generated file, so don't edit `install-pvedash.sh` directly. Edit the files in `src/`, then rebuild:

```bash
python3 tests/test_collector.py
python3 build.py
```

Commit the rebuilt `install-pvedash.sh`, because that's the file the install command downloads. To release a new version, raise the number in `VERSION` first, so `pvedash update` sees it.

## License

[MIT](LICENSE)
