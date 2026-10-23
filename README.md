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
`/tmp`, and run the script there (each block uses its own folder name, so
a second run never mixes with the first). First, once per PowerShell window, in the
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

   By hand:

   ```powershell
   Write-RouterConf setup/network.conf $net; ssh-keygen -R 192.168.1.1; $d = "/tmp/bifrost-setup-$(Get-Random)"; scp -O -r setup "root@192.168.1.1:$d"; ssh -t root@192.168.1.1 "sh $d/main-router.sh"
   ```

2. **Each AP.** A factory-fresh AP boots at 192.168.1.1, the same address as
   the main router, so plug **only your PC** into it and name it:

   ```bash
   ./deploy.sh ap <hostname>
   ```

   Plug the PC into one of its **LAN** ports, not its WAN port. Its `AP_IP`
   in `APS` must be on the same subnet as `192.168.1.1` (the default
   `192.168.1.2`, `.3`, …): the PC keeps that address while the AP moves.

   It finds the AP at 192.168.1.1, configures it, and waits for its own IP (the
   session freezes mid-run, that's fine). When it says it's waiting for
   internet, plug it into the main LAN.

   **Use `ap <name>` whenever the device at 192.168.1.1 is an AP.** Bare
   `./deploy.sh` treats a factory device there as the main router.

   By hand (a factory-fresh AP at 192.168.1.1; an AP that's already set up
   uses its IP from `APS`):

   ```powershell
   Write-RouterConf setup/network.conf $net; ssh-keygen -R 192.168.1.1; $d = "/tmp/bifrost-setup-$(Get-Random)"; scp -O -r setup "root@192.168.1.1:$d"; ssh -t root@192.168.1.1 "sh $d/dumb-ap.sh <hostname>"
   ```

3. **Once every AP is up**, run the same command again. This time it reaches
   all of them and applies the addons:

   ```bash
   ./deploy.sh
   ```

   After a factory AP, the first run stops before the addons: the AP is still
   finishing and is about to reboot. Running it again is the normal flow (and
   is why this step exists).

   The Telegram bot is applied when `BOT_TOKEN` is set; WireGuard when
   `WG_PORT` is set. By hand (it also needs the APs' IPs, and asks each AP's
   root password once):

   ```powershell
   $aps = (Select-String -Path bifrost.conf -Pattern '^APS="([^"]*)"').Matches[0].Groups[1].Value; $apIps = ($aps -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -split ',')[1] }) -join ' '; Write-RouterConf addons/wifi-watch/wifi-watch.conf $watch "AP_IPS=""$apIps"""; $d = "/tmp/bifrost-wifi-watch-$(Get-Random)"; scp -O -r addons/wifi-watch "root@192.168.1.1:$d"; ssh -t root@192.168.1.1 "sh $d/install.sh"
   ```

   ```powershell
   Write-RouterConf addons/wireguard/wireguard.conf $wg; $d = "/tmp/bifrost-wireguard-$(Get-Random)"; scp -O -r addons/wireguard "root@192.168.1.1:$d"; ssh -t root@192.168.1.1 "sh $d/install.sh"
   ```

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

`add` saves `~/wg-<name>.conf` (delete it once imported). By hand:

```powershell
Write-RouterConf addons/wireguard/wireguard.conf $wg; $d = "/tmp/bifrost-wireguard-$(Get-Random)"; scp -O -r addons/wireguard "root@192.168.1.1:$d"; ssh -t root@192.168.1.1 "sh $d/install.sh client add <name>"; scp -O root@192.168.1.1:/tmp/wg-<name>.conf .; ssh root@192.168.1.1 "rm -f /tmp/wg-<name>.conf"
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
- **Passwords, no SSH keys.** `deploy.sh` tries `ROOT_PASSWORD_CURRENT` (if
  set), then `ROOT_PASSWORD`, then an empty password (what a factory image
  has), with `sshpass`. If none logs in, SSH asks (once per step on Linux,
  where the connection is reused for a minute). After the first deploy, set
  `ROOT_PASSWORD_CURRENT` to `ROOT_PASSWORD` for non-interactive runs.
- **Separate pieces.** `setup/` never references an addon, and the
  addons never touch what it owns, so each one runs on its own, in any order.
- **A router only reboots when it has to.** Each setup script hashes `uci
  export` before and after; if nothing changed, it exits without rebooting
  (and `deploy.sh` notices, instead of waiting for a reboot that is not
  coming). Re-running everything on a quiet day touches no Wi-Fi.
- **An IP change is expected.** A factory AP (or a main router moving off
  `192.168.1.1`) drops the SSH session mid-run. The script ignores the hangup
  and keeps its later output in `/tmp/main-router.log` or `/tmp/dumb-ap.log`
  on that router; `deploy.sh` waits for the new address. If a move skipped the
  addons, the next run applies them.
- **Host keys aren't pinned.** Every flash gives a router a new SSH host key,
  so pinning would break every run. `deploy.sh` only talks to your own devices
  on your LAN.

## License

[MIT](LICENSE)
