# wifi-watch (addon)

Telegram home/away notifier for a home network: `ax6000-main` plus two
`ax4200` dumb APs bridged onto the same LAN.

**This is an addon.** It never touches wireless, network, dhcp or firewall
config. `../setup/` owns those, and nothing here duplicates or contradicts
them. The only change it makes to a dumb AP is appending one public key to
`/etc/dropbear/authorized_keys` so it can be asked which stations are
associated.

| File | Installed to | What it is |
|---|---|---|
| `wifi-watch.conf` | `/etc/wifi-watch.conf` | **All settings**: bot token, chat, people, APs, tuning. Git-ignored; create it from `wifi-watch.conf.example` |
| `install.sh` | (run from the copy) | Installer / uninstaller / health check |
| `wifi-watch.sh` | `/usr/bin/` | The notifier daemon |
| `wifi-where.sh` | `/usr/bin/` | Read-only diagnostic |
| `wifi-watch-lib.sh` | `/usr/lib/wifi-watch/lib.sh` | Shared config loading, SSH plumbing, queries |
| `wifi-watch.init` | `/etc/init.d/wifi-watch` | procd service wrapper |

## Detection model

A person is present if **either** signal says so, so a false "left" requires
both to fail in the same instant.

| | Source | Why it holds up |
|---|---|---|
| **1. Association** | `hostapd` via ubus — locally on the main router, over SSH on `.2`/`.3` | Authoritative. The AP knows a phone is there whether or not it answers packets. Immune to power-save. |
| **2. ARP reachability** | broadcast `arping` to each leased IP | ARP requests are *broadcast*, so they flood every bridge port and find a phone that just roamed. Wi-Fi chipsets answer ARP in firmware (ARP offload), so this survives doze. |

The main router reads its own radios locally over ubus — no SSH, no key, no
failure mode. Only the dumb APs need the key.

Three guarantees on top:

- **Person-keyed state, not MAC-keyed.** Modern phones use randomized MACs
  that can rotate. A MAC-keyed machine reads a rotation as "arrived" +
  "left". hostapd's MAC-only
  view is translated through a persistent MAC→person map learned from the DHCP
  leases, so a rotation is absorbed.
- **An unreachable AP holds departures.** One signal down means degraded data,
  so state is held and logged rather than announced. Bounded by
  `AP_FAIL_GRACE` polls so an AP that is genuinely unplugged can't wedge the
  notifier forever.
- **Silent seeding on cold start,** so a reboot or procd respawn doesn't
  announce the whole household.

A departure needs 4 consecutive misses (~2 min) **and** 3 further confirmation
rounds that re-query the APs. A roam is seconds wide.

## Install

From the repo root, with the router reachable:

```sh
scp -O -r router/addon-wifi-watch root@192.168.1.1:/tmp/
ssh -t root@192.168.1.1 'sh /tmp/addon-wifi-watch/install.sh'
```

The installer is idempotent, so re-run it after every flash or after editing
anything here, `wifi-watch.conf` included. Each run:

- installs `curl`, `arping`, `timeout` and an SSH client if missing (a flash
  removes them)
- reuses or creates `/root/.ssh/wifi-watch` and authorizes it on each AP that
  doesn't already accept it
- copies the files, overwriting `/etc/wifi-watch.conf` with this directory's
  copy (the copy here is the source of truth)
- lists the config and key in `/etc/sysupgrade.conf`, so a flash with "keep
  settings" doesn't force re-authorizing the APs
- restarts the service and runs a self-test

AP authorization uses the key if it already works. If not, it falls back to
`AP_PASSWORD="<root pw>"` from the environment, if set, or else an interactive
password prompt (hence `ssh -t`). The password is never written to disk.

```sh
sh install.sh --check      # diagnose an existing install
sh install.sh --uninstall  # remove (leaves the SSH key and authorized_keys line)
```

## Operating

```sh
logread -e wifi-watch   # what the notifier decided and why
wifi-where.sh           # which AP each device is on, plus notifier state
wifi-where.sh -a        # include devices with no DHCP hostname
```

Log lines worth knowing:

| Line | Meaning |
|---|---|
| `starting: association via local ubus + SSH to [...]` | Both signals up. If it says *"local ubus only"*, the key handoff failed and the dumb APs are ARP-only. |
| `MISS: <person> (n/4)` | One probe round found nothing. Normal in ones; a roam should not reach 4. |
| `RECOVERED: <person> answered during confirmation` | A departure was about to fire and the confirmation caught it. Margins are working but tighter than ideal. |
| `HOLD: ... an AP is unreachable` | Departure suppressed on degraded data. |
| `WARN: AP <ip> unreachable (n/10)` | That AP is not answering SSH. |

## Configuration

Everything is in `wifi-watch.conf`. Re-run `install.sh` to apply.

People are `hostname-substring=name` pairs:

```sh
PEOPLE="Pixel-8=Alice iPhone-Bob=Bob"
PEOPLE_MAC="aa:bb:cc:dd:ee:ff=Alice"   # fallback for a device with no DHCP hostname
```

| Setting | Default | Raise it if |
|---|---|---|
| `MISSES_TO_LEAVE` | 4 | You see `RECOVERED` lines regularly |
| `CONFIRM_ROUNDS` / `CONFIRM_GAP` | 3 / 5 s | Departures still slip through |
| `AP_FAIL_GRACE` | 10 | An AP reboots often and you want longer suppression |
| `POLL_INTERVAL` | 30 s | — |

If Telegram is unreachable (WAN down, PPPoE reconnecting), messages go to a
queue (`/tmp/wifi-watch/.outbox`) and are sent, in order and with the original
time attached, as soon as it comes back.

## Known environment quirks

- **No `sftp-server`** on OpenWrt — use `scp -O`.
- **No `timeout` applet** in this busybox build. The installer adds
  `coreutils-timeout`; `wifi-watch.sh` also ping-gates each AP before spending
  an SSH handshake, so a powered-off AP fails in 2 s instead of stalling the
  poll loop on TCP connect.
- **`arping` is not in busybox here** — the installer adds `iputils-arping`.
  Without it the ARP signal degrades to ICMP and roam false-positives return.
