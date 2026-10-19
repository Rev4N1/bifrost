# Pi Zero 2 W — WireGuard Gateway

A USB-Ethernet-only WireGuard endpoint behind the OpenWrt main router. It's
locked down with nftables, kept reachable by DuckDNS, tuned to minimize SD-card
writes, and has its radios and LED off.

- The Pi is plugged into the main router's USB port and shows up there as
  `usb0`, bridged into the LAN.
- The router side (drivers, bridge port, static lease, port forward) is
  [`router/addon-pi-gateway`](../router/addon-pi-gateway/README.md). Nothing is
  clicked in LuCI.
- **Every change is a command block, and every block is safe to re-run.** On a
  Pi built from an older version of this guide, re-running the blocks brings it
  up to date. Only the Imager step (Part 0) and moving the cable are manual.

Needs **Raspberry Pi OS Lite (64-bit), Trixie, from 2025-10-20 or later**. Those
images ship `rpi-usb-gadget`, which this guide relies on.

| What                    | Value                      |
| ----------------------- | -------------------------- |
| Pi hostname             | `pi-zero-2w`               |
| Pi LAN address          | `192.168.1.5`              |
| Pi usb0 MAC (`PI_MAC`)  | first-boot random, frozen in Part 2 → `pi-gateway.conf` |
| LAN subnet              | `192.168.1.0/24`           |
| VPN subnet / Pi address | `10.7.0.0/24` / `10.7.0.1` |
| First client            | `laptop` → `10.7.0.2`      |
| WireGuard port          | `51820/udp`                |
| DuckDNS domain          | `<yourname>.duckdns.org` (asked in Part 5) |

**The path, start to finish (about 30 minutes):**

| Part | Where | What |
|---|---|---|
| 0 | PC | Flash the card with Imager |
| 1 | PC | One block turns on USB-Ethernet mode |
| 2 | Pi, on the PC's USB | One block: plain DHCP client, pinned MACs |
| 3 | PC, then the cable | Router side in one block, then move the Pi to the router |
| 4 | Pi | Update, then strip it down (one block + reboot) |
| 5 | Pi | DuckDNS (asks for subdomain + token) |
| 6 | Pi | WireGuard server, then one block per client |
| 7 | Pi | Firewall, applied with automatic rollback |
| 8 | Pi + phone | Verify |

### Upgrading a Pi built from an older version of this guide

Just walk the guide from Part 2 on, skipping only what doesn't apply. Every
block keeps what's already right: the pinned MACs, the WireGuard keys and
peers, and the DuckDNS settings.

- **Part 2**: run the block over SSH at `192.168.1.5` (not `10.12.194.1`).
- **Part 3**: step 1 only. The Pi is already on the router, so skip moving
  the cable.
- **Parts 4, 5, 7 and 8** as written. In Part 5, press Enter at both prompts
  to keep the current values.
- **Part 6**: the server block does nothing on an existing server. Only use
  "Add a client" for new devices.

---

## Part 0 — Flash the SD card (Raspberry Pi Imager 2.x)

The only GUI step.

1. Install Raspberry Pi Imager from https://www.raspberrypi.com/software/.
2. **Device** `Raspberry Pi Zero 2 W` → **OS** `Raspberry Pi OS (other)` →
   `Raspberry Pi OS Lite (64-bit)` → **Storage**: the SD card. Double-check
   the drive; it gets wiped.
3. In **Customisation**:
   - Hostname `pi-zero-2w`.
   - Localisation: your timezone and keyboard.
   - User: a username (not `pi`) and a password.
   - Wi-Fi: **leave it unconfigured**.
   - Remote access: **enable SSH** (password authentication is fine. The
     firewall in Part 7 only allows SSH from the LAN).
   - Raspberry Pi Connect: off.
   - Interfaces & Features: if it offers **USB Gadget mode**, turn it on and
     Part 1 has nothing to do. With the standard OS list it usually isn't
     offered yet, so Part 1 handles it.
4. Write. When it finishes, **leave the card in the reader**.

---

## Part 1 — Turn on USB-Ethernet gadget mode (on the PC)

Out of the box the Pi's USB port only takes power. Gadget mode makes it a
network link too, and it has to be switched on in the card's cloud-init
`user-data` file before first boot.

Plug the card back in (Fedora mounts its `bootfs` partition automatically;
open it in Files if it didn't), then:

```bash
(
set -e
boot=$(findmnt -nro TARGET --source LABEL=bootfs | head -n1)
[ -n "$boot" ] || { echo "bootfs is not mounted - open the SD card in Files first"; exit 1; }
f="$boot/user-data"
sed -i 's/\r$//' "$f"
if ! grep -q 'enable_usb_gadget' "$f"; then
    if grep -q '^rpi:' "$f"; then
        awk '
            add { ind = match($0, /^[ \t]+[^ \t]/) ? substr($0, 1, RLENGTH - 1) : "  "
                  print ind "enable_usb_gadget: true"; add = 0 }
            { print }
            /^rpi:[ \t]*$/ { add = 1 }
            END { if (add) print "  enable_usb_gadget: true" }
        ' "$f" > "$f.new" && mv "$f.new" "$f"
    else
        [ -z "$(tail -c1 "$f")" ] || echo >> "$f"
        printf 'rpi:\n  enable_usb_gadget: true\n' >> "$f"
    fi
fi
grep -A3 '^rpi:' "$f"
sync
)
```

What it does:
- Finds where `bootfs` is mounted.
- If `user-data` already has an `rpi:` block, it adds `enable_usb_gadget: true`
  as its first line, indented like the lines already under it. YAML allows only
  one `rpi:` key and needs consistent indentation.
- If there's no `rpi:` block, it appends one.
- If the line is already there, it changes nothing.

The output should show `rpi:` with `enable_usb_gadget: true` indented under it.
Eject the card and put it in the Pi.

**On Windows**, do the same by hand. Open the `bootfs` drive, then open
`user-data` in Notepad:
- If there's an `rpi:` line, add `enable_usb_gadget: true` right under it,
  indented with the same spaces as the lines below it.
- If there isn't one, add these two lines at the end:

  ```yaml
  rpi:
    enable_usb_gadget: true
  ```

Use spaces, not tabs. Save, then eject.

---

## Part 2 — First boot over USB to the computer, and prepare for the router

There's no internet in this stage, so nothing gets installed yet.

1. Plug a cable from the Pi's **USB** port (the inner one, not `PWR`) into
   the computer. That single port powers the Pi and carries the network link.
2. Wait 2–3 minutes. First boot resizes the filesystem and reboots once.
3. On Fedora there's nothing to do: NetworkManager sees a new wired connection
   and gets an address from the Pi. Windows needs the Raspberry Pi RNDIS driver
   once (see the
   [rpi-usb-gadget README](https://github.com/raspberrypi/rpi-usb-gadget)).
4. Connect: the Pi is running in "shared" mode right now, acting as a DHCP
   server for the computer at `10.12.194.1`.

   ```bash
   ssh <user>@10.12.194.1
   ```

   If that doesn't answer, try `ssh <user>@pi-zero-2w.local`.

### Make usb0 a plain DHCP client with a fixed MAC

Two things about `rpi-usb-gadget` are wrong for a Pi that lives on a router:

- **Shared mode.** Its auto-switcher (`rpi-usb-gadget-ics`) only recognizes a
  computer's connection-sharing gateway (`192.168.137.1`, `192.168.2.1`,
  `10.42.0.1`). On the router it falls back to "shared" mode, where the Pi runs
  an authoritative DHCP server, and `usb0` is bridged into the LAN, so that
  would serve the whole house. This block stops the switcher and turns the
  shared profile into a DHCP client. Part 7 adds a firewall rule so DHCP server
  replies can never leave the Pi.
- **The MAC.** The `g_ether` driver picks random MACs on every boot unless
  they're pinned, and the router's static lease needs a fixed one. On the
  first run the block freezes the random MACs from this first boot. Every
  later run keeps whatever is already pinned. Part 3 copies the pinned MACs
  into `router/addon-pi-gateway/pi-gateway.conf` for you.

  Optional, after reflashing the SD card: to give the new install the old
  MACs (so the router lease stays valid), fill in `PI_MAC` and `HOST_MAC` on
  the first line with the values from `pi-gateway.conf`. Left empty, the Pi
  freezes new random ones, which then go into `pi-gateway.conf` in Part 3.

```bash
sudo PI_MAC= HOST_MAC= bash <<'EOF'
set -eu
systemctl disable --now rpi-usb-gadget-ics.service

nmcli connection modify "USB Gadget (shared)" connection.autoconnect yes \
    ipv4.method auto ipv4.addresses "" ipv6.method link-local
nmcli connection modify "USB Gadget (client)" connection.autoconnect no

conf=/etc/modprobe.d/usb-gadget.conf
cur_dev=$(sed -n 's/.*dev_addr=\([^ ]*\).*/\1/p' "$conf" 2>/dev/null)
cur_host=$(sed -n 's/.*host_addr=\([^ ]*\).*/\1/p' "$conf" 2>/dev/null)
dev=${PI_MAC:-${cur_dev:-$(dmesg | awk '/: MAC/ {print $NF}' | tail -n1)}}
host=${HOST_MAC:-${cur_host:-$(dmesg | awk '/: HOST MAC/ {print $NF}' | tail -n1)}}
[ -n "$dev" ] && [ -n "$host" ] || { echo "no g_ether MACs found - reboot and re-run"; exit 1; }
echo "options g_ether host_addr=$host dev_addr=$dev" > "$conf"
echo "pinned: PI_MAC=$dev HOST_MAC=$host (Part 3 copies them into pi-gateway.conf)"
EOF
```

`ipv6.method link-local` keeps an IPv6 link-local address on `usb0`. That's
the recovery path: plug the Pi back into the computer and
`ssh <user>@pi-zero-2w.local` still works.

**Never run `sudo rpi-usb-gadget on` again.** It rewrites the shared profile
back to DHCP-server mode and re-enables the switcher. If it ever happens, re-run
this block.

Don't `nmcli connection down`/`up` here, because that would kill this SSH
session. The changes take effect at the reboot in Part 3.

---

## Part 3 — Move to the router

1. On the PC, from the repo root, run this block. First replace `<user>` on
   the `PI=` line. Use `10.12.194.1` while the Pi is on the computer's USB, or
   `192.168.1.5` once it's on the router.

   ```bash
   (
   set -e
   PI='<user>@10.12.194.1'
   conf=router/addon-pi-gateway/pi-gateway.conf
   [ -f "$conf" ] || cp "$conf.example" "$conf"
   pinned=$(ssh "$PI" cat /etc/modprobe.d/usb-gadget.conf)
   pi_mac=$(echo "$pinned" | sed -n 's/.*dev_addr=\([^ ]*\).*/\1/p')
   host_mac=$(echo "$pinned" | sed -n 's/.*host_addr=\([^ ]*\).*/\1/p')
   [ -n "$pi_mac" ] && [ -n "$host_mac" ] || { echo "no pinned MACs on the Pi - run the Part 2 block first"; exit 1; }
   sed -i -e "s/^PI_MAC=\"[^\"]*\"/PI_MAC=\"$pi_mac\"/" \
          -e "s/^HOST_MAC=\"[^\"]*\"/HOST_MAC=\"$host_mac\"/" "$conf"
   echo "pi-gateway.conf: PI_MAC=$pi_mac HOST_MAC=$host_mac"
   scp -O -r router/addon-pi-gateway root@192.168.1.1:/tmp/
   ssh root@192.168.1.1 'sh /tmp/addon-pi-gateway/install.sh'
   )
   ```

   What it does:
   - Reads the pinned MACs from the Pi (`/etc/modprobe.d/usb-gadget.conf`,
     written in Part 2).
   - Writes them into `router/addon-pi-gateway/pi-gateway.conf`, creating it
     from the `.example` template first if needed. `dev_addr` becomes `PI_MAC`
     (the router's lease uses it); `host_addr` becomes `HOST_MAC` (stored only
     for reusing the MACs after a reflash).
   - Copies the addon to the router and runs it. That installs the
     USB-Ethernet drivers, bridges `usb0` into the LAN, and creates the static
     lease to `192.168.1.5` and the WireGuard port forward.

   **On Windows**, do the same in PowerShell:
   1. Run `ssh <user>@10.12.194.1 cat /etc/modprobe.d/usb-gadget.conf`.
   2. Copy `pi-gateway.conf.example` to `pi-gateway.conf` if it doesn't exist,
      then paste the `dev_addr` value into `PI_MAC` and the `host_addr` value
      into `HOST_MAC`.
   3. Run the last two lines (`scp …` and `ssh …`) as they are.

   Its check fails if the WAN address is private or CGNAT. Inbound WireGuard
   can't work then, and DuckDNS can't fix that.

2. Shut the Pi down, then move the cable from the computer to the router's USB
   port:

   ```bash
   sudo poweroff
   ```

3. After a minute, from any LAN machine:

   ```bash
   ssh <user>@192.168.1.5
   ```

   If the Pi doesn't come up, run
   `ssh root@192.168.1.1 'sh /tmp/addon-pi-gateway/install.sh --check'`. If that
   doesn't explain it, plug the Pi back into the computer,
   `ssh <user>@pi-zero-2w.local`, and look at `journalctl -u NetworkManager -b`
   and `ip addr show usb0`.

---

## Part 4 — Update, then strip it down: unused hardware off, SD writes minimized

The Pi is headless, wired, and only routes WireGuard. Everything else either
costs RAM and CPU (display stack, audio, idle consoles) or writes to the SD card
(logs, swap, man-page indexing).

```bash
sudo apt update && sudo apt full-upgrade -y && sudo apt autoremove -y
```

Then one block for everything else:

```bash
sudo bash <<'EOF'
set -eu
cfg=/boot/firmware/config.txt

# ---- SD card: nothing routine writes to it ---------------------------
# Logs in RAM only (lost on reboot: that's the trade-off). Trixie has no
# rsyslog, so this covers all logging and log2ram isn't needed.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=20M\n' > /etc/systemd/journald.conf.d/volatile.conf
systemctl restart systemd-journald
if dpkg -s log2ram >/dev/null 2>&1; then
    systemctl stop log2ram || true
    apt-get purge -y log2ram
fi
rm -f /etc/apt/sources.list.d/azlux.list /usr/share/keyrings/azlux-archive-keyring.gpg

# Swap: compressed RAM only. rpi-swap's default (zram+file) occasionally
# writes idle pages to /var/swap on the card.
mkdir -p /etc/rpi/swap.conf.d
printf '[Main]\nMechanism=zram\n' > /etc/rpi/swap.conf.d/50-zram-only.conf

# Daily man-page index rebuild: pointless writes on a headless box.
systemctl disable --now man-db.timer 2>/dev/null || true

# Pi OS already mounts / with noatime; just confirm.
findmnt -no OPTIONS / | grep -q noatime && echo "root: noatime ok" || echo "WARNING: / is not noatime"

# ---- Hardware that's never used ------------------------------------
# Bluetooth, Wi-Fi, activity LED off. No display or camera: drop the
# KMS display driver and audio, and give the GPU the minimum RAM.
systemctl disable --now bluetooth.service 2>/dev/null || true
systemctl mask --now wpa_supplicant.service
sed -i -e 's/^dtoverlay=vc4-kms-v3d/#&/' \
       -e 's/^dtparam=audio=on$/dtparam=audio=off/' \
       -e 's/^camera_auto_detect=1$/camera_auto_detect=0/' \
       -e 's/^display_auto_detect=1$/display_auto_detect=0/' "$cfg"
[ -z "$(tail -c1 "$cfg")" ] || echo >> "$cfg"     # appends start on a new line
[ "$(awk '/^\[/ {s=$0} END {print s}' "$cfg")" = "[all]" ] || echo "[all]" >> "$cfg"
for l in dtoverlay=disable-bt dtoverlay=disable-wifi \
         dtparam=act_led_trigger=none dtparam=act_led_activelow=on; do
    grep -qxF "$l" "$cfg" || echo "$l" >> "$cfg"
done
# gpu_mem=16 makes the firmware boot start_cd.elf: only set it if that's there.
if [ -f /boot/firmware/start_cd.elf ]; then
    grep -qxF gpu_mem=16 "$cfg" || echo gpu_mem=16 >> "$cfg"
else
    echo "no start_cd.elf - leaving gpu_mem at its default"
fi

# Login prompts on a screen and serial pins nobody connects to.
systemctl disable --now getty@tty1.service serial-getty@ttyAMA0.service 2>/dev/null || true

# ---- Performance ---------------------------------------------------
# Hold the CPU at full clock: lower WireGuard latency, no ramp-up on
# bursts. Costs almost nothing at idle on a Zero 2 W.
cat > /etc/systemd/system/cpu-performance.service <<'UNIT'
[Unit]
Description=CPU frequency governor: performance

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo performance > "$g"; done'

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now cpu-performance.service

# ---- Security updates install themselves ---------------------------
# Debian packages only; a new kernel still needs a manual reboot.
apt-get install -y unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    > /etc/apt/apt.conf.d/20auto-upgrades
EOF
sudo reboot
```

After reconnecting:

```bash
swapon --show                                                  # only /dev/zram0
cat /sys/class/leds/ACT/brightness                             # 0
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor   # performance
free -m                                                        # total higher than before (was 415)
```

If the LED is lit anyway, `act_led_activelow` is inverted on your board. Run
this, then reboot:

```bash
sudo sed -i 's/^dtparam=act_led_activelow=on$/dtparam=act_led_activelow=off/' /boot/firmware/config.txt
```

Kept on purpose: `avahi-daemon` (it makes `pi-zero-2w.local` resolve, which
is the USB recovery path), `cron`, and the `apt-daily` timers that
unattended-upgrades needs.

---

## Part 5 — DuckDNS

The block asks for your DuckDNS subdomain and token. Press Enter at either
prompt to keep the value already stored. The token goes to root through a pipe,
so it never appears on a command line. The update script checks the TLS
certificate, treats `KO` as a failure, and logs to the RAM journal.

```bash
sudo mkdir -p /opt/duckdns
read -rp  'DuckDNS subdomain, without .duckdns.org (Enter keeps current): ' DUCK_DOMAIN
read -rsp 'DuckDNS token (Enter keeps current): ' DUCK_TOKEN; echo
printf '%s\n%s\n' "$DUCK_DOMAIN" "$DUCK_TOKEN" | sudo sh -c '
    read -r d; read -r t
    f=/opt/duckdns/duckdns.env
    [ -f "$f" ] && . "$f"
    d=${d:-${DUCKDNS_DOMAIN:-}}; t=${t:-${DUCKDNS_TOKEN:-}}
    [ -n "$d" ] && [ -n "$t" ] || { echo "need a subdomain and a token"; exit 1; }
    umask 077
    printf "DUCKDNS_DOMAIN=%s\nDUCKDNS_TOKEN=%s\n" "$d" "$t" > "$f"
    echo "duckdns: using $d.duckdns.org"'
unset DUCK_DOMAIN DUCK_TOKEN

sudo tee /opt/duckdns/duck.sh > /dev/null <<'EOF'
#!/bin/sh
set -eu
. /opt/duckdns/duckdns.env
resp=$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=")
echo "duckdns: $resp"
[ "$resp" = "OK" ]
EOF
sudo chmod 750 /opt/duckdns/duck.sh

sudo tee /etc/systemd/system/duckdns.service > /dev/null <<'EOF'
[Unit]
Description=DuckDNS IP update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/duckdns/duck.sh
EOF

sudo tee /etc/systemd/system/duckdns.timer > /dev/null <<'EOF'
[Unit]
Description=Run DuckDNS update every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now duckdns.timer
sudo systemctl start duckdns.service
journalctl -u duckdns.service -n 3 --no-pager
```

The journal should show `duckdns: OK`.

---

## Part 6 — WireGuard

Every device has a **private key** (secret) and a **public key** derived from
it. A config lists its own private key under `[Interface]` and the other side's
public key under `[Peer]`. A **preshared key** is an extra secret, identical on
both sides.

### 1. Server (once; re-running is a no-op)

This block refuses to touch an existing `wg0.conf`. Regenerating the server key
would break every client.

```bash
sudo apt install -y wireguard qrencode
sudo bash <<'EOF'
set -eu
umask 077
cd /etc/wireguard
if [ -e wg0.conf ]; then
    echo "wg0.conf exists - leaving the server untouched"
else
    wg genkey | tee server.key | wg pubkey > server.pub
    cat > wg0.conf <<CONF
[Interface]
Address = 10.7.0.1/24
ListenPort = 51820
PrivateKey = $(cat server.key)
# nftables (Part 7) handles forwarding and NAT: no PostUp/PostDown.
CONF
fi
systemctl enable --now wg-quick@wg0
wg show wg0
EOF
```

### 2. Add a client (repeat per device)

Set `NAME` and the next free `IP`. `sudo grep AllowedIPs /etc/wireguard/wg0.conf`
lists the IPs in use. The endpoint is the DuckDNS name from Part 5. The block
refuses a name or IP that already exists, adds the peer live (no restart), and
prints the QR code for the phone app.

```bash
sudo NAME=laptop IP=10.7.0.2 bash <<'EOF'
set -eu
umask 077
cd /etc/wireguard
mkdir -p clients
grep -q "^# $NAME\$" wg0.conf && { echo "client $NAME already exists"; exit 1; }
grep -q "AllowedIPs = $IP/32" wg0.conf && { echo "$IP already used"; exit 1; }
[ -n "${ENDPOINT:-}" ] || ENDPOINT=$(. /opt/duckdns/duckdns.env 2>/dev/null && echo "$DUCKDNS_DOMAIN.duckdns.org") || true
[ -n "${ENDPOINT:-}" ] || { echo "no DuckDNS config yet - pass ENDPOINT=<yourname>.duckdns.org"; exit 1; }

wg genkey | tee "clients/$NAME.key" | wg pubkey > "clients/$NAME.pub"
wg genpsk > "clients/$NAME.psk"

cat >> wg0.conf <<CONF

[Peer]
# $NAME
PublicKey = $(cat "clients/$NAME.pub")
PresharedKey = $(cat "clients/$NAME.psk")
AllowedIPs = $IP/32
CONF

cat > "clients/$NAME.conf" <<CONF
[Interface]
PrivateKey = $(cat "clients/$NAME.key")
Address = $IP/32
DNS = 9.9.9.9, 1.1.1.1

[Peer]
PublicKey = $(cat server.pub)
PresharedKey = $(cat "clients/$NAME.psk")
Endpoint = $ENDPOINT:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF

wg syncconf wg0 <(wg-quick strip wg0)
qrencode -t ansiutf8 < "clients/$NAME.conf"
EOF
```

- **Phone:** in the WireGuard app, **+** → **Scan from QR code**. Enlarge the
  terminal if the code is cut off.
- **Computer:** copy the file over, then delete the temporary copy:

  ```bash
  sudo install -m 600 -o "$USER" /etc/wireguard/clients/laptop.conf ~/laptop.conf
  ```
  ```bash
  scp <user>@192.168.1.5:laptop.conf ~/
  ssh <user>@192.168.1.5 'rm ~/laptop.conf'
  sudo nmcli connection import type wireguard file ~/laptop.conf && rm ~/laptop.conf
  ```
  On Fedora the last line imports it as a NetworkManager connection: toggle it
  from the network menu, or `nmcli connection up laptop`. On Windows, run the
  `scp` and `ssh` lines in PowerShell, then use **Import tunnel(s) from file**
  in the WireGuard app. Either way, delete the file afterwards: it contains the
  client's private key.

Client config notes:

- `AllowedIPs = 0.0.0.0/0, ::/0` sends all traffic through the tunnel.
  `::/0` stops IPv6 leaking around the tunnel; the Pi doesn't forward IPv6, so
  apps fall back to IPv4. For LAN-only access, use
  `AllowedIPs = 10.7.0.0/24, 192.168.1.0/24` instead.
- `DNS` is public because Part 7 blocks VPN clients from the LAN, including
  the router's DNS.

Once a client is imported everywhere, its private key isn't needed on the Pi:

```bash
sudo rm -f /etc/wireguard/clients/laptop.key /etc/wireguard/clients/laptop.conf
```

**Revoke a client:**

```bash
sudo NAME=laptop bash <<'EOF'
set -eu
cd /etc/wireguard
awk -v n="# $NAME" '
    /^\[Peer\]/ { if (blk != "" && !drop) printf "%s", blk; blk = $0 "\n"; drop = 0; inpeer = 1; next }
    inpeer      { blk = blk $0 "\n"; if ($0 == n) drop = 1; next }
                { print }
    END         { if (blk != "" && !drop) printf "%s", blk }
' wg0.conf > wg0.conf.new && mv wg0.conf.new wg0.conf && chmod 600 wg0.conf
rm -f clients/$NAME.*
wg syncconf wg0 <(wg-quick strip wg0)
wg show wg0 peers
EOF
```

---

## Part 7 — Firewall (nftables) + IP forwarding

Rewrites `/etc/nftables.conf` completely, so re-running it always converges.
Rules for other services on the Pi (for example a web dashboard on port 8080)
go in their own file in `/etc/nftables.d/`, which this config includes, so this
block never wipes them.

```bash
sudo apt install -y nftables
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-wireguard-forward.conf
sudo sysctl --system >/dev/null
sudo mkdir -p /etc/nftables.d
sudo tee /etc/nftables.conf > /dev/null <<'EOF'
#!/usr/sbin/nft -f
# Managed by PI_ZERO_SETUP.md Part 7 - re-running that block overwrites this.
# Extra rules go in /etc/nftables.d/*.nft (included at the end).

define IFACE      = "usb0"
define SERVER_IP  = 192.168.1.5
define LAN_SUBNET = 192.168.1.0/24

define WG_IFACE   = "wg0"
define VPN_SUBNET = 10.7.0.0/24
define WG_PORT    = 51820

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept
        # IPv6 neighbour discovery, ahead of the invalid check (ND isn't tracked)
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept
        ct state established,related accept
        ct state invalid drop

        # LAN -> Pi (SSH, management)
        iifname $IFACE ip saddr $LAN_SUBNET ip daddr $SERVER_IP accept

        # USB-to-computer recovery: SSH over IPv6 link-local, and mDNS so
        # pi-zero-2w.local resolves (on the LAN too)
        iifname $IFACE ip6 saddr fe80::/10 tcp dport 22 accept
        iifname $IFACE udp dport 5353 accept

        # WireGuard handshakes
        iifname $IFACE udp dport $WG_PORT accept

        # VPN peers -> Pi itself
        iifname $WG_IFACE ip saddr $VPN_SUBNET accept
    }

    chain output {
        type filter hook output priority 0; policy drop;

        # Never act as a DHCP server on the LAN (see Part 2)
        oifname $IFACE udp sport 67 drop

        oifname "lo" accept
        ct state established,related accept
        oifname $IFACE accept
        oifname $WG_IFACE ip daddr $VPN_SUBNET accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop

        # VPN -> LAN: only what /etc/nftables.d/vpn-lan-access.nft allows

        # VPN -> internet, not the rest of the LAN
        iifname $WG_IFACE ip saddr $VPN_SUBNET ip daddr != $LAN_SUBNET oifname $IFACE accept
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip saddr $VPN_SUBNET oifname $IFACE masquerade
    }
}

include "/etc/nftables.d/*.nft"
EOF
sudo nft -c -f /etc/nftables.conf && echo "syntax ok"
```

The rules match interfaces by name, so the ruleset loads at boot before `wg0`
exists.

### Let VPN clients reach specific LAN services

By default VPN clients reach the internet and the Pi, but nothing else on the
LAN. To open specific services, list them in your own
`/etc/nftables.d/vpn-lan-access.nft`, one rule per line. It lives only on the
Pi, so your LAN layout never ends up in this repo. Re-running the block
rewrites it with whatever you list.

```bash
sudo tee /etc/nftables.d/vpn-lan-access.nft > /dev/null <<'EOF'
table inet filter {
    chain forward {
        # example - replace with your hosts:  ip daddr <LAN IP>  tcp|udp dport <port>
        iifname "wg0" ip saddr 10.7.0.0/24 ip daddr 192.168.1.20 tcp dport 3389 accept
    }
}
EOF
sudo nft -c -f /etc/nftables.conf && echo "syntax ok"
```

VPN traffic is masqueraded, so those hosts see it coming from `192.168.1.5`.
Give them static IPs. Rules for anything else running on the Pi, such as a web
dashboard, go in another file in `/etc/nftables.d/` the same way.

### Apply with automatic rollback

You're connected over `usb0`, the interface these rules govern. This block
loads the rules with a two-minute "flush everything" timer as a safety net:

```bash
sudo systemctl stop nft-rollback.timer 2>/dev/null || true
sudo systemd-run --on-active=120 --unit=nft-rollback nft flush ruleset
sudo nft -f /etc/nftables.conf
```

Within two minutes, open a **new** SSH session to `192.168.1.5`. If it connects,
make the rules permanent:

```bash
sudo systemctl stop nft-rollback.timer
sudo systemctl enable --now nftables
sudo systemctl reload nftables
```

If the new session can't connect, wait the two minutes (the rules get flushed),
then fix whatever went wrong and run the apply block again.

---

## Part 8 — Verify

On the Pi:

```bash
ip -br addr show usb0                                  # 192.168.1.5, pinned MAC
systemctl is-enabled rpi-usb-gadget-ics.service        # disabled
swapon --show                                          # only /dev/zram0
sudo wg show                                           # wg0 up, peers listed
sudo nft list ruleset | head -n 5                      # table inet filter loaded
systemctl is-active nftables wg-quick@wg0 duckdns.timer
cat /proc/sys/net/ipv4/ip_forward                      # 1
```

From the PC: `ssh root@192.168.1.1 'sh /tmp/addon-pi-gateway/install.sh --check'`.

From a client **on mobile data** (not home Wi-Fi):

- The tunnel connects: `sudo wg show` on the Pi shows a recent handshake.
- Internet works through the tunnel: your public IP (e.g. on ifconfig.me) is
  your home IP.
- The services listed in `vpn-lan-access.nft` are reachable.
- Everything else on `192.168.1.0/24` is blocked.
