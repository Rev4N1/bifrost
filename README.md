# Bifrost

The bridge to and across your home network, as code. OpenWrt 25.12 on one
main router plus dumb APs over a wired backhaul, a Raspberry Pi Zero 2 W as
WireGuard gateway, and optional addons. One command on your PC deploys any
piece, and every piece is safe to re-run after a flash.

- **Routers:** one SSID everywhere with 802.11r/k/v/w fast roaming, `usteer`
  steering clients to the best AP, non-overlapping channels, lower 2.4 GHz
  power, hardware NAT offload, packet steering, and optional UPnP (`UPNP`),
  reinstalled after every flash.
- **Pi:** a WireGuard endpoint on the main router's USB port, locked down with
  nftables, kept reachable by DuckDNS, and stripped down for performance and
  SD-card life.
- **Addons:** a Telegram home/away notifier, and the router side of the Pi.

```
bifrost.conf.example      every setting and secret, in one file (copy to bifrost.conf)
deploy.sh                 the one command you run on the PC
router/
  setup/                  main router + dumb APs: network, wireless, dhcp, firewall
  addon-wifi-watch/       Telegram home/away notifier (optional, own README)
  addon-pi-gateway/       router side of the Pi: usb0, static lease, port forward
pi/                       the Pi: setup.sh (own README)
```

`router/setup/` never references an addon, and the addons never touch what it
owns.

## Configure

Everything lives in one git-ignored file. It's also the only file to copy
when you move to another PC.

```bash
cp -n bifrost.conf.example bifrost.conf
```

Fill in every `CHANGE_ME` in the router part. The bot and the Pi are optional:
each stays off while its key setting (`BOT_TOKEN`, `PI_MAC`) is empty. Nothing
about the layout is hard-coded: `APS` lists one `hostname,ip,ch24,ch5` entry
per dumb AP. `PI_MAC` fills itself (see [pi/README.md](pi/README.md)).

`deploy.sh` hands each device only its own part of the file, as a small
config written into a temporary copy on the PC (deleted when it exits). The
Telegram token never reaches the APs, for example, and the router password
never reaches the Pi.

## Deploy

```bash
./deploy.sh routers
```

That's the whole "after every router flash" routine: the main router, then each
AP, waiting for each reboot, then the addons in use. Each step on
its own:

```bash
./deploy.sh main
./deploy.sh ap <hostname>            # add --fresh for an AP still at factory 192.168.1.1
./deploy.sh wifi-watch
./deploy.sh pi-gateway
```

The Pi has its own walkthrough: [pi/README.md](pi/README.md).

**A factory-fresh dumb AP** boots at 192.168.1.1, the same address as the main
router. Plug only your PC into it and run `./deploy.sh ap <hostname> --fresh`.
It moves to its own IP mid-run. When it says it's waiting for internet, plug it
into the main LAN. Without internet it keeps `wpad-basic` (802.11r works,
802.11k/v doesn't); run it again later to fix that.

## Requirements

- **PC:** Linux with `bash`, `ssh` and `scp`. On Windows, `deploy.sh` runs in
  Git Bash, except `sdcard` (see [pi/README.md](pi/README.md)).
- **Routers:** OpenWrt 25.12 (`apk`).
- **Pi:** Raspberry Pi OS Lite (64-bit), Trixie, from 2025-10-20 or later.

Routers get a new SSH host key on every flash, so `deploy.sh` doesn't pin their
keys; it only talks to them on your LAN. On Linux it reuses one SSH connection
per device, so you type each password once.

## License

[MIT](LICENSE)
