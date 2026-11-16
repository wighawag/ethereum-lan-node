"""ethereum-lan-node-wired: serve DHCP on the box's cable only when nobody else does.

The decision record is docs/adr/0001-the-cable-gets-a-dhcp-server-only-when-nobody-else-serves-one.md;
nix/wired.nix explains the knobs. In short, one loop, every TICK seconds:

  no carrier             -> stop serving, drop the address, start over.
  the box has an address on another network (a router gave it one)
                         -> never serve; if serving, stop at once and linger.
  quiet for CLIENT_WAIT  -> probe: broadcast DHCPDISCOVERs and listen. Nobody
                            answers -> take ADDRESS and start dnsmasq.
  serving                -> probe again every PROBE_INTERVAL; any answer from
                            a server that is not us -> stop at once, linger.
  lingering              -> dnsmasq is gone, ADDRESS stays (deprecated, so
                            Avahi stops announcing it) until every lease we
                            gave out has expired, then it goes too. Meanwhile
                            our former clients' renewals get a DHCPNAK, so
                            they move to the new server at their next renewal
                            (every RENEW_SECONDS) instead of at expiry.

The probe speaks raw Ethernet (AF_PACKET) so it never fights NetworkManager's
own DHCP client for UDP port 68, and uses a random MAC so a router does not
confuse it with the box. Our own dnsmasq answers the probe too; its offers
name ADDRESS as the server and are ignored.
"""

import ipaddress
import json
import os
import random
import select
import signal
import socket
import struct
import subprocess
import sys
import time

IFACE = os.environ["WIRED_INTERFACE"]
ADDRESS = os.environ["SERVER_ADDRESS"]
PREFIX = int(os.environ.get("SERVER_PREFIX", "24"))
RANGE_START = os.environ["RANGE_START"]
RANGE_END = os.environ["RANGE_END"]
LEASE_SECONDS = int(os.environ.get("LEASE_SECONDS", "120"))
CLIENT_WAIT = int(os.environ.get("CLIENT_WAIT", "30"))
PROBE_INTERVAL = int(os.environ.get("PROBE_INTERVAL", "30"))
PROBE_TRIES = int(os.environ.get("PROBE_TRIES", "3"))
PROBE_WINDOW = float(os.environ.get("PROBE_WINDOW", "6"))
RENEW_SECONDS = int(os.environ.get("RENEW_SECONDS", str(LEASE_SECONDS // 4)))
LINGER = int(os.environ.get("LINGER", str(LEASE_SECONDS + 60)))
DNSMASQ = os.environ.get("DNSMASQ", "dnsmasq")
RUN_DIR = os.environ.get("RUNTIME_DIRECTORY", "/run/ethereum-lan-node-wired")
TICK = 2

CIDR = f"{ADDRESS}/{PREFIX}"


def log(msg):
    print(msg, flush=True)


def run(*args, check=False):
    return subprocess.run(list(args), check=check, capture_output=True, text=True)


def carrier():
    try:
        with open(f"/sys/class/net/{IFACE}/carrier") as f:
            return f.read().strip() == "1"
    except OSError:
        # Missing interface, or administratively down (NetworkManager brings
        # it up): either way there is no cable we could serve on.
        return False


def addresses():
    out = run("ip", "-j", "-4", "addr", "show", "dev", IFACE).stdout
    try:
        links = json.loads(out or "[]")
    except ValueError:
        return []
    return [a for link in links for a in link.get("addr_info", [])]


def foreign_addresses():
    """Addresses on the cable that are not ours and not link-local: a sign that
    another network (a router, a venue LAN) is on the other end."""
    return [a["local"] for a in addresses()
            if a.get("scope") == "global" and a.get("local") != ADDRESS]


def mac_of_iface():
    with open(f"/sys/class/net/{IFACE}/address") as f:
        return f.read().strip()


# --- the probe -------------------------------------------------------------

def checksum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def discover_frame(mac, xid):
    bootp = struct.pack(
        "!BBBBIHH4s4s4s4s16s64s128s",
        1, 1, 6, 0, xid, 0, 0x8000,  # BOOTREQUEST, ethernet, broadcast flag
        b"\0" * 4, b"\0" * 4, b"\0" * 4, b"\0" * 4,
        mac + b"\0" * 10, b"\0" * 64, b"\0" * 128,
    )
    options = (b"\x63\x82\x53\x63"
               + bytes([53, 1, 1])            # DHCPDISCOVER
               + bytes([55, 3, 1, 3, 54])     # ask for mask, router, server id
               + bytes([255]))
    payload = bootp + options
    payload += b"\0" * max(0, 300 - len(payload))
    udp = struct.pack("!HHHH", 68, 67, 8 + len(payload), 0) + payload  # checksum 0: allowed on IPv4
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), random.randint(0, 0xFFFF), 0,
                     64, 17, 0, b"\0" * 4, b"\xff" * 4)
    ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    return b"\xff" * 6 + mac + b"\x08\x00" + ip + udp


def parse_reply(frame, xid):
    """The server id of a DHCP reply to `xid` in an Ethernet frame, or None."""
    if len(frame) < 14 + 20 + 8 + 240 or frame[12:14] != b"\x08\x00":
        return None
    ip = frame[14:]
    ihl = (ip[0] & 0x0F) * 4
    if ip[9] != 17:
        return None
    udp = ip[ihl:]
    if len(udp) < 8 + 240 or struct.unpack("!H", udp[2:4])[0] != 68:
        return None
    bootp = udp[8:]
    if bootp[0] != 2 or struct.unpack("!I", bootp[4:8])[0] != xid or bootp[236:240] != b"\x63\x82\x53\x63":
        return None
    server_id = parse_options(bootp[240:]).get(54, b"")
    if len(server_id) == 4:
        return socket.inet_ntoa(server_id)
    return socket.inet_ntoa(ip[12:16])  # no server id: the IP source


def probe():
    """Broadcast DHCPDISCOVERs on the cable for PROBE_WINDOW seconds and return
    the DHCP servers that answered, other than ourselves."""
    found = set()
    try:
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
        s.bind((IFACE, 0))
    except OSError as e:
        log(f"probe: cannot open a raw socket on {IFACE}: {e}; treating the cable as busy")
        return {"(probe failed)"}
    try:
        mac = bytes([0x02] + [random.randint(0, 255) for _ in range(5)])
        xid = random.getrandbits(32)
        frame = discover_frame(mac, xid)
        start = time.monotonic()
        sends = [start + k * PROBE_WINDOW / PROBE_TRIES for k in range(PROBE_TRIES)]
        while True:
            now = time.monotonic()
            if now >= start + PROBE_WINDOW:
                break
            while sends and sends[0] <= now:
                sends.pop(0)
                try:
                    s.send(frame)
                except OSError as e:
                    log(f"probe: send failed: {e}")
            wait = (sends[0] if sends else start + PROBE_WINDOW) - now
            r, _, _ = select.select([s], [], [], max(0.05, wait))
            if r:
                server = parse_reply(s.recv(4096), xid)
                if server and server != ADDRESS:
                    found.add(server)
    finally:
        s.close()
    return found


# --- serving ----------------------------------------------------------------

class Server:
    def __init__(self):
        self.proc = None

    def address_present(self):
        return any(a.get("local") == ADDRESS for a in addresses())

    def add_address(self):
        if not self.address_present():
            run("ip", "addr", "add", CIDR, "dev", IFACE)
        else:
            run("ip", "addr", "change", CIDR, "dev", IFACE, "preferred_lft", "forever", "valid_lft", "forever")

    def deprecate_address(self):
        # Still reachable (deprecation only stops the kernel picking it as a
        # source), but Avahi no longer announces it beside a real address, so
        # ethereum.local resolves to the address the router gave the box.
        if self.address_present():
            run("ip", "addr", "change", CIDR, "dev", IFACE, "preferred_lft", "0", "valid_lft", "forever")

    def drop_address(self):
        if self.address_present():
            run("ip", "addr", "del", CIDR, "dev", IFACE)

    def start(self):
        self.add_address()
        if self.proc and self.proc.poll() is None:
            return
        leases = os.path.join(RUN_DIR, "leases")
        try:
            os.unlink(leases)
        except FileNotFoundError:
            pass
        netmask = str(ipaddress.ip_network(CIDR, strict=False).netmask)
        args = [
            DNSMASQ, "--keep-in-foreground", "--conf-file=/dev/null", "--log-facility=-",
            "--port=0",                    # DHCP only, no DNS
            f"--interface={IFACE}", "--bind-dynamic",  # bound to the cable alone (SO_BINDTODEVICE), beside the hotspot's dnsmasq
            f"--dhcp-range={RANGE_START},{RANGE_END},{netmask},{LEASE_SECONDS}s",
            # Renew often, so a client hears our DHCPNAK soon after we stop.
            f"--dhcp-option=option:T1,{RENEW_SECONDS}",
            f"--dhcp-option=option:T2,{RENEW_SECONDS * 2}",
            "--dhcp-option=option:router",      # no gateway: a laptop on Wi-Fi keeps its internet
            "--dhcp-option=option:dns-server",  # no DNS: it keeps its resolver too
            f"--dhcp-host={mac_of_iface()},ignore",  # never answer the box's own DHCP client
            f"--dhcp-leasefile={leases}",
            "--pid-file=",
            "--log-dhcp",
        ]
        # Not --dhcp-authoritative: never NAK a client of another server.
        self.proc = subprocess.Popen(args)
        log(f"serving DHCP on {IFACE} as {ADDRESS} ({RANGE_START}-{RANGE_END}, {LEASE_SECONDS}s leases)")

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None


class Retirer:
    """While lingering: answer our FORMER clients' renewals with a DHCPNAK, so
    they drop the 10.43 lease and look for the new server right away.

    Only requests about our own subnet are answered (a renewal or rebind from
    an address in it, a reboot asking for one, or a request naming us as the
    server). Everything else, including every request about the new router's
    addresses, is ignored: this never interferes with another server.
    """

    def __init__(self):
        self.sock = None
        self.net = ipaddress.ip_network(CIDR, strict=False)

    def open(self):
        if self.sock:
            return
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, IFACE.encode())
            s.bind(("", 67))
            self.sock = s
        except OSError as e:
            log(f"cannot listen on {IFACE}:67 to retire leases ({e}); clients will move when their lease expires")

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def ours(self, ip):
        try:
            return ip != "0.0.0.0" and ipaddress.ip_address(ip) in self.net
        except ValueError:
            return False

    def handle(self):
        try:
            data, _ = self.sock.recvfrom(4096)
        except OSError:
            return
        if len(data) < 240 or data[0] != 1 or data[236:240] != b"\x63\x82\x53\x63":
            return
        opts = parse_options(data[240:])
        if opts.get(53) != b"\x03":  # DHCPREQUEST
            return
        ciaddr = socket.inet_ntoa(data[12:16])
        requested = socket.inet_ntoa(opts[50]) if len(opts.get(50, b"")) == 4 else "0.0.0.0"
        server_id = socket.inet_ntoa(opts[54]) if len(opts.get(54, b"")) == 4 else None
        if not (server_id == ADDRESS or (server_id is None and (self.ours(ciaddr) or self.ours(requested)))):
            return
        nak = (struct.pack("!BBBBIHH", 2, data[1], data[2], 0, struct.unpack("!I", data[4:8])[0], 0, struct.unpack("!H", data[10:12])[0])
               + b"\0" * 12 + data[24:28] + data[28:44] + b"\0" * 192
               + b"\x63\x82\x53\x63" + bytes([53, 1, 6, 54, 4]) + socket.inet_aton(ADDRESS) + bytes([255]))
        # Broadcast, as RFC 2131 says, AND unicast to a renewing client: one
        # in RENEWING listens on a socket bound to its leased address, which
        # never sees a broadcast (dhcpcd ignored broadcast NAKs until it fell
        # back to rebinding, measured in the VM test).
        targets = [("255.255.255.255", 68)]
        if self.ours(ciaddr):
            targets.append((ciaddr, 68))
        try:
            for t in targets:
                self.sock.sendto(nak, t)
            log(f"DHCPNAK to {data[28:34].hex(':')} ({ciaddr if ciaddr != '0.0.0.0' else requested}): we no longer serve, look again")
        except OSError as e:
            log(f"DHCPNAK send failed: {e}")


def parse_options(opts):
    out = {}
    i = 0
    while i < len(opts) and opts[i] != 255:
        if opts[i] == 0:
            i += 1
            continue
        if i + 1 >= len(opts):
            break
        code, length = opts[i], opts[i + 1]
        out[code] = opts[i + 2:i + 2 + length]
        i += 2 + length
    return out


def main():
    server = Server()
    retirer = Retirer()
    state = "waiting"
    quiet_since = None
    next_probe = 0.0
    linger_until = 0.0

    def shutdown(*_):
        retirer.close()
        server.stop()
        server.drop_address()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # A previous run that died may have left the address behind.
    server.drop_address()
    log(f"watching {IFACE}: serve as {ADDRESS} only after {CIDR} sees no DHCP server for {CLIENT_WAIT}s")

    def go_linger(why):
        nonlocal state, linger_until
        server.stop()
        server.deprecate_address()
        retirer.open()
        linger_until = time.monotonic() + LINGER
        state = "lingering"
        log(f"stopped serving: {why}; keeping {ADDRESS} for {LINGER}s so clients can move")

    while True:
        now = time.monotonic()
        if not carrier():
            if state != "waiting" or server.address_present():
                retirer.close()
                server.stop()
                server.drop_address()
                log(f"{IFACE}: no carrier, not serving")
            state, quiet_since = "waiting", None
            time.sleep(TICK)
            continue

        foreign = foreign_addresses()

        if state == "waiting":
            if foreign:
                quiet_since = None
            else:
                quiet_since = quiet_since or now
                if now - quiet_since >= CLIENT_WAIT:
                    others = probe()
                    if others:
                        log(f"not serving: DHCP server(s) {', '.join(sorted(others))} answered on {IFACE}")
                        quiet_since = time.monotonic()
                    elif foreign_addresses():
                        quiet_since = None
                    else:
                        server.start()
                        state = "serving"
                        next_probe = time.monotonic() + PROBE_INTERVAL

        elif state == "serving":
            if foreign:
                go_linger(f"the box got {', '.join(foreign)} from another network")
            elif now >= next_probe:
                others = probe()
                if others:
                    go_linger(f"DHCP server(s) {', '.join(sorted(others))} answered on {IFACE}")
                else:
                    next_probe = time.monotonic() + PROBE_INTERVAL
            if state == "serving":
                if not server.alive():
                    log("dnsmasq exited; restarting it")
                    server.start()
                else:
                    server.add_address()  # NetworkManager may have flushed it

        elif state == "lingering":
            if now >= linger_until:
                retirer.close()
                server.drop_address()
                state, quiet_since = "waiting", None
                log(f"dropped {ADDRESS}: every lease we gave out has expired")

        # Sleep a tick, answering former clients meanwhile when lingering.
        until = time.monotonic() + TICK
        while True:
            left = until - time.monotonic()
            if left <= 0:
                break
            if retirer.sock:
                r, _, _ = select.select([retirer.sock], [], [], left)
                if r:
                    retirer.handle()
            else:
                time.sleep(left)


if __name__ == "__main__":
    if sys.argv[1:] == ["--probe"]:
        # One probe, for a human at an event: is there a DHCP server on this
        # cable (other than the box itself)? Exit 0 when one answered.
        servers = probe()
        for server in sorted(servers):
            print(server)
        sys.exit(0 if servers else 1)
    main()
