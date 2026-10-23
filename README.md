# Bifrost

The bridge to and across your home network, as code. OpenWrt routers (one main
router plus dumb APs over a wired backhaul), an optional WireGuard VPN on the
main router, and an optional Telegram home/away bot, all deployed from your PC
with one command. Every step is safe to re-run, so after a firmware flash you
just run it again.

- **Routers:** one SSID everywhere with 802.11r fast roaming, 802.11k/v
  steering and 802.11w protected management frames, `usteer` nudging devices
  to the best AP, non-overlapping channels, lower 2.4 GHz power, hardware NAT
  offload, packet steering, and optional UPnP.
- **WireGuard:** a VPN server on the main router, kept reachable by DuckDNS.
  VPN clients reach only the LAN services you list, split-tunnel by default
  (their own internet and DNS stay local). All of it is editable in LuCI.
- **Telegram bot:** tells a chat when someone's phone leaves or comes home.

## 1. What you need

- **Routers:** OpenWrt 25.12. One main router doing PPPoE, plus any number of
  dumb APs cabled to it.
- **PC:** Linux, or Windows with [Git for Windows](https://git-scm.com/download/win)
  (run everything below in **Git Bash**). Both come with what `deploy.sh`
  needs: `bash`, and OpenSSH 8.4 or newer (`ssh -V`). Nothing else to install.

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

## 3. The network

`./deploy.sh` is the whole deploy:

```bash
./deploy.sh
```

It configures or maintains everything: the main router, every AP, then the
addons whose part of `bifrost.conf` is filled in. Every step is safe to re-run,
and a router reboots only when its config actually changed. The one other form
is `./deploy.sh ap <name>` for a factory-fresh AP (step 2), which has to be
named because it boots on the main router's address.

1. **Main router.** Plug your PC into it and connect its WAN port:

   ```bash
   ./deploy.sh
   ```

   On the very first run the APs are not set up yet, so it configures the main
   router, names the APs it skipped, and leaves the addons for the next run.
   If `GW_IP` is not the factory `192.168.1.1`, this first run moves the main
   router and reboots it; run the command again at the new address to finish.

2. **Each AP.** A factory-fresh AP boots at 192.168.1.1, the same address as
   the main router, so plug **only your PC** into it and name it:

   ```bash
   ./deploy.sh ap <hostname>
   ```

   Plug the PC into one of its **LAN** ports, not its WAN port. Its `AP_IP`
   in `APS` must be on the same subnet as `GW_IP` (by default `192.168.1.2`,
   `.3`, …): the PC keeps that address while the AP moves.

   The first run sets the AP's hostname and password, moves it to its final
   address, and reboots it. It deliberately stops there: the SSH session is
   gone, so it cannot install packages or configure Wi-Fi reliably. Once it
   is back, plug it into the main LAN.

   **Use `ap <name>` whenever the device at 192.168.1.1 is an AP.** Bare
   `./deploy.sh` treats a factory device there as the main router.

3. **Once every AP is up and plugged into the main LAN**, run the same command
   again. This time it reaches all of them, finishes their package and Wi-Fi
   setup, and applies the addons:

   ```bash
   ./deploy.sh
   ```

   The first `ap` run only moved each factory AP (and set its hostname and
   password) and rebooted it. This second run is the normal one; after that,
   a re-run is just maintenance.

   The Telegram bot is applied when `BOT_TOKEN` is set; WireGuard when
   `WG_PORT` is set.

From then on, after a flash or a config change, it is always the same command:

```bash
./deploy.sh
```

**WireGuard clients** are the one thing that is not deploy. Add, list or revoke
one peer at a time from the PC:

```bash
./addons/wireguard/client.sh add <name>
./addons/wireguard/client.sh list
./addons/wireguard/client.sh revoke <name>
```

`add` saves `~/wg-<name>.conf` (delete it once imported).

See [addons/wireguard](addons/wireguard/README.md).

## 4. After every router flash

Flash with **"Keep settings"** checked, then:

```bash
./deploy.sh
```

Before flashing, take a rollback point of every router (the main and each AP
from `bifrost.conf`; the IPs below are the example ones):

```bash
stamp=$(date +%F-%H%M); mkdir -p ~/bifrost-backups/$stamp
for ip in 192.168.1.1 192.168.1.2 192.168.1.3; do
    ssh root@$ip 'sysupgrade -b /tmp/backup.tar.gz'
    scp -O "root@$ip:/tmp/backup.tar.gz" ~/bifrost-backups/$stamp/$ip.tar.gz
done
```

To roll back, flash the router with **"Keep settings"** unchecked, let it boot at
factory `192.168.1.1`, then `scp -O <file> root@192.168.1.1:/tmp/backup.tar.gz`
and run `sysupgrade -r /tmp/backup.tar.gz` on it; it comes back on its old
address with the old config.

## How it works

```
bifrost.conf.example      every setting, in the order you fill them in
deploy.sh                 the one command you run on the PC
lib/pc.sh                 PC-side helpers deploy.sh and client.sh share
setup/                    main router + dumb APs: network, wireless, dhcp, firewall
addons/
  wifi-watch/             the Telegram bot (own README)
  wireguard/              WireGuard VPN + DuckDNS on the main router, managed in LuCI
                          (client.sh adds/list/revokes peers from the PC)
```

- **Each device only gets its own part of `bifrost.conf`.** `deploy.sh` writes
  a small config for each one into a temporary copy on the PC, deleted when it
  exits, and copies it to `/tmp/bifrost-<part>` on the router. The Telegram
  token never reaches the APs, for example, and the router setup deletes its
  copy (with the root and PPPoE passwords) as soon as it finishes.
- **Passwords, no SSH keys, no prompts.** `deploy.sh` logs in with
  `ROOT_PASSWORD`, or an empty password (what a factory image has), typed by
  OpenSSH itself through `SSH_ASKPASS`. The password only lives in the
  environment of each ssh call, never on disk.
- **Separate pieces.** `setup/` never references an addon, and the
  addons never touch what it owns, so each one runs on its own, in any order.
- **A router only reboots when it has to.** Each setup script hashes `uci
  export` before and after; if nothing changed, it exits without rebooting
  (and `deploy.sh` notices, instead of waiting for a reboot that is not
  coming). Re-running everything on a quiet day touches no Wi-Fi.
- **An IP change is expected.** A factory AP (or a main router moving off
  `192.168.1.1`) drops the SSH session mid-run. The script ignores the hangup
  and keeps its later output in `/tmp/main-router.log` or `/tmp/dumb-ap.log`
  on that router; `deploy.sh` waits for the new address. A router whose
  address changes stops after the move and reboots, so the next run at the
  new address can finish it without racing the first one. A PC on the old
  subnet cannot follow a move to a different one, so the first run is
  simplest with `GW_IP=192.168.1.1` and AP IPs in `192.168.1.x`.
- **Host keys aren't pinned.** Every flash gives a router a new SSH host key,
  so pinning would break every run. `deploy.sh` only talks to your own devices
  on your LAN.

## License

[MIT](LICENSE)
