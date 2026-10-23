# Bifrost

The bridge to and across your home network, as code. OpenWrt routers (one main
router plus dumb APs over a wired backhaul), an optional WireGuard VPN on the
main router, and an optional Telegram home/away bot, all deployed from your PC
with one command. Every step is safe to re-run, so after a firmware flash you
just run it again.

- **Routers:** one SSID everywhere with 802.11r fast roaming, 802.11k/v
  steering and 802.11w protected management frames, `usteer` nudging devices
  to the best AP, explicit channels, lower 2.4 GHz power, hardware NAT
  offload, packet steering, and optional UPnP.
- **WireGuard:** a VPN server on the main router, kept reachable by DuckDNS.
  VPN clients reach only the LAN services you list and route only those
  through the tunnel (full tunnel when none are listed). All of it is
  editable in LuCI.
- **Telegram bot:** tells a chat when someone's phone leaves or comes home.

The whole design is IPv4-only on the LAN and WAN, and targets **OpenWrt 25.12**
(the first apk-based release). Older opkg images are rejected before anything
is changed.

## 1. What you need

- **Routers:** OpenWrt 25.12. One main router doing PPPoE, plus any number of
  dumb APs cabled to it.
- **PC:** Linux, or Windows with [Git for Windows](https://git-scm.com/download/win)
  (run everything below in **Git Bash**). Both need only `bash` and OpenSSH
  8.4 or newer (`ssh -V`); `deploy.sh` checks the rest.

## 2. Configure

Every setting and secret lives in one file:

```bash
cp -n bifrost.conf.example bifrost.conf
```

Open it and go top to bottom; it is ordered the way you fill it in. Replace
every `CHANGE_ME`. Parts 5 (Telegram) and 6 (WireGuard) are optional and stay
off while empty. Nothing about your layout is hard-coded: part 4 lists each AP
as `hostname,ip,ch24,ch5`.

`bifrost.conf` is git-ignored and holds every password, so keep a backup
somewhere safe, like a password manager or an encrypted USB stick. It is the
only file you need to rebuild everything.

Before changing a router, validate the file and prove every address answers:

```bash
./deploy.sh check
```

## 3. First deployment

### Main router

Plug your PC into a **LAN** port, connect the WAN port to the modem, then:

```bash
./deploy.sh
```

On the very first run the APs are not set up yet, so it configures the main
router, names the APs it skipped, and leaves the addons for the next run. If
`GW_IP` is not the factory `192.168.1.1`, this first run moves the main router
and reboots it; run the command again at the new address to finish.

### Each AP

A factory-fresh AP boots at `192.168.1.1`, the same address as the main router,
so plug **only your PC** into one of its **LAN** ports (not its WAN port) and
name it:

```bash
./deploy.sh ap <hostname>
```

Its `AP_IP` in `APS` must be on the same subnet as `GW_IP` (by default
`192.168.1.2`, `.3`, …): the PC keeps that address while the AP moves.

The first run sets the AP's hostname and password, moves it to its final
address, and reboots it. It deliberately stops there: the SSH session is gone,
so it cannot install packages or configure Wi-Fi reliably. Once it is back,
plug it into the main LAN.

**Use `ap <name>` whenever the device at 192.168.1.1 is an AP.** Bare
`./deploy.sh` treats a factory device there as the main router.

### Finish

Once every AP is up and plugged into the main LAN, run the normal command
again:

```bash
./deploy.sh
```

This reaches all of them, finishes their package and Wi-Fi setup, and applies
the addons. The Telegram bot is applied when `BOT_TOKEN` is set; WireGuard
when `WG_PORT` is set.

## 4. Day-to-day

After a flash or a config change, it is always the same command:

```bash
./deploy.sh
```

A router reboots only when its `uci` config actually changed. Re-running on a
quiet day touches no Wi-Fi.

Useful companions:

```bash
./deploy.sh check    # validate bifrost.conf, reach every router, change nothing
./deploy.sh backup   # sysupgrade backup of every router -> ~/bifrost-backups/<timestamp>/
```

**WireGuard clients** are the one thing that is not deploy. Add, list or revoke
one peer at a time from the PC:

```bash
./addons/wireguard/client.sh add <name>
./addons/wireguard/client.sh list
./addons/wireguard/client.sh revoke <name>
```

`add` saves `~/wg-<name>.conf` (delete it once imported). See
[addons/wireguard](addons/wireguard/README.md).

The Telegram bot has its own operating notes in
[addons/wifi-watch](addons/wifi-watch/README.md).

## 5. What gets configured

**Main router**

- PPPoE WAN on `WAN_DEVICE`, static LAN on `GW_IP/NETMASK`, IPv6 off.
- `dnsmasq` for DHCP and DNS; upstreams are exactly `DNS_LIST` when set, and
  DHCP clients always get the router as their resolver. `odhcpd` is removed
  from the config and disabled.
- Hardware flow offloading and packet steering.
- `usteer` on the LAN, `NTP_SERVER`, timezone, hostname and root password.
- Optional UPnP/NAT-PMP with IPv6 disabled.

**Dumb APs**

- The WAN port joins the LAN bridge; static `AP_IP`, gateway and DNS point at
  the main router; IPv6 off.
- `dnsmasq`, `odhcpd` and `firewall` are stopped, disabled, and their configs
  emptied. The main router owns DHCP, DNS and routing.
- Wi-Fi is rebuilt from `APS`, not patched: stale or factory `wifi-iface`
  sections on managed radios are removed. A 6 GHz or unknown radio is
  explicitly disabled rather than left running an old SSID.

**Wireless, on every router**

- One `psk2` SSID, 2.4 GHz and 5 GHz only, with `BW24`/`BW5` widths and the
  configured channels.
- 802.11r with over-the-air FT, 802.11k/v, optional 802.11w, a one-hour group
  rekey, and no low-ACK disconnects.
- 2.4 GHz power from `TXPOWER_24` (1-30 dBm), empty for the regulatory max.

**Addons**

- `wifi-watch` installs its own SSH key on the APs and queries hostapd for
  associated stations. It never changes network, wireless, DHCP or firewall
  config.
- `wireguard` seeds `wg0`, a `vpn` firewall zone, WAN UDP, and optional
  DuckDNS once; after that, LuCI owns it.

## 6. Layout

```
bifrost.conf.example      every setting, in the order you fill them in
deploy.sh                 the one command you run on the PC
lib/pc.sh                 PC-side helpers deploy.sh and client.sh share
router/
  common.sh               shared system, connectivity, usteer, wireless
  main.sh                 PPPoE gateway, DNS/DHCP, firewall, UPnP
  ap.sh                   dumb AP: bridge, static IP, no services
addons/
  wifi-watch/             Telegram bot (own README)
  wireguard/              VPN server + DuckDNS, managed in LuCI (own README)
```

- **Each device only gets its own part of `bifrost.conf`.** `deploy.sh` writes
  a small config for each one into a temporary copy on the PC, deleted when it
  exits, and copies it to `/tmp/bifrost-router` on the router. The Telegram
  token never reaches the APs, for example, and the router setup deletes its
  copy (with the root and PPPoE passwords) as soon as it finishes.
- **Passwords, no SSH keys, no prompts.** `deploy.sh` logs in with
  `ROOT_PASSWORD`, or an empty password (what a factory image has), typed by
  OpenSSH itself through `SSH_ASKPASS`. The password only lives in the
  environment of each ssh call, never on disk.
- **Separate pieces.** `router/` never references an addon, and the addons
  never touch what it owns, so each one runs on its own, in any order.
- **A router only reboots when it has to.** Each setup script hashes `uci
  export` before and after; if nothing changed, it exits without rebooting
  (and `deploy.sh` notices, instead of waiting for a reboot that is not
  coming).
- **An IP change is expected.** A factory AP (or a main router moving off
  `192.168.1.1`) drops the SSH session mid-run. The script ignores the hangup
  and keeps its later output in `/tmp/main-router.log` or `/tmp/dumb-ap.log`
  on that router; `deploy.sh` waits for the new address. A router whose
  address changes stops after the move and reboots, so the next run at the
  new address can finish it without racing the first one.
- **Host keys are not pinned.** Every flash gives a router a new SSH host key,
  so pinning would break every run. `deploy.sh` only talks to your own devices
  on your LAN.

## 7. Security notes

- `bifrost.conf` is the crown jewel: it has the root password, PPPoE login,
  Telegram token and DuckDNS token. Keep it out of git (it is ignored) and
  back it up encrypted. On Linux, `deploy.sh` warns if its mode is not `600`.
- The routers use password authentication over SSH, on the LAN only. There is
  no WAN SSH exposure in this repo; do not add one without key authentication.
- `wifi-watch` keeps a private key at `/root/.ssh/wifi-watch` on the main
  router and its public half in each AP's `authorized_keys`. It is a
  read-only query key for `hostapd`, but it is still a key: remove it with
  `install.sh --uninstall` ([addons/wifi-watch](addons/wifi-watch/README.md)) if you stop using the addon.
- The WireGuard addon keeps each client's private key on the router so LuCI
  can show its config and QR code later. That is convenient, not ideal. If
  you do not need LuCI QR codes, delete the peer's `private_key` after
  importing the config on the client; the tunnel keeps working.
- UPnP is off by default. Turning it on lets LAN applications open WAN ports
  without asking; enable it only if you need it.

## 8. Troubleshooting

**`apk: not found`, or the setup stops on the version check.** The repo is for
OpenWrt 25.12. Flash 25.12 first; older opkg images are intentionally refused.

**An AP is not reachable.** Run `./deploy.sh check`; it prints the expected
hostname for each address. A factory AP at `192.168.1.1` must be handled with
`./deploy.sh ap <name>` while only your PC is plugged into it. A configured AP
that does not answer at its `APS` address is skipped, and the addons wait for
the next run.

**Wi-Fi clients reconnect around an AP.** `hostapd` can log `nl80211: kernel
reports: key addition failed` during a roam; the client normally reassociates
immediately. It is usually a client that kept an old key, not a broken AP.
Check `logread -e hostapd` on the AP the client landed on. If one client
reconnects constantly, try disabling randomized MAC/private Wi-Fi address for
that SSID on the client, or move it off a DFS channel.

**5 GHz feels slow or drops.** 80 MHz channels overlap easily with three APs.
Use a different 80 MHz block per AP (`36`, `52`, `100`, `149`), and remember
that `52`/`100` are DFS: a radar event makes the AP leave the channel for a
minute. `149` is non-DFS in most countries but may be restricted to low power.
The router applies `COUNTRY`, so only legal channels will come up.

**WireGuard connects but nothing on the LAN is reachable.** VPN traffic to the
LAN is not NAT'd, so hosts see the client's `10.7.0.x` address; a host firewall
that only allows its local subnet needs `VPN_SUBNET` allowed too. Also check
`VPN_LAN_ACCESS`: only those `ip:proto:port` services are opened. Inbound
WireGuard needs a public WAN address; `addons/wireguard/install.sh --check`
warns on CGNAT and private WAN addresses.

**The Telegram bot says someone left while they are home.** Check
`logread -e wifi-watch` on the main router. `WARN: AP <ip> unreachable` means
the association signal is degraded and departures are held (up to
`AP_FAIL_GRACE` polls); `HOLD:` is the same condition during confirmation.
`wifi-where.sh` shows which AP each mapped device is on, and
`install.sh --check` ([addons/wifi-watch](addons/wifi-watch/README.md)) tests the key on every AP.

**A deploy stopped halfway.** Fix the reported setting or connection and run
`./deploy.sh` again. Every step is idempotent; a router that already moved to
its new address is picked up there.

## License

[MIT](LICENSE)
