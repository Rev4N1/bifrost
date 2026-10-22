# Bifrost

The bridge to and across your home network, as code. OpenWrt routers (one main
router plus dumb APs over a wired backhaul), an optional WireGuard VPN on the
main router, and an optional Telegram home/away bot, all deployed from your PC
with one command. Every step is safe to re-run, so after a firmware flash you
just run it again.

- **Routers:** one SSID everywhere with 802.11r/k/v/w fast roaming, `usteer`
  steering devices to the best AP, non-overlapping channels, lower 2.4 GHz
  power, hardware NAT offload, packet steering, a 1000-name DNS cache, and
  optional UPnP.
- **WireGuard:** a VPN server on the main router, kept reachable by DuckDNS.
  VPN clients get the internet plus only the LAN services you list. All of it
  is editable in LuCI.
- **Telegram bot:** tells a chat when someone's phone leaves or comes home.

## 1. What you need

- **Routers:** OpenWrt 25.12. One main router doing PPPoE, plus any number of
  dumb APs cabled to it.
- **PC:** Linux with `bash`, `ssh` and `scp`, for `deploy.sh`. `sshpass` is
  recommended so it types the routers' password for you
  (`sudo dnf install sshpass`). Every step also shows how to do it by hand in
  PowerShell, with the OpenSSH client (`ssh`, `scp`).

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

**By hand,** each step does what `deploy.sh` does: write a small config with
only that router's part of `bifrost.conf`, copy the folder to the router's
`/tmp`, and run the script there. First, once per PowerShell window, in the
repo folder, define the config writer and each step's settings:

```powershell
function Write-RouterConf($Out, [string[]]$Vars, [string[]]$Extra = @()) {
    $lines = @(Get-Content bifrost.conf | Where-Object { $_ -match "^($($Vars -join '|'))=" }) + $Extra
    [IO.File]::WriteAllText((Join-Path $PWD $Out), ($lines -join "`n") + "`n")
}
$net   = 'SSID','WPA_PSK','COUNTRY','MOBILITY_DOMAIN','BW24','BW5','TXPOWER_24','MAIN_HOSTNAME','GW_IP','NETMASK','WAN_DEVICE','PPPOE_USER','PPPOE_PASS','MAIN_CH24','MAIN_CH5','DNS_LIST','DHCP_DNS_OPTION','UPNP','APS','ROOT_PASSWORD','ZONENAME','TIMEZONE','NTP_SERVER'
$watch = 'BOT_TOKEN','CHAT_ID','PEOPLE','PEOPLE_MAC','POLL_INTERVAL','MISSES_TO_LEAVE','CONFIRM_ROUNDS','CONFIRM_GAP','ARPING_TRIES','INITIAL_SETTLE','AP_FAIL_GRACE'
$wg    = 'WG_PORT','VPN_SUBNET','CLIENT_DNS','VPN_LAN_ACCESS','DUCKDNS_DOMAIN','DUCKDNS_TOKEN'
```

By hand, SSH asks the router's root password each time (a factory-fresh router
has none). Every flash gives a router a new host key: the commands clear the
old one with `ssh-keygen -R`, then answer `yes` when SSH asks about the new
one.

## 3. Routers

From factory-fresh routers, in this order:

1. **Main router.** Plug your PC into it and connect its WAN port:

   ```bash
   ./deploy.sh main
   ```

   By hand:

   ```powershell
   Write-RouterConf setup/network.conf $net; ssh-keygen -R 192.168.1.1; scp -O -r setup root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/setup/main-router.sh"
   ```

2. **Each AP.** A factory-fresh AP boots at 192.168.1.1, the same address as
   the main router, so plug **only your PC** into it:

   ```bash
   ./deploy.sh ap <hostname> --fresh
   ```

   By hand (an AP that's already set up: its IP from `APS` instead of
   `192.168.1.1`):

   ```powershell
   Write-RouterConf setup/network.conf $net; ssh-keygen -R 192.168.1.1; scp -O -r setup root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/setup/dumb-ap.sh <hostname>"
   ```

   It moves to its own IP mid-run (the session freezes, that's fine). When it
   says it's waiting for internet, plug it into the main LAN.

3. **The addons** whose part of `bifrost.conf` is filled in. The Telegram bot:

   ```bash
   ./deploy.sh wifi-watch
   ```

   By hand (it also needs the APs' IPs, and asks each AP's root password
   once):

   ```powershell
   $aps = (Select-String -Path bifrost.conf -Pattern '^APS="([^"]*)"').Matches[0].Groups[1].Value; $apHosts = ($aps -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -split ',')[1] }) -join ' '; Write-RouterConf addons/wifi-watch/wifi-watch.conf $watch "AP_HOSTS=""$apHosts"""; scp -O -r addons/wifi-watch root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/wifi-watch/install.sh"
   ```

   WireGuard:

   ```bash
   ./deploy.sh wireguard
   ```

   By hand:

   ```powershell
   Write-RouterConf addons/wireguard/wireguard.conf $wg; scp -O -r addons/wireguard root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/wireguard/install.sh"
   ```

From then on, one command re-applies everything: the main router, each AP
(waiting for each reboot), then the addons in use. By hand, that's the blocks
above, in the same order.

```bash
./deploy.sh routers
```

**WireGuard clients:** add peers in LuCI, or print a QR code (it also saves
`wg-<name>.conf`; delete it once imported):

```bash
./deploy.sh wireguard client add <name>
```

By hand (after the WireGuard block above, if the router rebooted since):

```powershell
ssh -t root@192.168.1.1 "sh /tmp/wireguard/install.sh client add <name>"; scp -O root@192.168.1.1:/tmp/wg-<name>.conf .; ssh root@192.168.1.1 "rm -f /tmp/wg-<name>.conf"
```

See [addons/wireguard](addons/wireguard/README.md).

**By hand, when you're done,** delete the configs the blocks wrote. They hold
passwords, and git ignores them, so nothing else will:

```powershell
Remove-Item setup/network.conf, addons/wifi-watch/wifi-watch.conf, addons/wireguard/wireguard.conf -ErrorAction SilentlyContinue
```

## 4. After every router flash

Flash with **"Keep settings"** checked, then:

```bash
./deploy.sh routers
```

Before flashing, it's worth taking a rollback point of each router:

```bash
mkdir -p ~/router-backups && for ip in 192.168.1.1 192.168.1.2 192.168.1.3; do ssh root@$ip 'sysupgrade -b /tmp/backup.tar.gz' && scp -O root@$ip:/tmp/backup.tar.gz ~/router-backups/backup-$ip.tar.gz; done
```

By hand:

```powershell
New-Item -ItemType Directory -Force ~\router-backups | Out-Null; foreach ($ip in '192.168.1.1','192.168.1.2','192.168.1.3') { ssh root@$ip 'sysupgrade -b /tmp/backup.tar.gz'; scp -O "root@${ip}:/tmp/backup.tar.gz" "$HOME\router-backups\backup-$ip.tar.gz" }
```

## How it works

```
bifrost.conf.example      every setting, in the order you fill them in
deploy.sh                 the one command you run on the PC (./deploy.sh for help)
setup/                    main router + dumb APs: network, wireless, dhcp, firewall
addons/
  wifi-watch/             the Telegram bot (own README)
  wireguard/              WireGuard VPN + DuckDNS on the main router, managed in LuCI
```

- **Each device only gets its own part of `bifrost.conf`.** `deploy.sh` writes
  a small config for each one into a temporary copy on the PC, deleted when it
  exits. The Telegram token never reaches the APs, for example.
- **Passwords, no SSH keys.** `deploy.sh` logs in with `ROOT_PASSWORD`. With
  `sshpass` installed it types it for you; without it, SSH asks (once per
  step on Linux, where the connection is reused for a minute). A
  factory-fresh router has no password, so it asks nothing.
- **Separate pieces.** `setup/` never references an addon, and the
  addons never touch what it owns, so each one runs on its own, in any order.
- **Host keys aren't pinned.** Every flash gives a router a new SSH host key,
  so pinning would break every run. `deploy.sh` only talks to your own devices
  on your LAN.

## License

[MIT](LICENSE)
