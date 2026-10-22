# Bifrost

The bridge to and across your home network, as code. OpenWrt routers (one main
router plus dumb APs over a wired backhaul), an optional WireGuard VPN on the
main router, and an optional Telegram home/away bot, all deployed from your PC
with one command. Every step is safe to re-run, so after a firmware flash you just
run it again.

- **Routers:** one SSID everywhere with 802.11r/k/v/w fast roaming, `usteer`
  steering devices to the best AP, non-overlapping channels, lower 2.4 GHz
  power, hardware NAT offload, packet steering, and optional UPnP.
- **WireGuard:** a VPN server on the main router, kept reachable by DuckDNS.
  VPN clients get the internet plus only the LAN services you list. All of it
  is editable in LuCI.
- **Telegram bot:** tells a chat when someone's phone leaves or comes home.

## 1. What you need

- **Routers:** OpenWrt 25.12. One main router doing PPPoE, plus any number of
  dumb APs cabled to it.
- **PC:** Linux with `bash`, `ssh` and `scp`. `sshpass` is recommended so even
  the first login to each device is silent (`sudo dnf install sshpass`). On
  Windows, `deploy.sh` runs in Git Bash.

## 2. Configure

Every setting and secret lives in one file:

```bash
cp -n bifrost.conf.example bifrost.conf
```

Open it and go top to bottom; it's ordered the way you'd fill it in. Replace
every `CHANGE_ME`. Parts 5 (Telegram) and 6 (WireGuard) are optional and stay
off while empty. Nothing about your layout is hard-coded: part 4 lists each AP
as `hostname,ip,ch24,ch5`.

`bifrost.conf` is git-ignored and holds every password, so keep a backup
somewhere safe, like a password manager or an encrypted USB stick. It's the
only file you need to rebuild everything.

## 3. Routers

From factory-fresh routers, in this order:

1. **Main router.** Plug your PC into it and connect its WAN port:

   ```bash
   ./deploy.sh main
   ```

2. **Each AP.** A factory-fresh AP boots at 192.168.1.1, the same address as
   the main router, so plug **only your PC** into it:

   ```bash
   ./deploy.sh ap <hostname> --fresh
   ```

   It moves to its own IP mid-run (the session freezes, that's fine). When it
   says it's waiting for internet, plug it into the main LAN.

3. **The addons** whose part of `bifrost.conf` is filled in:

   ```bash
   ./deploy.sh wifi-watch
   ```

   ```bash
   ./deploy.sh wireguard
   ```

From then on, one command re-applies everything: the main router, each AP
(waiting for each reboot), then the addons in use:

```bash
./deploy.sh routers
```

**WireGuard clients:** `./deploy.sh wireguard client add <name>` prints a QR
code, or add peers in LuCI. See
[router/addon-wireguard](router/addon-wireguard/README.md).

## 4. After every router flash

Flash with **"Keep settings"** checked, then:

```bash
./deploy.sh routers
```

Before flashing, it's worth taking a rollback point of each router:

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
  addon-wireguard/        WireGuard VPN + DuckDNS on the main router, managed in LuCI
```

- **Each device only gets its own part of `bifrost.conf`.** `deploy.sh` writes
  a small config for each one into a temporary copy on the PC, deleted when it
  exits. The Telegram token never reaches the APs, for example.
- **No password prompts.** `deploy.sh` logs in with its own SSH key
  (`~/.ssh/bifrost_ed25519`, created on first run). The first time it meets a
  router, it installs that key using `ROOT_PASSWORD`. That's silent with
  `sshpass`, and asks once without it. "Keep settings" keeps the key across
  flashes.
- **Separate pieces.** `router/setup/` never references an addon, and the
  addons never touch what it owns, so each one runs on its own, in any order.
- **Host keys aren't pinned.** Every flash gives a router a new SSH host key,
  so pinning would break every run. `deploy.sh` only talks to your own devices
  on your LAN.

## Related

[Skidbladnir](https://github.com/Rev4N1/skidbladnir) turns a Raspberry Pi Zero
2 W into a pocket Tailscale exit node that works on any Wi-Fi, with nothing to
set up on the router.

## License

[MIT](LICENSE)
