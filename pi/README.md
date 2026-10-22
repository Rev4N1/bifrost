# Pi Zero 2 W — Tailscale stick

A Tailscale exit node and subnet router you can take anywhere. At home it plugs
into the main router's USB port and shows up there as `usb0`, bridged into the
LAN: no Wi-Fi needed, no extra cables, no power supply. Anywhere else, give it
USB power and it joins a Wi-Fi you saved. Wherever it is, your Tailscale devices
can:

- use it as an **exit node**, so all their traffic (`0.0.0.0/0`) leaves from
  where the Pi is,
- reach the **whole LAN** it's on. It advertises the networks it's connected
  to (the home LAN through `usb0`, a hotel's through Wi-Fi) as subnet routes,
  and updates them whenever it moves.

There's no firewall on the Pi: Tailscale's access controls (in the admin
console) decide who reaches what. Tailscale needs no port forward and works
behind any NAT, CGNAT included. For a plain WireGuard server on the router, see
[router/addon-wireguard](../router/addon-wireguard/README.md); the two work
side by side.

Everything on the Pi is done by `setup.sh`: `deploy.sh` copies it over with the
Pi's part of `bifrost.conf`, runs it, and deletes both. Every step is safe to
re-run.

## First time (about 20 minutes)

Before you start: the routers are set up (`./deploy.sh routers`), and part 7 of
`bifrost.conf` is filled in. That means `PI_USER` and `PI_PASSWORD` (the user
you'll create in step 1), and optionally `TS_AUTHKEY` (from the Tailscale admin
console, Settings → Keys). Pick a strong `PI_PASSWORD`: SSH listens on every
network the Pi joins.

1. **Flash the card** with Raspberry Pi Imager 2.x: *Raspberry Pi Zero 2 W* →
   *Raspberry Pi OS Lite (64-bit)* (Trixie). In Customisation, set the
   hostname, the user and password from `bifrost.conf`, and **enable SSH**.
   Leave Wi-Fi unconfigured; you add networks later (see
   [Taking it somewhere](#taking-it-somewhere)).

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

   It updates the Pi, strips it down, sets up Wi-Fi and installs Tailscale.
   Without `TS_AUTHKEY`, it prints a login link: open it and approve the Pi.
   It reboots at the end if needed.

7. **Approve it in the [admin console](https://login.tailscale.com/admin/machines):**
   on the Pi's row, *Edit route settings…* → tick **Use as exit node** and the
   home LAN route. Then *Disable key expiry*, so it never needs a new login.

8. **Use it:** in the Tailscale app on any device, pick the Pi as exit node.
   The LAN behind it works with or without that.

**Every new network is a new route to approve.** To skip that, let your
tailnet approve them by itself: in the admin console, *Access controls*, add
this to the policy file, with your Tailscale login:

```json
"autoApprovers": {
  "routes": {
    "10.0.0.0/8":     ["you@example.com"],
    "172.16.0.0/12":  ["you@example.com"],
    "192.168.0.0/16": ["you@example.com"]
  },
  "exitNode": ["you@example.com"]
}
```

## Taking it somewhere

Away from home, plug the Pi into anything that gives USB power. It joins the
first saved Wi-Fi in range, and Tailscale finds it there.

To save a Wi-Fi, connect your laptop to the Pi's **USB** port (the inner one,
which powers it too) and wait 2 minutes. Then:

```bash
ssh <PI_USER>@pi-zero-2w.local
```

On the Pi, with the network in range:

```bash
sudo nmcli device wifi connect "Hotel Wifi" password 'its password'
```

Or saved ahead of time, out of range:

```bash
sudo nmcli connection add type wifi ifname wlan0 con-name "Hotel Wifi" ssid "Hotel Wifi" wifi-sec.key-mgmt wpa-psk wifi-sec.psk 'its password'
```

To see what's saved and connected, and to forget one:

```bash
nmcli connection show
```

```bash
sudo nmcli connection delete "Hotel Wifi"
```

**If `pi-zero-2w.local` doesn't resolve,** your laptop is only looking it up
over IPv4 (Fedora's default). On a Linux laptop, share its connection on that
cable once: the Pi then gets an IPv4 address from the laptop, and internet
through it too. `HOST_MAC` is in `bifrost.conf`:

```bash
nmcli connection add type ethernet con-name pi-usb ethernet.mac-address <HOST_MAC> ipv4.method shared ipv6.method link-local
```

A Wi-Fi with a captive portal (a sign-in page) won't work: the Pi has no
browser.

## Later

- **After editing `bifrost.conf`,** run `./deploy.sh pi` again. Only what
  differs changes.
- **After a router flash,** nothing to do here; `./deploy.sh routers` restores
  the router side.
- **Reflashing the SD card:** remove the old Pi in the admin console, then do
  steps 1–7 again. `bifrost.conf` already holds its MACs, so the router's
  lease still matches.

## What `setup.sh` does

| Step | |
|---|---|
| `network` | Pins the USB MACs (random on every boot otherwise). Makes `usb0` a DHCP client with IPv6 link-local. Keeps `rpi-usb-gadget`'s auto-switcher **enabled**, since it's what brings `usb0` up at boot. It picks the "shared" profile, which as shipped would be a DHCP server on your LAN, so that profile is turned into a client. |
| `system` | Updates, with automatic security updates from then on. Logs and swap in RAM only, so the SD card barely gets written. Bluetooth, LED, display driver, audio and idle consoles off; GPU memory at its minimum. |
| `wifi` | Wi-Fi on, with the country from `COUNTRY` and power saving off. When `usb0` is connected, NetworkManager prefers it. |
| `tailscale` | Installs Tailscale with auto-updates and logs in as `PI_NAME`, as an exit node. A NetworkManager hook (`/etc/NetworkManager/dispatcher.d/90-tailscale-routes`) advertises the networks on `usb0` and `wlan0` as routes, whenever they change. |

`./deploy.sh pi` runs them all; `./deploy.sh pi <step>` runs one.

**Speed:** Tailscale encrypts in userspace on a 1 GHz core, so expect tens of
Mbps through the Pi, less over Wi-Fi. That's plenty for a phone or for reaching
a LAN. For full speed at home, use the router's WireGuard.

## Troubleshooting

- **Can't reach it over the network:** plug it into your laptop and
  `ssh <PI_USER>@pi-zero-2w.local` (see above). Over Tailscale,
  `ssh <PI_USER>@pi-zero-2w` works from anywhere.
- **The Pi boots but its USB link never comes up** (the router shows `usb0`
  as `down`, with the Pi's LED off you can't tell otherwise): the
  `rpi-usb-gadget-ics` service got disabled. Put the SD card in a Linux PC,
  open it in the file manager, and re-enable it on the card:

  ```bash
  root=$(findmnt -nro TARGET --source LABEL=rootfs | head -n1) && sudo ln -sfn /usr/lib/systemd/system/rpi-usb-gadget-ics.service "$root/etc/systemd/system/multi-user.target.wants/rpi-usb-gadget-ics.service" && sync
  ```

- **Tailscale works, but nothing passes through the Pi:** the exit node or the
  route isn't approved yet (step 7). On the Pi, `tailscale status` and
  `tailscale debug prefs` show what it advertises.

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
