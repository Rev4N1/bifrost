# Bifrost

The bridge to and across your home network, as code. OpenWrt routers (one main
router plus dumb APs over a wired backhaul), an optional WireGuard VPN on the
main router, and an optional Telegram home/away bot, all deployed from your PC
with one command. Every step is safe to re-run, so after a firmware flash you
just run it again.

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
- **PC:** Linux with `bash`, `ssh` and `scp`, for `deploy.sh`. `sshpass` is
  recommended so even the first login to each device is silent
  (`sudo dnf install sshpass`). On Windows, do the same by hand: see
  [Windows (by hand)](#windows-by-hand).

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

## Windows (by hand)

`deploy.sh` is for Linux. On Windows, do its job by hand in PowerShell, with
Windows' own SSH client (Settings → System → Optional features → *OpenSSH
Client*). Everything that runs on the routers is the same. For each step,
`deploy.sh` writes a small config with only that router's part of
`bifrost.conf`, copies the folder to the router's `/tmp`, and runs the script
there. Below, you do the same.

SSH asks the router's root password each time (a factory-fresh router has
none). Every flash gives a router a new host key, so clear the old one first
with `ssh-keygen -R <ip>`, then answer `yes` when SSH asks about the new one.

**Once per PowerShell window,** in the repo folder, define the config writer
and the variable lists:

```powershell
function Write-RouterConf($Out, [string[]]$Vars, [string[]]$Extra = @()) {
    $lines = @(Get-Content bifrost.conf | Where-Object { $_ -match "^($($Vars -join '|'))=" }) + $Extra
    [IO.File]::WriteAllText((Join-Path $PWD $Out), ($lines -join "`n") + "`n")
}
$net   = 'SSID','WPA_PSK','COUNTRY','MOBILITY_DOMAIN','BW24','BW5','TXPOWER_24','MAIN_HOSTNAME','GW_IP','NETMASK','WAN_DEVICE','PPPOE_USER','PPPOE_PASS','MAIN_CH24','MAIN_CH5','DNS_LIST','DHCP_DNS_OPTION','UPNP','APS','ROOT_PASSWORD','ZONENAME','TIMEZONE','NTP_SERVER'
$watch = 'BOT_TOKEN','CHAT_ID','PEOPLE','PEOPLE_MAC','POLL_INTERVAL','MISSES_TO_LEAVE','CONFIRM_ROUNDS','CONFIRM_GAP','ARPING_TRIES','INITIAL_SETTLE','AP_FAIL_GRACE'
$wg    = 'WG_PORT','VPN_SUBNET','CLIENT_DNS','VPN_LAN_ACCESS','DUCKDNS_DOMAIN','DUCKDNS_TOKEN'
```

**Main router** (section 3, step 1):

```powershell
Write-RouterConf router/setup/network.conf $net; ssh-keygen -R 192.168.1.1; scp -O -r router/setup root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/setup/main-router.sh"
```

**An AP** (step 2). Factory-fresh, it's at `192.168.1.1`, with only your PC
plugged into it; already set up, use its IP from `APS`. Replace `<hostname>`
with its name in `APS`:

```powershell
Write-RouterConf router/setup/network.conf $net; ssh-keygen -R 192.168.1.1; scp -O -r router/setup root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/setup/dumb-ap.sh <hostname>"
```

**Telegram bot** (step 3). It also needs the APs' IPs, and asks each AP's root
password once:

```powershell
$aps = (Select-String -Path bifrost.conf -Pattern '^APS="([^"]*)"').Matches[0].Groups[1].Value; $apHosts = ($aps -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -split ',')[1] }) -join ' '; Write-RouterConf router/addon-wifi-watch/wifi-watch.conf $watch "AP_HOSTS=""$apHosts"""; scp -O -r router/addon-wifi-watch root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/addon-wifi-watch/install.sh"
```

**WireGuard** (step 3):

```powershell
Write-RouterConf router/addon-wireguard/wireguard.conf $wg; scp -O -r router/addon-wireguard root@192.168.1.1:/tmp/; ssh -t root@192.168.1.1 "sh /tmp/addon-wireguard/install.sh"
```

A client from PowerShell (it prints the QR code, and saves `wg-phone.conf`
here; delete it once imported). Run the WireGuard block above first if the
router rebooted since:

```powershell
ssh -t root@192.168.1.1 "sh /tmp/addon-wireguard/install.sh client add phone"; scp -O root@192.168.1.1:/tmp/wg-phone.conf .; ssh root@192.168.1.1 "rm -f /tmp/wg-phone.conf"
```

**When you're done,** delete the configs written above. They hold passwords,
and git ignores them, so nothing else will:

```powershell
Remove-Item router/setup/network.conf, router/addon-wifi-watch/wifi-watch.conf, router/addon-wireguard/wireguard.conf -ErrorAction SilentlyContinue
```

**Rollback point before a flash** (section 4):

```powershell
New-Item -ItemType Directory -Force ~\router-backups | Out-Null; foreach ($ip in '192.168.1.1','192.168.1.2','192.168.1.3') { ssh root@$ip 'sysupgrade -b /tmp/backup.tar.gz'; scp -O "root@${ip}:/tmp/backup.tar.gz" "$HOME\router-backups\backup-$ip.tar.gz" }
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

## License

[MIT](LICENSE)
