# Pi Zero 2 W — WireGuard gateway

A WireGuard endpoint that plugs into the main router's USB port and shows up
there as `usb0`, bridged into the LAN. No Wi-Fi, no extra cables, no power
supply. Everything on the Pi is done by `setup.sh`, which `deploy.sh` copies
over with the Pi part of your `bifrost.conf`, runs, and deletes. Every step
is safe to re-run.

## First time (about 20 minutes)

In `bifrost.conf`, fill in the Pi part: `PI_USER` and `PI_PASSWORD` (the user
you create in step 1), your DuckDNS subdomain and token, and optionally the LAN
services VPN clients may reach (`VPN_LAN_ACCESS`). With the password there,
`deploy.sh` installs its own SSH key on the Pi once and answers `sudo`, so it
never asks. Install `sshpass` (`sudo dnf install sshpass`) for that first
login to be silent too.

1. **Flash** with Raspberry Pi Imager 2.x: *Raspberry Pi Zero 2 W* →
   *Raspberry Pi OS Lite (64-bit)* (Trixie). In Customisation, set the
   hostname, a user and password, and **enable SSH**. Leave Wi-Fi
   unconfigured.

2. **Turn on USB-Ethernet mode.** With the card still in the PC:

   ```bash
   ./deploy.sh sdcard
   ```

   This adds `enable_usb_gadget: true` under `rpi:` in the card's `user-data`.
   Without it, the Pi's USB port only takes power.

3. **Boot it on your PC.** Use a cable from the Pi's **USB** port (the inner
   one, not `PWR`) to the PC, and wait 2–3 minutes. The Pi now serves the PC an
   address and answers at `10.12.194.1`. Fedora needs nothing; Windows needs the
   [Raspberry Pi RNDIS driver](https://github.com/raspberrypi/rpi-usb-gadget)
   once.

4. **Prepare it for the router, and the router for it:**

   ```bash
   ./deploy.sh pi --usb network
   ./deploy.sh pi-gateway --usb
   ```

   The first command makes `usb0` a plain DHCP client and pins its MACs. The
   second records those MACs and sets up the router: USB-Ethernet drivers,
   `usb0` in the LAN bridge, a static lease, and the WireGuard port forward.

5. **Move it.** Shut it down, then move the cable to the router's USB port:

   ```bash
   ssh -t -i ~/.ssh/bifrost_ed25519 <PI_USER>@10.12.194.1 sudo poweroff
   ```

6. **Everything else:**

   ```bash
   ./deploy.sh pi
   ```

   It updates the Pi, strips it down, and sets up DuckDNS, WireGuard and the
   firewall. When the firewall changes, it asks you to confirm a fresh SSH
   login within 2 minutes; without a "yes", the previous rules come back by
   themselves. It reboots at the end if needed.

7. **Add clients:**

   ```bash
   ./deploy.sh pi client add phone       # next free IP
   ./deploy.sh pi client add laptop 10.7.0.9
   ./deploy.sh pi client list
   ./deploy.sh pi client revoke phone
   ```

   `add` prints a QR code for the phone app. It also saves `~/wg-<name>.conf`
   on your PC, which contains the private key: import it, then delete it. On
   Fedora: `sudo nmcli connection import type wireguard file ~/wg-<name>.conf`.

**Coming from the old step-by-step guide?** Fill in the Pi part of
`bifrost.conf`, then run `./deploy.sh pi network`, `./deploy.sh pi-gateway` and
`./deploy.sh pi`. Existing keys, peers, pinned MACs and the DuckDNS token are
kept.

## What `setup.sh` does

| Step | |
|---|---|
| `network` | Keeps `rpi-usb-gadget`'s auto-switcher enabled: it's what brings `usb0` up at boot. On a router the switcher picks the "shared" profile, which as shipped would run an authoritative DHCP server on your LAN, so that profile becomes a plain DHCP client with IPv6 link-local. Also pins the `g_ether` MACs, which are otherwise random every boot. |
| `system` | Updates, with automatic security updates. Logs and swap in RAM only, and log2ram removed (Trixie has no rsyslog). Bluetooth, Wi-Fi, LED, display driver, audio and idle consoles off; GPU memory at its minimum. |
| `duckdns` | Updates `<subdomain>.duckdns.org` every 5 minutes, treating `KO` as a failure. |
| `wireguard` | Creates the server once. It never regenerates keys, so a re-run is a no-op. |
| `firewall` | nftables, generated from `bifrost.conf`. LAN to Pi, WireGuard in, and VPN to internet are allowed. VPN to the LAN only reaches the services in `VPN_LAN_ACCESS`. The Pi can never answer DHCP on the LAN. Rules for other services go in `/etc/nftables.d/*.nft`. |

Run one with `./deploy.sh pi <step>`.

## Re-running, reflashing, recovery

- **Re-run** step 6 any time, for example after editing `bifrost.conf`. Only what
  differs changes.
- **Reflashing the SD card:** `bifrost.conf` already holds the old `PI_MAC` and
  `HOST_MAC` (`deploy.sh pi-gateway` records them there). Step 4's `network`
  reuses them, so the router's lease still matches. You also need to re-add
  your WireGuard clients, since the server keys are new.
- **Locked out:** plug the Pi into your PC and run
  `ssh <PI_USER>@pi-zero-2w.local`. The firewall keeps IPv6 link-local SSH and
  mDNS open for exactly this.
- **The Pi boots but never brings its USB link up** (the router shows `usb0`
  as `down`): the `rpi-usb-gadget-ics` service is disabled. Put the SD card in
  a Linux PC and re-enable it on the card:

  ```bash
  root=$(findmnt -nro TARGET --source LABEL=rootfs | head -n1) && sudo ln -sfn /usr/lib/systemd/system/rpi-usb-gadget-ics.service "$root/etc/systemd/system/multi-user.target.wants/rpi-usb-gadget-ics.service" && sync
  ```

## Windows

`deploy.sh` runs in Git Bash. The exception is step 2, which needs Linux. By
hand: open the `bootfs` drive and open `user-data` in Notepad. If it has an
`rpi:` line, add `enable_usb_gadget: true` under it, indented like the lines
below it. Otherwise add these two lines at the end (spaces, not tabs):

```yaml
rpi:
  enable_usb_gadget: true
```
