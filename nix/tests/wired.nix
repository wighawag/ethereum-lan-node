# The Ethernet port (nix/wired.nix), with nothing but the cable: no chain, no
# explorer, only the landing page to reach.
#
# vlan 1, a switch with PCs and no router, later a router:
#   box     the LAN node with the fallback DHCP server (B)
#   client  a PC that does DHCP (dhcpcd) and mDNS, as a Debian laptop does
#   router  a home router (dnsmasq, authoritative), booted halfway through
#
# vlan 2, a direct cable to a box WITHOUT the server (A only):
#   linklocal  the LAN node with link-local fallback only
#   laptop     a PC with only a 169.254 address, as macOS and Windows give
#              themselves
#
# Timings are shortened (clientWait, probeInterval) so the test is minutes;
# leaseTime stays the shipped 120 s, since the move to a router depends on it.
{
  pkgs,
  lib,
  module,
}: let
  cable = vlan: {
    virtualisation.vlans = [];
    virtualisation.interfaces.eth1 = {inherit vlan;};
  };

  mdns = {
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };
  };

  lanNode = {fallback}: {
    imports = [
      module
      mdns
      (cable (
        if fallback
        then 1
        else 2
      ))
    ];
    environment.systemPackages = [pkgs.curl pkgs.jq];
    services.ethereumLanNode = {
      enable = true;
      chain.enable = false;
      explorer.enable = false;
      faucet.enable = false;
      network.wired = {
        interface = "eth1";
        fallbackServer = {
          enable = fallback;
          clientWait = 10;
          probeInterval = 10;
          probeWindow = 3;
        };
      };
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "ethereum-lan-node-wired";

    nodes.box = {
      imports = [(lanNode {fallback = true;})];
      networking.hostName = "ethereum";
    };

    nodes.linklocal = {
      imports = [(lanNode {fallback = false;})];
      networking.hostName = "linklocal";
    };

    nodes.client = {
      imports = [mdns (cable 1)];
      environment.systemPackages = [pkgs.curl];
      networking.useDHCP = false;
      networking.interfaces.eth1.useDHCP = true;
    };

    nodes.laptop = {
      imports = [mdns (cable 2)];
      environment.systemPackages = [pkgs.curl];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "169.254.20.20";
          prefixLength = 16;
        }
      ];
    };

    nodes.router = {
      imports = [(cable 1)];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "192.168.77.1";
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedUDPPorts = [67];
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          port = 0;
          dhcp-range = ["192.168.77.50,192.168.77.150,255.255.255.0,1h"];
          dhcp-authoritative = true;
        };
      };
    };

    testScript = ''
      import re

      def ipv4(machine, prefix):
          out = machine.succeed("ip -4 -o addr show dev eth1")
          m = re.search(r"inet (" + re.escape(prefix) + r"[0-9.]+)/", out)
          return m.group(1) if m else None

      for m in [box, client, linklocal, laptop]:
          m.start()

      with subtest("A alone: a link-local laptop reaches a box without the server"):
          linklocal.wait_for_unit("NetworkManager.service")
          linklocal.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -q 'inet 169.254.'", timeout=120)
          linklocal.fail("systemctl cat ethereum-lan-node-wired.service")
          linklocal.wait_for_open_port(80)
          laptop.wait_until_succeeds("getent hosts linklocal.local | grep -q '^169\\.254\\.'", timeout=120)
          laptop.succeed("curl -sf http://linklocal.local/config.json")

      with subtest("B: on a switch with no router, the box hands the PC an address"):
          box.wait_for_unit("ethereum-lan-node-wired.service")
          box.wait_until_succeeds("journalctl -u ethereum-lan-node-wired | grep -q 'serving DHCP on eth1'", timeout=120)
          client.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -q 'inet 10.43.0.'", timeout=120)
          box.wait_for_open_port(80)
          client.succeed("curl -sf http://10.43.0.1/config.json")
          # No gateway and no DNS from the box: a laptop also on Wi-Fi keeps both.
          client.fail("ip route show default | grep -q 10.43.0.1")
          client.fail("grep -q 10.43.0.1 /etc/resolv.conf")
          client.wait_until_succeeds("getent hosts ethereum.local | grep -q '^10\\.43\\.0\\.1 '", timeout=120)
          client.succeed("curl -sf http://ethereum.local/config.json")
          # The box never leased itself an address from its own server, and its
          # probe does not count its own dnsmasq as another server.
          assert ipv4(box, "10.43.0.") == "10.43.0.1", box.succeed("ip -4 -o addr show dev eth1")
          box.fail("ethereum-lan-node-dhcp-probe")

      with subtest("a router joins the switch: the box steps aside and stays reachable"):
          # Every second, the PC loads the landing page by name, as a player would.
          client.succeed(
              "systemd-run --unit=reach --setenv=PATH=/run/current-system/sw/bin sh -c 'while true; do "
              "if curl -sf -m 2 -o /dev/null http://ethereum.local/config.json; then echo ok; else echo FAIL; fi >> /tmp/reach; "
              "sleep 1; done'"
          )
          router.start()
          router.wait_for_unit("dnsmasq.service")
          # The probe hears the router (the path that catches a router whose
          # offer the box's own client has not taken yet).
          assert box.wait_until_succeeds("ethereum-lan-node-dhcp-probe", timeout=60).split() == ["192.168.77.1"]
          box.wait_until_succeeds("journalctl -u ethereum-lan-node-wired | grep -q 'stopped serving'", timeout=120)
          box.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -q 'inet 192.168.77.'", timeout=240)
          # While it lingers, the box still answers on 10.43.0.1, for PCs on old leases.
          box.succeed("ip -4 -o addr show dev eth1 | grep -q 'inet 10.43.0.1/24'")
          client.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -q 'inet 192.168.77.'", timeout=300)
          client.wait_until_fails("ip -4 -o addr show dev eth1 | grep -q 'inet 10.43.0.'", timeout=300)
          box.wait_until_succeeds("journalctl -u ethereum-lan-node-wired | grep -q 'dropped 10.43.0.1'", timeout=300)
          box.fail("ip -4 -o addr show dev eth1 | grep -q 'inet 10.43.0.1'")
          addr = ipv4(box, "192.168.77.")
          client.wait_until_succeeds(f"getent hosts ethereum.local | grep -q '^{re.escape(addr)} '", timeout=120)
          client.succeed(f"curl -sf http://{addr}/config.json")
          client.succeed("systemctl stop reach")
          samples = client.succeed("cat /tmp/reach").split()
          fails = samples.count("FAIL")
          print(f"reachability by name during the move: {len(samples) - fails} ok, {fails} failed")
          # A PC still on its old lease cannot reach the router-given address
          # until it moves, which the NAK at its next renewal (every 30 s)
          # makes happen: seconds of churn, never minutes.
          assert fails <= 40, samples

      with subtest("a box that boots onto a network with a router never serves"):
          box.shutdown()
          box.start()
          box.wait_for_unit("ethereum-lan-node-wired.service")
          box.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -q 'inet 192.168.77.'", timeout=180)
          box.sleep(30)
          box.fail("journalctl -b -u ethereum-lan-node-wired | grep -q 'serving DHCP'")
          box.fail("ip -4 -o addr show dev eth1 | grep -q 'inet 10.43.0.1'")
    '';
  }
