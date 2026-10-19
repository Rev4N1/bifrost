# pi-gateway (addon)

The router side of the Pi WireGuard gateway ([pi/README.md](../../pi/README.md)),
so a router flash can never silently break the VPN.

| What | Where on the router | Section |
|---|---|---|
| `kmod-usb-net-cdc-ether`, `kmod-usb-net-rndis` | packages | — |
| `usb0` as a LAN bridge port | `network` | br-lan device |
| Static lease: Pi MAC → `192.168.1.5` | `dhcp` | `pigw_<name>` |
| Port forward WAN `udp/51820` → Pi | `firewall` | `pigw_wireguard` |

It never touches what `../setup/` owns. Any other lease for the same MAC or IP,
or other forward of the same WAN port (such as one made by hand in LuCI), is
replaced, so there's exactly one of each.

## Install

```bash
./deploy.sh pi-gateway <user>@<pi address>   # first time: reads the Pi's MAC into pi-gateway.conf
./deploy.sh pi-gateway                       # after that, e.g. after every router flash
```

`./deploy.sh routers` runs it too, once `pi-gateway.conf` exists. After a
deploy, the installer stays in `/tmp` on the router until its next reboot:

```bash
ssh root@192.168.1.1 sh /tmp/addon-pi-gateway/install.sh --check      # drivers, bridge, lease, forward, Pi ping, WAN not CGNAT
ssh root@192.168.1.1 sh /tmp/addon-pi-gateway/install.sh --uninstall  # remove lease, forward, bridge port (drivers stay)
```
