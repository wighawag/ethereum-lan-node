# The Ethernet port gets a DHCP server, but only when nobody else serves one

Decided 2026-11-11, after the box worked on Wi-Fi and on a venue's Ethernet but not on a cable straight into a laptop.

## Context

On a cable with no router at the other end (a laptop, or a switch with several PCs) nobody hands out addresses. NetworkManager's default wired profile only does DHCP, so the box ended up with no IPv4 address; macOS and Windows gave themselves a 169.254 address the box had nothing in common with, and a Linux laptop got nothing. Only IPv6 link-local was left, which browsers cannot use and the fleet's IPv4-only mDNS does not resolve.

The box must work in every case with nobody at a keyboard: a venue LAN, a direct cable, a switch of PCs, and a router appearing on that switch halfway through an event.

## Decision

Two layers, configured in `nix/wired.nix`, each usable alone:

- **A, link-local fallback** (`network.wired.linkLocalFallback`, on by default once `network.wired.interface` is set): NetworkManager's `ipv4.link-local = fallback` gives the box a 169.254 address whenever DHCP gives it none; Avahi announces it. It can never disturb a network. It reaches only clients that also do link-local (macOS and Windows do by themselves, a stock Linux NetworkManager does not).
- **B, a fallback DHCP server** (`network.wired.fallbackServer.enable`, off by default in the module, on for wighawag's box): after `clientWait` seconds without a lease, the box probes the cable for a DHCP server and, if none answers, takes 10.43.0.1/24 and runs its own dnsmasq there. Every PC that does DHCP (all of them, by default) gets an address, which is what makes a switch of PCs work.

**A alone is always a valid configuration**: `fallbackServer.enable = false` removes B entirely (no unit, no open port) and leaves A as it is. That is the fallback if B ever misbehaves at a venue.

### How B avoids being a rogue DHCP server

A DHCP server on a port that may be plugged into someone else's network is the classic rogue-DHCP accident, so B is built to step aside:

1. **Listen before speaking.** It serves only after NetworkManager got no lease for `clientWait` seconds AND a probe (three DHCPDISCOVERs over `probeWindow` seconds, raw Ethernet, random MAC) heard no server.
2. **Keep listening.** While serving, it probes every `probeInterval` seconds, and NetworkManager's own DHCP client keeps running (its timeout is infinite). Another server answering the probe, or the box getting an address from another network, stops B at once.
3. **Reset on unplug.** No carrier stops B and drops its address; the next plug starts from step 1.
4. **Small blast radius.** Leases are 120 s (dnsmasq's minimum) with renewal every 30 s. It is not authoritative, so it never NAKs another server's clients. It offers no gateway and no DNS server, so a laptop also on Wi-Fi keeps its internet and resolver. It never answers the box's own DHCP client. Its dnsmasq is bound to the cable alone (SO_BINDTODEVICE), beside the hotspot's.
5. **Hand clients over.** After stopping it keeps 10.43.0.1 for a lease time plus a minute, deprecated (so Avahi announces the router-given address instead), and answers its FORMER clients' renewals with a DHCPNAK, so they look for the new server at their next renewal (within 30 s) instead of at expiry. It NAKs only requests about its own subnet: never one about another server's addresses.

Measured in `checks.wired` (a router booted onto a switch where the box was serving): the box stopped serving as soon as it got the router's lease, the PC moved to the router 20 s later at its first renewal, and the landing page by `ethereum.local` failed for about 20 one-second samples out of 200, all in that window.

## Considered options

- **A only.** Safe, but a switch of Linux PCs (or Debian laptops) would not reach the box without per-client setup. Kept as the fallback configuration rather than the default for this box.
- **NetworkManager's `ipv4.method = shared` as a second, lower-priority profile.** One line of config, but it serves DHCP without ever checking for another server, keeps serving if the cable is moved without a carrier drop, and uses 10.42.0.0/24 (the hotspot's) by default. Rejected: no rogue-DHCP protection at all.
- **Handing out DNS (the box) on the cable**, so `ethereum.lan` works for clients that cannot do mDNS (some Windows setups). Rejected for now: it would put the box in every lookup path of a laptop that is also on Wi-Fi. The name is mDNS (`<hostname>.local`) or the IP shown on the landing page.
- **Stopping without a hand-over** (drop 10.43.0.1 at once, no NAK). Measured: PCs then stay on the dead subnet until their lease expires, up to two minutes unable to reach the box.

## Consequences

- The box answers on 10.43.0.1 on a cable with no router, as it answers on 10.42.0.1 on its hotspot. A literal `http://10.43.0.1` tab dies when a router takes over; one opened by `ethereum.local` survives, since games use same-host URLs.
- A client that only does link-local (no DHCP) on a cable where B is serving cannot reach `ethereum.local`: Avahi announces only the box's global address (10.43.0.1) when it has one, and the client has no route to it.
- `sudo ethereum-lan-node-dhcp-probe` on the box lists the DHCP servers on the cable (other than the box's own), for diagnosing a venue.
