# The network: the box's own Wi-Fi, the networks it joins, and sharing an
# uplink when there is one.
#
# THREE MODES, ONE CONFIG, decided by what is plugged in rather than by a
# switch:
#
#   - hotspot: hostapd on `ap.interface` at a FIXED address (10.42.0.1), with
#     dnsmasq for DHCP and DNS on that interface only. Fixed on purpose: a
#     printed QR card (join the Wi-Fi, open http://10.42.0.1) always works.
#   - joined: NetworkManager brings up Ethernet (DHCP) and any known Wi-Fi in
#     range on the OTHER radio. The box then also answers on whatever address
#     that network gave it; the landing page shows it.
#   - both: the hotspot keeps running beside an uplink, and hotspot clients
#     get the internet through it (NAT), but NOT the uplink's private ranges
#     or the tailnet (see `ap.blockPrivateNetworks`).
#
# Two radios are what make "both" robust: a dedicated AP radio and a separate
# client radio never have to agree on a channel. A single radio that can do
# AP+station (iwlwifi claims it) is possible by pointing `ap.interface` at a
# virtual interface, but it is the degraded case.
#
# NetworkManager owns the uplinks and is told to leave the AP interface alone.
# (hostapd's module then warns that an interface is configured for both client
# and AP: a false positive here. NetworkManager runs wpa_supplicant over D-Bus
# with interface auto-detection off, and never hands it an unmanaged device.)
# Known Wi-Fi networks are the host's business (networking.networkmanager.
# ensureProfiles, with the passwords from wherever the host keeps secrets).
{
  config,
  lib,
  pkgs,
  ...
}: let
  top = config.services.ethereumLanNode;
  cfg = top.network;
  ap = cfg.ap;
  subnet = "${lib.concatStringsSep "." (lib.take 3 (lib.splitString "." ap.address))}";
  defaultChannel =
    if ap.band == "5g"
    then 36
    else 6;
in {
  options.services.ethereumLanNode.network = {
    networkmanager = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Let NetworkManager manage the uplinks (Ethernet, Wi-Fi client).";
    };

    ap = {
      enable = lib.mkEnableOption "the box's own Wi-Fi hotspot";
      interface = lib.mkOption {
        type = lib.types.str;
        example = "wlx00c0cab14964";
        description = "The wireless interface that becomes the access point. It is unmanaged by NetworkManager.";
      };
      ssid = lib.mkOption {
        type = lib.types.str;
        default = "master node";
      };
      passphrase = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "I am vitalik";
        description = "WPA2 passphrase (8 to 63 characters). Public by default: it is printed on a card. Set to null and use passphraseFile to keep it out of the store.";
      };
      passphraseFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "A file holding the passphrase, instead of `passphrase`.";
      };
      countryCode = lib.mkOption {
        type = lib.types.str;
        default = "GB";
        description = "Regulatory domain. Without one, every 5 GHz channel is no-IR and the AP cannot start there.";
      };
      band = lib.mkOption {
        type = lib.types.enum ["2g" "5g"];
        default = "5g";
        description = "5g: faster and quieter at events; 2g: for old phones.";
      };
      channel = lib.mkOption {
        type = lib.types.int;
        default = defaultChannel;
        defaultText = lib.literalExpression "36 on 5g, 6 on 2g";
        description = "A non-DFS channel, so the AP starts at once instead of after a radar scan.";
      };
      htCapabilities = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["HT40" "SHORT-GI-20" "SHORT-GI-40"];
        description = "802.11n capabilities to request. Trim this if hostapd reports one the driver lacks.";
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = "10.42.0.1";
        description = "The box's address on its hotspot (a /24). Fixed, so printed QR codes stay valid.";
      };
      blockPrivateNetworks = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Forward hotspot clients to the public internet only: never to the
          uplink's private ranges (the venue's or home LAN, the router) nor
          to tailscale. Strangers join this Wi-Fi.
        '';
      };
    };

    shareInternet = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "NAT hotspot clients out of whatever uplink has the default route.";
    };
  };

  config = lib.mkIf top.enable (lib.mkMerge [
    (lib.mkIf cfg.networkmanager {
      networking.networkmanager.enable = true;
      networking.networkmanager.unmanaged = lib.optional ap.enable "interface-name:${ap.interface}";
    })

    (lib.mkIf ap.enable {
      assertions = [
        {
          assertion = (ap.passphrase == null) != (ap.passphraseFile == null);
          message = "services.ethereumLanNode.network.ap: set exactly one of passphrase and passphraseFile.";
        }
        {
          assertion = lib.hasSuffix ".1" ap.address;
          message = "services.ethereumLanNode.network.ap.address must be the .1 of its /24.";
        }
      ];

      hardware.wirelessRegulatoryDatabase = true;
      # The client radio follows the same country, so it can use the same
      # channels as the AP.
      boot.extraModprobeConfig = ''
        options cfg80211 ieee80211_regdom="${ap.countryCode}"
      '';

      services.hostapd = {
        enable = true;
        radios.${ap.interface} = {
          inherit (ap) band channel countryCode;
          wifi4 = {
            enable = true;
            capabilities = ap.htCapabilities;
          };
          wifi5.enable = ap.band == "5g";
          networks.${ap.interface} = {
            inherit (ap) ssid;
            authentication =
              {
                # WPA2, not WPA3: every phone at an event has to get on.
                mode = "wpa2-sha1";
              }
              // (
                if ap.passphraseFile != null
                then {wpaPasswordFile = ap.passphraseFile;}
                else {wpaPassword = ap.passphrase;}
              );
          };
        };
      };

      networking.interfaces.${ap.interface}.ipv4.addresses = [
        {
          address = ap.address;
          prefixLength = 24;
        }
      ];

      services.dnsmasq = {
        enable = true;
        # The box itself keeps its normal resolver; dnsmasq serves the hotspot.
        resolveLocalQueries = false;
        settings = {
          interface = ap.interface;
          bind-dynamic = true;
          except-interface = "lo";
          domain-needed = true;
          bogus-priv = true;
          dhcp-authoritative = true;
          dhcp-range = ["${subnet}.20,${subnet}.250,255.255.255.0,12h"];
          dhcp-option = [
            "option:router,${ap.address}"
            "option:dns-server,${ap.address}"
          ];
          domain = "lan";
          local = "/lan/";
          address = [
            "/${config.networking.hostName}.lan/${ap.address}"
            "/ethereum.lan/${ap.address}"
          ];
        };
      };

      networking.firewall.interfaces.${ap.interface} = {
        allowedUDPPorts = [53 67];
        allowedTCPPorts = [53];
      };

      systemd.services.dnsmasq = {
        after = ["hostapd.service" "network-addresses-${ap.interface}.service"];
        wants = ["network-addresses-${ap.interface}.service"];
      };
    })

    (lib.mkIf (ap.enable && cfg.shareInternet) {
      networking.nat = {
        enable = true;
        internalInterfaces = [ap.interface];
        # No externalInterface: masquerade out of whichever uplink routes it.
      };
      networking.firewall.extraCommands = lib.mkIf ap.blockPrivateNetworks ''
        iptables -w -N eln-ap-forward 2>/dev/null || iptables -w -F eln-ap-forward
        iptables -w -D FORWARD -i ${ap.interface} -j eln-ap-forward 2>/dev/null || true
        iptables -w -I FORWARD 1 -i ${ap.interface} -j eln-ap-forward
        iptables -w -A eln-ap-forward -o tailscale0 -j DROP
        for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
          iptables -w -A eln-ap-forward -d "$range" -j DROP
        done
      '';
      networking.firewall.extraStopCommands = lib.mkIf ap.blockPrivateNetworks ''
        iptables -w -D FORWARD -i ${ap.interface} -j eln-ap-forward 2>/dev/null || true
        iptables -w -F eln-ap-forward 2>/dev/null || true
        iptables -w -X eln-ap-forward 2>/dev/null || true
      '';
    })
  ]);
}
