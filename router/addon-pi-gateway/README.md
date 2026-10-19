# pi-gateway (addon)

The router side of the Pi WireGuard gateway (`../../pi/PI_ZERO_SETUP.md`). It
replaces the LuCI clicks the Pi guide used to need, so a router flash can no
longer silently break the VPN.

| What | Where on the router | Section |
|---|---|---|
| `kmod-usb-net-cdc-ether`, `kmod-usb-net-rndis` | packages | — |
| `usb0` as a LAN bridge port | `network` | br-lan device |
| Static lease: Pi MAC → `192.168.1.5` | `dhcp` | `pigw_<name>` |
| Port forward WAN `udp/51820` → Pi | `firewall` | `pigw_wireguard` |

It never touches what `../setup/` owns. Any other lease for the same MAC or IP,
or other forward of the same WAN port (such as the ones made by hand in LuCI),
is replaced, so there's exactly one of each.

## Install

```sh
cp router/addon-pi-gateway/pi-gateway.conf.example router/addon-pi-gateway/pi-gateway.conf
# fill in PI_MAC, then from the repo root:
scp -O -r router/addon-pi-gateway root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'sh /tmp/addon-pi-gateway/install.sh'
```

Re-run it after every router flash, or after editing `pi-gateway.conf`.

```sh
sh install.sh --check      # drivers, bridge, leases, forward, Pi ping, WAN not CGNAT
sh install.sh --uninstall  # remove leases, forward, bridge port (drivers stay)
```
