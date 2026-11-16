# The box's Ethernet port, for every way it gets plugged in.
#
#   - into a router or a venue LAN: a DHCP client, as any laptop would be.
#   - straight into a laptop, or into a switch with PCs and no router: nobody
#     hands out addresses there, so two things make the box reachable anyway.
#
# A, LINK-LOCAL FALLBACK (`linkLocalFallback`, on by default): when DHCP gives
# NetworkManager nothing, the box takes a 169.254.x.y address, the one macOS
# and Windows give themselves in the same situation, and Avahi announces it as
# <hostname>.local. It can never disturb a network. Its limit: the other end
# must do link-local too, which a stock Linux NetworkManager does not.
#
# B, A FALLBACK DHCP SERVER (`fallbackServer.enable`, OFF by default): after
# `clientWait` seconds with no lease, the box probes the cable for a DHCP
# server and, if none answers, takes `address` (10.43.0.1) and hands out
# leases itself, so any PC that does DHCP (all of them, by default) gets an
# address and reaches the box. It is how a switch full of PCs works.
#
# A DHCP server on an uplink is the classic rogue-DHCP accident, so B is
# built to step aside (the full reasoning: docs/adr/0001-*):
#
#   - it serves only after hearing nobody, and re-probes every
#     `probeInterval` seconds while serving; any other server, or the box
#     getting an address from one, stops it at once;
#   - an unplugged cable stops it, and the next plug starts from scratch;
#   - leases are short (`leaseTime`), so clients move to a real router soon
#     after it appears; it is not authoritative (never NAKs another server's
#     clients); it offers no gateway and no DNS, so a laptop also on Wi-Fi
#     keeps its internet and resolver;
#   - clients renew every leaseTime/4 (30 s); once it has stopped, the box
#     answers its FORMER clients' renewals with a DHCPNAK (only requests about
#     its own subnet, never another server's), so they move to the router
#     within about 30 s instead of at lease expiry;
#   - after stopping it keeps `address` (deprecated, so Avahi announces the
#     router-given address instead) until every lease it gave out has
#     expired, then drops it.
#
# B layers on A; turning B off leaves A exactly as it is. B needs A's
# NetworkManager profile (the box's DHCP client on that port is the second
# half of the detection), so it requires `network.networkmanager`.
{
  config,
  lib,
  pkgs,
  ...
}: let
  top = config.services.ethereumLanNode;
  cfg = top.network.wired;
  srv = cfg.fallbackServer;
  subnet = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." srv.address));

  daemon = pkgs.writers.writePython3Bin "ethereum-lan-node-wired" {
    flakeIgnore = ["E501" "W503"];
  } (builtins.readFile ./pkgs/wired-fallback/wired_fallback.py);

  env = {
    WIRED_INTERFACE = cfg.interface;
    SERVER_ADDRESS = srv.address;
    SERVER_PREFIX = "24";
    RANGE_START = "${subnet}.20";
    RANGE_END = "${subnet}.250";
    LEASE_SECONDS = toString srv.leaseTime;
    RENEW_SECONDS = toString (srv.leaseTime / 4);
    CLIENT_WAIT = toString srv.clientWait;
    PROBE_INTERVAL = toString srv.probeInterval;
    PROBE_WINDOW = toString srv.probeWindow;
    LINGER = toString (srv.leaseTime + 60);
    DNSMASQ = lib.getExe' pkgs.dnsmasq "dnsmasq";
  };

  # `sudo ethereum-lan-node-dhcp-probe`: which DHCP servers answer on the
  # cable, other than the box's own. Exit 0 if any did. Handy at a venue.
  probeCommand = pkgs.writeShellScriptBin "ethereum-lan-node-dhcp-probe" ''
    ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") env)}
    exec ${lib.getExe daemon} --probe
  '';
in {
  options.services.ethereumLanNode.network.wired = {
    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "enp1s0";
      description = ''
        The Ethernet port. When set, the box gets a NetworkManager profile for
        it (DHCP, plus `linkLocalFallback`) and, if enabled, the fallback DHCP
        server. When null, NetworkManager's own default wired profile applies.
      '';
    };

    linkLocalFallback = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Take a 169.254.x.y address when DHCP gives none (A).";
    };

    fallbackServer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Hand out addresses on the cable when no other DHCP server answers
          there (B). Off by default: a DHCP server on a port that may be
          plugged into someone else's network is something to opt into.
        '';
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = "10.43.0.1";
        description = "The box's address while it serves (a /24, the .1). Not the hotspot's 10.42.0.0/24.";
      };
      leaseTime = lib.mkOption {
        type = lib.types.ints.between 120 3600;
        default = 120;
        description = "Lease length in seconds. Short, so clients move to a real router soon after one appears. dnsmasq's minimum is 120.";
      };
      clientWait = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Seconds without a lease, after carrier, before probing for a DHCP server.";
      };
      probeInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "While serving, seconds between probes for another DHCP server.";
      };
      probeWindow = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
        description = "How long one probe listens; it sends three DHCPDISCOVERs across it.";
      };
    };
  };

  config = lib.mkIf (top.enable && cfg.interface != null) (lib.mkMerge [
    {
      assertions = [
        {
          assertion = top.network.networkmanager;
          message = "services.ethereumLanNode.network.wired needs network.networkmanager.";
        }
        {
          assertion = !(top.network.ap.enable && lib.hasPrefix "${subnet}." top.network.ap.address);
          message = "services.ethereumLanNode.network.wired.fallbackServer.address must not be in the hotspot's subnet.";
        }
        {
          assertion = lib.hasSuffix ".1" srv.address;
          message = "services.ethereumLanNode.network.wired.fallbackServer.address must be the .1 of its /24.";
        }
      ];

      environment.systemPackages = [probeCommand];

      # A higher priority than NetworkManager's automatic "Wired connection 1",
      # so this profile is the one the port comes up with.
      networking.networkmanager.ensureProfiles.profiles.eln-wired = {
        connection = {
          id = "eln-wired";
          type = "ethernet";
          interface-name = cfg.interface;
          autoconnect = "true";
          autoconnect-priority = "10";
        };
        ipv4 =
          {
            method = "auto";
            # Never give up on DHCP: a router plugged in later must still be
            # found, by NetworkManager and therefore by B's detection.
            dhcp-timeout = "2147483647";
            may-fail = "true";
          }
          # 4 = NM_SETTING_IP4_LL_FALLBACK (keyfiles store this enum as a
          # number): link-local only while no other IPv4 address is set.
          // lib.optionalAttrs cfg.linkLocalFallback {link-local = "4";};
        ipv6.method = "auto";
      };
    }

    (lib.mkIf srv.enable {
      networking.firewall.interfaces.${cfg.interface}.allowedUDPPorts = [67];

      systemd.services.ethereum-lan-node-wired = {
        description = "ethereum LAN node: serve DHCP on ${cfg.interface} when nobody else does";
        wantedBy = ["multi-user.target"];
        after = ["NetworkManager.service"];
        path = [pkgs.iproute2];
        environment = env;
        serviceConfig = {
          ExecStart = lib.getExe daemon;
          # If it dies, never leave the address (and so the subnet) behind.
          ExecStopPost = "-${pkgs.iproute2}/bin/ip addr del ${srv.address}/24 dev ${cfg.interface}";
          Restart = "always";
          RestartSec = 5;
          RuntimeDirectory = "ethereum-lan-node-wired";
        };
      };
    })
  ]);
}
