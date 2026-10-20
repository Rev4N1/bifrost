# Bifrost

The bridge to and across your home network, as code. OpenWrt routers (one main
router plus dumb APs over a wired backhaul), an optional Raspberry Pi Zero 2 W
as WireGuard gateway, and an optional Telegram home/away bot, all deployed from
your PC with one command. Every step is safe to re-run, so after a firmware
flash you just run it again.

- **Routers:** one SSID everywhere with 802.11r/k/v/w fast roaming, `usteer`
  steering devices to the best AP, non-overlapping channels, lower 2.4 GHz
  power, hardware NAT offload, packet steering, and optional UPnP.
- **Pi:** a WireGuard endpoint on the main router's USB port, locked down with
  nftables, kept reachable by DuckDNS, and stripped down to what it uses, for
  free RAM and SD-card life.
- **Telegram bot:** tells a chat when someone's phone leaves or comes home.

## 1. What you need

- **Routers:** OpenWrt 25.12. One main router doing PPPoE, plus any number of
  dumb APs cabled to it.
- **PC:** Linux with `bash`, `ssh` and `scp`. `sshpass` is recommended so even
  the first login to each device is silent (`sudo dnf install sshpass`). On
  Windows, `deploy.sh` runs in Git Bash.
- **Pi (optional):** a Raspberry Pi Zero 2 W with Raspberry Pi OS Lite
  (64-bit), Trixie, from 2025-10-20 or later.

## 2. Configure

Every setting and secret lives in one file:

```bash
cp -n bifrost.conf.example bifrost.conf
```

Open it and go top to bottom; it's ordered the way you'd fill it in. Replace
every `CHANGE_ME`. Parts 5 (Telegram) and 6 (Pi) are optional and stay off
while empty. Nothing about your layout is hard-coded: part 4 lists each AP as
`hostname,ip,ch24,ch5`.

`bifrost.conf` is git-ignored and holds every password, so keep a backup
somewhere safe, like a password manager or an encrypted USB stick. It's the
only file you need to rebuild everything.

## 3. Routers

```bash
./deploy.sh routers
```

This sets up the main router, then each AP (waiting for each reboot), then the
addons whose part of the config is filled in. Each piece also runs on its own:

```bash
./deploy.sh main
./deploy.sh ap <hostname>
./deploy.sh wifi-watch
./deploy.sh pi-gateway
```

**A factory-fresh AP** boots at 192.168.1.1, the same address as the main
router. Plug only your PC into it and run `./deploy.sh ap <hostname> --fresh`.
It moves to its own IP mid-run. When it says it's waiting for internet, plug it
into the main LAN.

## 4. Pi (optional)

Follow [pi/README.md](pi/README.md). It's about 20 minutes, mostly waiting.

## 5. After every router flash

Flash with **"Keep settings"** checked, then:

```bash
./deploy.sh routers
```

The Pi doesn't need anything. Before flashing, it's worth taking a rollback
point of each router:

```bash
mkdir -p ~/router-backups && for ip in 192.168.1.1 192.168.1.2 192.168.1.3; do ssh -i ~/.ssh/bifrost_ed25519 root@$ip 'sysupgrade -b /tmp/backup.tar.gz' && scp -O -i ~/.ssh/bifrost_ed25519 root@$ip:/tmp/backup.tar.gz ~/router-backups/backup-$ip.tar.gz; done
```

## How it works

```
bifrost.conf.example      every setting, in the order you fill them in
deploy.sh                 the one command you run on the PC (./deploy.sh for help)
router/
  setup/                  main router + dumb APs: network, wireless, dhcp, firewall
  addon-wifi-watch/       the Telegram bot (own README)
  addon-pi-gateway/       the router side of the Pi: usb0, static lease, port forward
pi/                       the Pi itself: setup.sh (own README)
```

- **Each device only gets its own part of `bifrost.conf`.** `deploy.sh` writes
  a small config for each one into a temporary copy on the PC, deleted when it
  exits. The Telegram token never reaches the APs, for example, and the router
  password never reaches the Pi.
- **No password prompts.** `deploy.sh` logs in with its own SSH key
  (`~/.ssh/bifrost_ed25519`, created on first run). The first time it meets a
  device, it installs that key using `ROOT_PASSWORD` or `PI_PASSWORD`. That's
  silent with `sshpass`, and asks once without it. "Keep settings" keeps the
  key across flashes, and on the Pi `sudo` is answered from `PI_PASSWORD` too.
- **Separate pieces.** `router/setup/` never references an addon, and the
  addons never touch what it owns, so each one runs on its own, in any order.
- **Host keys aren't pinned.** Every flash gives a router a new SSH host key,
  so pinning would break every run. `deploy.sh` only talks to your own devices
  on your LAN.

## License

[MIT](LICENSE)
