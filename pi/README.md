# Pi Zero 2 W — WireGuard gateway

A WireGuard endpoint that plugs into the main router's USB port and shows up
there as `usb0`, bridged into the LAN. No Wi-Fi, no extra cables, no power
supply. Everything on the Pi is done by `setup.sh`: `deploy.sh` copies it over
with the Pi's part of `bifrost.conf`, runs it, and deletes both. Every step is
safe to re-run.

## First time (about 20 minutes)

Before you start: the routers are set up (`./deploy.sh routers`), and part 6 of
`bifrost.conf` is filled in. That means `PI_USER` and `PI_PASSWORD` (the user
you'll create in step 1), your DuckDNS subdomain and token, and optionally
`VPN_LAN_ACCESS`.

1. **Flash the card** with Raspberry Pi Imager 2.x: *Raspberry Pi Zero 2 W* →
   *Raspberry Pi OS Lite (64-bit)* (Trixie). In Customisation, set the
   hostname, the user and password from `bifrost.conf`, and **enable SSH**.
   Leave Wi-Fi unconfigured.

2. **Turn on USB-Ethernet mode.** With the card still in the PC, and opened in
   your file manager so it's mounted:

   ```bash
   ./deploy.sh sdcard
   ```

   Without this, the Pi's USB port only takes power.

3. **Boot it on your PC.** Use a cable from the Pi's **USB** port (the inner
   one, not `PWR`) to the PC, and wait 2–3 minutes. Linux needs nothing;
   Windows needs the
   [Raspberry Pi RNDIS driver](https://github.com/raspberrypi/rpi-usb-gadget)
   once.

4. **Prepare it for the router, and the router for it:**

   ```bash
   ./deploy.sh pi --usb network
   ./deploy.sh pi-gateway --usb
   ```

   The first command makes the Pi a plain network client and pins its MACs.
   The second records those MACs in `bifrost.conf` and sets up the router:
   USB-Ethernet drivers, `usb0` in the LAN bridge, a static lease, and the
   WireGuard port forward.

5. **Move it to the router:**

   ```bash
   ./deploy.sh pi --usb poweroff
   ```

   Wait a few seconds, then move the cable from the PC to the router's USB
   port.

6. **Set up everything else:**

   ```bash
   ./deploy.sh pi
   ```

   It updates the Pi, strips it down, and sets up DuckDNS, WireGuard and the
   firewall. When the firewall rules change, it asks you to open a second
   terminal, check that `ssh <PI_USER>@<PI_IP>` still logs in, and type `yes`.
   Without a "yes" within 2 minutes, the previous rules come back by
   themselves. It reboots at the end if needed.

7. **Add your devices:**

   ```bash
   ./deploy.sh pi client add phone            # gets the next free IP
   ./deploy.sh pi client add laptop 10.7.0.9  # or a chosen one
   ./deploy.sh pi client list
   ./deploy.sh pi client revoke phone
   ```

   `add` prints a QR code for the WireGuard phone app. It also saves
   `~/wg-<name>.conf` on the PC, for computers:
   `sudo nmcli connection import type wireguard file ~/wg-<name>.conf` on
   Fedora, or "Import tunnel(s) from file" in the WireGuard app. That file
   contains the device's private key, so delete it after importing.

## Later

- **After editing `bifrost.conf`,** for example `VPN_LAN_ACCESS`, run
  `./deploy.sh pi` again. Only what differs changes.
- **After a router flash,** nothing to do here; `./deploy.sh routers` restores
  the router side.
- **Reflashing the SD card:** do steps 1–6 again. `bifrost.conf` already holds
  the old MACs, so the router's lease still matches. Re-add your devices
  (step 7), since the server keys are new.

## What `setup.sh` does

| Step | |
|---|---|
| `network` | Pins the USB MACs (random on every boot otherwise). Makes `usb0` a DHCP client with IPv6 link-local. Keeps `rpi-usb-gadget`'s auto-switcher **enabled**, since it's what brings `usb0` up at boot. It picks the "shared" profile, which as shipped would be a DHCP server on your LAN, so that profile is turned into a client. |
| `system` | Updates, with automatic security updates from then on. Logs and swap in RAM only, so the SD card barely gets written. Bluetooth, Wi-Fi, LED, display driver, audio and idle consoles off; GPU memory at its minimum. |
| `duckdns` | Updates `<subdomain>.duckdns.org` every 5 minutes. |
| `wireguard` | Creates the server the first time. It never touches existing keys or peers. |
| `firewall` | Allowed: LAN to Pi, WireGuard in, VPN to internet, and VPN to the services in `VPN_LAN_ACCESS`; nothing else on the LAN. The Pi can never act as a DHCP server. Rules for other services on the Pi go in `/etc/nftables.d/*.nft`. |

`./deploy.sh pi` runs them all; `./deploy.sh pi <step>` runs one.

## Troubleshooting

- **Locked out over the network:** plug the Pi into your PC and
  `ssh <PI_USER>@pi-zero-2w.local`. The firewall keeps that path open on
  purpose.
- **The Pi boots but its USB link never comes up** (the router shows `usb0`
  as `down`, with the Pi's LED off you can't tell otherwise): the
  `rpi-usb-gadget-ics` service got disabled. Put the SD card in a Linux PC,
  open it in the file manager, and re-enable it on the card:

  ```bash
  root=$(findmnt -nro TARGET --source LABEL=rootfs | head -n1) && sudo ln -sfn /usr/lib/systemd/system/rpi-usb-gadget-ics.service "$root/etc/systemd/system/multi-user.target.wants/rpi-usb-gadget-ics.service" && sync
  ```

## Windows

`deploy.sh` runs in Git Bash, except step 2, which needs Linux. To do step 2
by hand, open the card's `bootfs` drive and open `user-data` in Notepad:
- If it has an `rpi:` line, add `enable_usb_gadget: true` under it, indented
  like the lines below it.
- Otherwise, add these two lines at the end, with spaces, not tabs:

```yaml
rpi:
  enable_usb_gadget: true
```
