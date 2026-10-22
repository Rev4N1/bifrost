# pi-gateway (addon)

The router side of the Pi Tailscale stick ([pi/README.md](../../pi/README.md)),
so a router flash can never silently take the Pi offline.

| What | Where on the router | Section |
|---|---|---|
| `kmod-usb-net-cdc-ether`, `kmod-usb-net-rndis` | packages | — |
| `usb0` as a LAN bridge port | `network` | br-lan device |
| Static lease: Pi MAC → `192.168.1.5` | `dhcp` | `pigw_<name>` |

Tailscale needs no port forward; the WireGuard one older versions made
(`pigw_wireguard`) is removed. It never touches what `../setup/` owns. Any
other lease for the same MAC or IP is replaced, so there's exactly one.

## Install

```bash
./deploy.sh pi-gateway --usb    # first time, Pi still on the PC: records its MAC in bifrost.conf
./deploy.sh pi-gateway          # after that, e.g. after every router flash
```

`./deploy.sh routers` runs it too, once `PI_MAC` is set (part 8 of `bifrost.conf`). After a
deploy, the installer stays in `/tmp` on the router until its next reboot:

```bash
ssh -i ~/.ssh/bifrost_ed25519 root@192.168.1.1 sh /tmp/addon-pi-gateway/install.sh --check      # drivers, bridge, lease, Pi ping
ssh -i ~/.ssh/bifrost_ed25519 root@192.168.1.1 sh /tmp/addon-pi-gateway/install.sh --uninstall  # remove lease, bridge port (drivers stay)
```
