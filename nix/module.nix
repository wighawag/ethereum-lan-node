# services.ethereumLanNode: the whole box.
#
# The parts live in their own files and each has its own `enable`, so a box
# can run the chain without the hotspot, or the games without the explorer:
#
#   chain.nix     geth in dev mode, from a fixed genesis
#   explorer.nix  blockscout (pinned containers) + native postgres
#   faucet.nix    faucet-server, funded by the test mnemonic's account 0
#   network.nix   the Wi-Fi hotspot, the uplinks, internet sharing
#   games.nix     the games, the landing page and its status feed
#
# Everything a box remembers lives under `stateDir`, which is what makes
# `ethereum-lan-node-reset` one command (see the bottom of this file).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ethereumLanNode;
in {
  imports = [
    ./chain.nix
    ./explorer.nix
    ./faucet.nix
    ./network.nix
    ./games.nix
  ];

  options.services.ethereumLanNode = {
    enable = lib.mkEnableOption "the ethereum LAN node (chain, explorer, faucet, games, hotspot)";

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ethereum-lan-node";
      description = "Where the chain, the faucet and the games keep their state. Deleted by `ethereum-lan-node-reset`.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "LAN";
      description = "The chain's display name (explorer, landing page, wallets).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open every service port on every interface. This box exists to be
        reached by strangers' phones, on its hotspot and on whatever network
        it joined, so the default is open.
      '';
    };

    services = lib.mkOption {
      internal = true;
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          title = lib.mkOption {type = lib.types.str;};
          port = lib.mkOption {type = lib.types.port;};
          path = lib.mkOption {
            type = lib.types.str;
            default = "/";
          };
          unit = lib.mkOption {type = lib.types.str;};
          link = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the landing page links to it (false for an API).";
          };
        };
      });
      default = {};
      description = "What each part contributes to the landing page and the status feed.";
    };

    resetUnits = lib.mkOption {
      internal = true;
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Units the reset command stops before deleting state and starts again after.";
    };

    resetCommands = lib.mkOption {
      internal = true;
      type = lib.types.lines;
      default = "";
      description = "Extra state wiping (e.g. dropping the explorer's database), run while the units are stopped.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = ["d ${cfg.stateDir} 0755 root root - -"];

    # ONE command to start an event clean. It stops everything that remembers
    # the chain, deletes ALL of stateDir (chain, faucet rate limits, game
    # records and rooms) plus what the parts add to resetCommands, and starts
    # the same units again; each game's deploy unit then redeploys onto the
    # fresh chain.
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "ethereum-lan-node-reset";
        runtimeInputs = [pkgs.systemd pkgs.coreutils];
        text = ''
          if [ "$(id -u)" != 0 ]; then
            echo "ethereum-lan-node-reset: run as root (sudo)" >&2
            exit 1
          fi
          if [ "''${1:-}" != "--yes" ]; then
            echo "This DELETES the chain and every game's state under ${cfg.stateDir}."
            read -r -p "Type 'reset' to continue: " answer
            [ "$answer" = reset ] || { echo aborted; exit 1; }
          fi
          units=(${lib.escapeShellArgs cfg.resetUnits})
          systemctl stop "''${units[@]}"
          ${cfg.resetCommands}
          find ${cfg.stateDir} -mindepth 1 -maxdepth 1 -exec rm -rf {} +
          systemd-tmpfiles --create
          systemctl start "''${units[@]}"
          echo "ethereum-lan-node: reset done"
        '';
      })
    ];
  };
}
