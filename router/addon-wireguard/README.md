# wireguard (addon)

A WireGuard VPN server on the main router: VPN clients reach the internet and
the services in `VPN_LAN_ACCESS`, and nothing else on the LAN. Everything shows
up in LuCI, where you can change it whenever you like.

**`bifrost.conf` seeds it, LuCI owns it.** The first deploy creates each piece
below from part 6 of `bifrost.conf`. From then on, a piece that exists is never
touched again, so what you change in LuCI stays, and "Keep settings" carries it
across flashes. Re-runs only reinstall the packages (a flash drops them) and
bring `wg0` back up.

| What | Where in LuCI | Section |
|---|---|---|
| Interface `wg0`, its key, listen port, peers | Network → Interfaces → wg0 | `network.wg0` |
| Zone `vpn`: VPN → internet, nothing else | Network → Firewall → Zones | `firewall.wgvpn`, `wgvpn_wan` |
| One rule per `VPN_LAN_ACCESS` entry | Network → Firewall → Traffic Rules | `firewall.wgvpn_lan<N>` |
| Ping the router from the VPN | Network → Firewall → Traffic Rules | `firewall.wgvpn_ping` |
| WAN `udp/WG_PORT` open | Network → Firewall → Traffic Rules | `firewall.wgvpn_in` |
| DuckDNS | Services → Dynamic DNS | `ddns.duckdns` |

The router itself is closed to VPN clients (zone input `REJECT`), except for
ping. To manage it over the VPN, add a rule in LuCI.

## Install

```bash
./deploy.sh wireguard
```

`./deploy.sh routers` runs it too, while `WG_PORT` is set.

VPN traffic to the LAN isn't NAT'd, so LAN hosts see the client's `10.7.0.x`
address. A host firewall that only allows its "local subnet" (Windows Remote
Desktop, for example) needs `10.7.0.0/24` allowed too.

## Clients

Either in LuCI (Network → Interfaces → wg0 → Edit → Peers → Add peer:
generate a key pair and a preshared key, set Allowed IPs to a free
`10.7.0.x/32`, save, then *Generate configuration…* for the QR code), or from
the PC:

```bash
./deploy.sh wireguard client add phone            # next free IP, QR in the terminal
./deploy.sh wireguard client add laptop 10.7.0.9  # or a chosen one
./deploy.sh wireguard client list
./deploy.sh wireguard client revoke phone
```

Both kinds show up in LuCI and in `client list`. A client added from the PC
leaves only its public key on the router, and its private key only in
`~/wg-<name>.conf` (delete it once imported). So LuCI can't show a QR code for
it later. A peer added in LuCI keeps its private key on the router.

## Check, start over

```bash
ssh -i ~/.ssh/bifrost_ed25519 root@192.168.1.1 sh /tmp/addon-wireguard/install.sh --check      # wg0, peers, zone, WAN not CGNAT, DuckDNS
ssh -i ~/.ssh/bifrost_ed25519 root@192.168.1.1 sh /tmp/addon-wireguard/install.sh --uninstall  # removes it all, keys and peers included
```

The installer stays in `/tmp` until the router reboots; otherwise run
`./deploy.sh wireguard` first. To re-seed from `bifrost.conf`, uninstall and
deploy again. Every client then needs a new config, since the server key is new.

## Speed

VPN traffic can't use the hardware NAT offload, so the CPU encrypts it. A
Filogic 830 router (4× Cortex-A53 at 2 GHz, as in most AX6000s) handles
several hundred Mbps. Usually your
home upload speed is the real limit, since it's the remote client's download
speed. Other traffic stays offloaded.
