# Bifrost

The bridge to and across your home network, as code. OpenWrt 25.12 on one
main router plus two dumb APs, a Raspberry Pi Zero 2 W as WireGuard gateway,
and optional addons on top. Every script is safe to re-run after a flash.

| Device | IP | Role | 2.4 GHz | 5 GHz |
|---|---|---|---|---|
| `ax6000-main` | 192.168.1.1 | PPPoE gateway, DHCP, DNS, Wi-Fi | ch 1 / 20 | ch 36 / 80 |
| `ax4200-ap1` | 192.168.1.2 | dumb AP (bridge only) | ch 6 / 20 | ch 100 / 80 (DFS) |
| `ax4200-ap2` | 192.168.1.3 | dumb AP (bridge only) | ch 11 / 20 | ch 52 / 80 (DFS) |
| `pi-zero-2w` | 192.168.1.5 | WireGuard gateway, on the main router's USB port (`usb0`) | — | — |

The three routers share one SSID over a wired backhaul: 802.11r fast roaming,
802.11k/v plus `usteer` steering clients to the best AP, and 802.11w (optional
PMF). The main router has hardware NAT offload, and every router has packet
steering on.

```
router/
  setup/                  provisioning: owns network, wireless, dhcp, firewall basics
    network.conf.example    shared values + all setup secrets (copy to network.conf)
    common.sh               shared steps (system, wpad, wireless, bridge)
    main-ap_ax6000.sh       main router
    dumb-ap_ax4200.sh       dumb APs:  sh dumb-ap_ax4200.sh ap1|ap2
  addon-wifi-watch/       Telegram home/away notifier (optional, own README)
  addon-pi-gateway/       router side of the Pi: usb0 bridge port + drivers,
                          static lease, WireGuard port forward (optional)
pi/
  PI_ZERO_SETUP.md        the Pi itself: gadget networking, WireGuard, nftables
```

`setup/` never references an addon, and the addons never touch what `setup/`
owns. Each piece can be re-run on its own.

## The PC side

Every command meant for your computer is written for **Linux (bash; Fedora is
what it's used on)** and runs from the repo root. They only need `ssh`, `scp`,
`sed` and `awk`, which every distro ships.

**On Windows** the `ssh`/`scp` lines work unchanged in PowerShell (OpenSSH is
built in). For the few blocks that use other Linux tools, the Pi guide
explains what each one does, so you can do the same by hand.

## Before the first run

The real config files hold secrets and are git-ignored. Create the router
configs from their templates, then fill in every `CHANGE_ME` (the scripts refuse
to run while one is left):

```bash
cp -n router/setup/network.conf.example router/setup/network.conf
cp -n router/addon-wifi-watch/wifi-watch.conf.example router/addon-wifi-watch/wifi-watch.conf
```

That copies each `*.example` template to its real name. `-n` never overwrites a
config you've already filled in. On Windows, copy the two files in Explorer.

`pi-gateway.conf` fills itself: Part 3 of the Pi guide reads the Pi's MACs and
writes it.

## Setting up from scratch

1. **Routers**: run the "After every router flash" steps below.
2. **Pi**: follow [`pi/PI_ZERO_SETUP.md`](pi/PI_ZERO_SETUP.md) from Part 0. Its
   Part 3 runs `addon-pi-gateway` on the router for you.

## After every router flash

Everything is idempotent: re-run it all from the repo root, in this order. Each
setup script reboots its router at the end. Wait until the router answers
again (about 2 minutes) before the next step.

```bash
# 1. main router
scp -O -r router/setup root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'sh /tmp/setup/main-ap_ax6000.sh'

# 2. each dumb AP (use 192.168.1.1 instead if it's factory-fresh: see below)
scp -O -r router/setup root@192.168.1.2:/tmp/
ssh root@192.168.1.2 'sh /tmp/setup/dumb-ap_ax4200.sh ap1'
scp -O -r router/setup root@192.168.1.3:/tmp/
ssh root@192.168.1.3 'sh /tmp/setup/dumb-ap_ax4200.sh ap2'

# 3. addons, on the main router, once the APs are back up
scp -O -r router/addon-wifi-watch root@192.168.1.1:/tmp/
ssh -t root@192.168.1.1 'sh /tmp/addon-wifi-watch/install.sh'
scp -O -r router/addon-pi-gateway root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'sh /tmp/addon-pi-gateway/install.sh'
```

`scp -O` is required: OpenSSH 9+ defaults to SFTP and OpenWrt has no
`sftp-server`.

A **factory-fresh dumb AP** boots at 192.168.1.1, the same IP as the main
router. Provision it with only your PC plugged in. It moves to .2/.3 mid-run, so
your SSH session freezes. That's expected: the script keeps going. While it
waits up to 120 s for internet (to install full `wpad`), plug the AP into the
main LAN. If it gets no internet, it skips that step and keeps `wpad-basic`
(802.11r still works, 802.11k/v doesn't). Re-run it later to fix that.

The Pi itself survives router flashes untouched: step 3's `addon-pi-gateway`
restores everything the router owes it.
