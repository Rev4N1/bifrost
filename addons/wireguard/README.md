# wireguard (addon)

A WireGuard VPN server on the main router: VPN clients reach the services in
`VPN_LAN_ACCESS`, and nothing else on the LAN. New clients are split-tunnel:
only those hosts go through the VPN, and each client keeps its own internet
and DNS. Everything shows
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

`client.sh` in this folder is the PC-side peer tool; it never runs on the
router.

## Install

```bash
./deploy.sh
```

That is the whole deploy, and it applies the addon whenever `WG_PORT` is set.
There is no separate WireGuard command.

VPN traffic to the LAN isn't NAT'd, so LAN hosts see the client's `10.7.0.x`
address. A host firewall that only allows its "local subnet" (Windows Remote
Desktop, for example) needs `10.7.0.0/24` allowed too.

## Clients

From the PC, or in LuCI (Network → Interfaces → wg0 → Edit → Peers → Add
peer: generate a key pair and a preshared key, set Allowed IPs to a free
`10.7.0.x/32`, save, then *Generate configuration…* for the QR code). From the
PC:

```bash
./addons/wireguard/client.sh add phone            # next free IP, QR in the terminal
./addons/wireguard/client.sh add laptop 10.7.0.9  # or a chosen one
./addons/wireguard/client.sh list
./addons/wireguard/client.sh revoke phone
```

Adding a peer changes one router setting, so it is not part of `deploy.sh`.
Run `./deploy.sh` first (or at least once), so the addon is installed.
`VPN_SUBNET` must stay a `/24` that does not overlap the LAN (the router is `.1`, clients get `.2`-`.254`);
a client IP outside it is refused, because the router would have no route back
through the tunnel.

Both kinds show up in LuCI and in `client list`, and both keep their private
key on the router, so LuCI can show any client's config and QR code later.
`add` also saves `~/wg-<name>.conf` on the PC; delete it once imported.

**What a client from `client.sh` routes:** only the router's VPN address
(`10.7.0.1`, to ping it) and the LAN hosts the `vpn` zone may reach (the
`dest_ip` of its ACCEPT rules to `lan`, as they are on the router now). There
is no `DNS =` line, so the client keeps its own DNS. For a full tunnel, set
`AllowedIPs = 0.0.0.0/0` in that client: the router lets VPN traffic out to
the internet. LuCI's *Generate configuration…* dialog has its own Allowed IPs
field; set it the same way there.

## Check, start over

```bash
ssh root@192.168.1.1 sh /tmp/bifrost-wireguard/install.sh --check      # wg0, peers, zone, WAN not CGNAT, DuckDNS
ssh root@192.168.1.1 sh /tmp/bifrost-wireguard/install.sh --uninstall  # removes it all, keys and peers included
```

The installer stays in `/tmp` until the router reboots; otherwise run
`./deploy.sh` first. To re-seed from `bifrost.conf`, uninstall and deploy
again. Every client then needs a new config, since the server key is new.

## Speed

VPN traffic can't use the hardware NAT offload, so the CPU encrypts it. A
Filogic 830 router (4× Cortex-A53 at 2 GHz, as in most AX6000s) handles
several hundred Mbps. Usually your
home upload speed is the real limit, since it's the remote client's download
speed. Other traffic stays offloaded.
