# Pi Zero 2 W — Tailscale stick

A Tailscale exit node and subnet router you can take anywhere. At home it plugs
into the main router's USB port and shows up there as `usb0`, bridged into the
LAN: no Wi-Fi needed, no extra cables, no power supply. Anywhere else, give it
USB power and it joins a Wi-Fi you saved. Either way, your Tailscale devices
can:

- use it as an **exit node**, so all their traffic (`0.0.0.0/0`) leaves from
  where the Pi is,
- reach the home services in `VPN_LAN_ACCESS`, advertised as `/32` routes.
  Its firewall blocks everything else on the LAN, and every other network the
  Pi sits on.

Tailscale needs no port forward and works behind any NAT, CGNAT included. For a
plain WireGuard server on the router, see
[router/addon-wireguard](../router/addon-wireguard/README.md); the two work
side by side.

Everything on the Pi is done by `setup.sh`: `deploy.sh` copies it over with the
Pi's part of `bifrost.conf`, runs it, and deletes both. Every step is safe to
re-run.

## First time (about 20 minutes)

Before you start: the routers are set up (`./deploy.sh routers`), and part 8 of
`bifrost.conf` is filled in. That means `PI_USER` and `PI_PASSWORD` (the user
you'll create in step 1), and optionally `TS_AUTHKEY` (from the Tailscale admin
console, Settings → Keys) and `VPN_LAN_ACCESS` (part 6).

1. **Flash the card** with Raspberry Pi Imager 2.x: *Raspberry Pi Zero 2 W* →
   *Raspberry Pi OS Lite (64-bit)* (Trixie). In Customisation, set the
   hostname, the user and password from `bifrost.conf`, and **enable SSH**.
   Leave Wi-Fi unconfigured; you add networks later with `wifi add`.

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
   USB-Ethernet drivers, `usb0` in the LAN bridge, and a static lease.

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

   It updates the Pi, strips it down, turns on Wi-Fi, installs Tailscale and
   sets up the firewall. Without `TS_AUTHKEY`, it prints a login link: open it
   and approve the Pi. When the firewall rules change, it asks you to open a
   second terminal, check that `ssh <PI_USER>@<PI_IP>` still logs in, and type
   `yes`. Without a "yes" within 2 minutes, the previous rules come back by
   themselves. It reboots at the end if needed.

7. **Approve it in the [admin console](https://login.tailscale.com/admin/machines):**
   on the Pi's row, *Edit route settings…* → tick **Use as exit node** and its
   subnet routes. Then *Disable key expiry*, so it never needs a new login.

8. **Use it:** in the Tailscale app on any device, pick the Pi as exit node.
   The home services work with or without that.

## Taking it somewhere

Save the Wi-Fi first, from anywhere: at home, over Tailscale, or from a laptop
on the Pi's USB port. Saving works even when the network isn't in range:

```bash
./deploy.sh pi wifi add "Hotel Wifi" 'its password'
./deploy.sh pi wifi list
./deploy.sh pi wifi forget "Hotel Wifi"
```

Away from home, plug the Pi into anything that gives USB power. It joins the
first saved Wi-Fi in range, and Tailscale finds it there.

**From a laptop, no Wi-Fi known yet:** plug the laptop into the Pi's **USB**
port and wait 2 minutes. The laptop finds the Pi by name over the cable
(IPv6 link-local and mDNS):

```bash
./deploy.sh pi --usb wifi add "Hotel Wifi" 'its password'
```

Without the repo on that laptop, SSH in by hand:

```bash
ssh <PI_USER>@pi-zero-2w.local
```

```bash
sudo nmcli device wifi connect "Hotel Wifi" password 'its password'
```

A Wi-Fi with a captive portal (a sign-in page) won't work: the Pi has no
browser.

## Later

- **After editing `bifrost.conf`,** for example `VPN_LAN_ACCESS`, run
  `./deploy.sh pi` again. Only what differs changes. A new route needs
  approving in the admin console.
- **After a router flash,** nothing to do here; `./deploy.sh routers` restores
  the router side.
- **Reflashing the SD card:** do steps 1–7 again. `bifrost.conf` already holds
  the old MACs, so the router's lease still matches. Remove the old Pi in the
  admin console first.

## What `setup.sh` does

| Step | |
|---|---|
| `network` | Pins the USB MACs (random on every boot otherwise). Makes `usb0` a DHCP client with IPv6 link-local. Keeps `rpi-usb-gadget`'s auto-switcher **enabled**, since it's what brings `usb0` up at boot. It picks the "shared" profile, which as shipped would be a DHCP server on your LAN, so that profile is turned into a client. |
| `system` | Updates, with automatic security updates from then on. Logs and swap in RAM only, so the SD card barely gets written. Bluetooth, LED, display driver, audio and idle consoles off; GPU memory at its minimum. |
| `wifi` | Wi-Fi on, with the country from `COUNTRY` and power saving off. When `usb0` is connected, NetworkManager prefers it. |
| `tailscale` | Removes the old DuckDNS + WireGuard server if it's there. Installs Tailscale with auto-updates, and logs in as `PI_NAME`: exit node, plus the `VPN_LAN_ACCESS` hosts as routes. |
| `firewall` | Allowed: anything over the USB cable, Tailscale peers to the Pi, VPN to internet, and VPN to the services in `VPN_LAN_ACCESS` (home LAN only). Nothing else on the LAN, nothing into whatever network the Pi is on, and Wi-Fi gets nothing inbound but Tailscale. The Pi can never act as a DHCP server. It uses its own nftables tables, next to Tailscale's. Rules for other services on the Pi go in `/etc/nftables.d/*.nft`. |

`./deploy.sh pi` runs them all; `./deploy.sh pi <step>` runs one.

**Speed:** Tailscale encrypts in userspace on a 1 GHz core, so expect tens of
Mbps through the Pi, less over Wi-Fi. That's plenty for a phone or for reaching
home services. For full speed at home, use the router's WireGuard.

## Troubleshooting

- **Locked out over the network:** plug the Pi into your PC and
  `ssh <PI_USER>@pi-zero-2w.local`. The firewall keeps the USB cable open on
  purpose. Over Tailscale, `ssh <PI_USER>@pi-zero-2w` works from anywhere.
- **The Pi boots but its USB link never comes up** (the router shows `usb0`
  as `down`, with the Pi's LED off you can't tell otherwise): the
  `rpi-usb-gadget-ics` service got disabled. Put the SD card in a Linux PC,
  open it in the file manager, and re-enable it on the card:

  ```bash
  root=$(findmnt -nro TARGET --source LABEL=rootfs | head -n1) && sudo ln -sfn /usr/lib/systemd/system/rpi-usb-gadget-ics.service "$root/etc/systemd/system/multi-user.target.wants/rpi-usb-gadget-ics.service" && sync
  ```

- **Tailscale works, but nothing passes through the Pi:** the routes or the
  exit node aren't approved yet (step 7).

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
