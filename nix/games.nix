# The games, the landing page, and the status feed the landing page reads.
#
# A GAME IS A PACKAGE WITH A KNOWN SHAPE, built by the game's own repo (this
# flake never learns how a game is built):
#
#   $pkg/web/            the static site, built with same-host URLs
#                        (`PUBLIC_NODE_URL="//:8545"` and friends), so one
#                        build works on every address the box answers on
#   $pkg/bin/<server>    optional: a long-running service (e.g. a room server)
#   $pkg/bin/<deploy>    optional: deploys the game's contracts, idempotently
#
# and describes itself in `passthru.lan`:
#
#   passthru.lan = {
#     title = "Conquest";            description = "...";
#     fallback = "/404.html";        # SPA shell, default /index.html
#     server = { bin = "conquest-demo-server"; port = 30042; args = [...]; };
#     deploy = { bin = "bomber-world-deploy"; };
#   };
#
# The host only picks the games and their web ports:
#
#   services.ethereumLanNode.games.conquest = {
#     package = inputs.conquest-demo.packages.${system}.lan;
#     webPort = 8001;
#   };
#
# ONE PORT PER GAME, never a hostname: a port works the same on the hotspot,
# on a venue's network, by IP and by mDNS name, with no DNS to set up, and a
# SvelteKit static build served at `/` needs no base path. Services the page
# calls are found the same way (same host, their own port), which is what the
# games' `//:<port>` URLs already do.
#
# Each game's server and deploy get, in their environment:
#   ETH_NODE_URI   the chain RPC (local)       CHAIN_ID   the chain id
#   MNEMONIC       the funded test mnemonic    STATE_DIRECTORY  their own dir
# and their state lives under stateDir/games/<name>, so a reset wipes it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  top = config.services.ethereumLanNode;
  games = top.games;
  runDir = "/run/ethereum-lan-node";

  gameModule = {
    name,
    config,
    ...
  }: let
    lan = config.package.passthru.lan or {};
  in {
    options = {
      package = lib.mkOption {
        type = lib.types.package;
        description = "The game's `lan` package (see the header of games.nix).";
      };
      title = lib.mkOption {
        type = lib.types.str;
        default = lan.title or name;
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = lan.description or "";
      };
      webPort = lib.mkOption {
        type = lib.types.port;
        description = "The port its static site is served on.";
      };
      fallback = lib.mkOption {
        type = lib.types.str;
        default = lan.fallback or "/index.html";
        description = "The page served for a path that is not a file (an SPA shell; SvelteKit's static adapter calls it 404.html or 200.html).";
      };
      server = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = lan ? server;
        };
        bin = lib.mkOption {
          type = lib.types.str;
          default = lan.server.bin or "";
        };
        port = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = lan.server.port or null;
          description = "The port it listens on (opened in the firewall).";
        };
        args = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = lan.server.args or [];
          description = "Arguments. `$STATE_DIRECTORY` is expanded by the shell.";
        };
      };
      deploy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = lan ? deploy;
        };
        bin = lib.mkOption {
          type = lib.types.str;
          default = lan.deploy.bin or "";
        };
      };
    };
  };

  gameEnv = name: {
    ETH_NODE_URI = top.chain.rpcUrl;
    CHAIN_ID = toString top.chain.chainId;
    MNEMONIC = top.chain.mnemonic;
    STATE_DIRECTORY = "${top.stateDir}/games/${name}";
  };

  sandbox = name: {
    User = "ethereum-lan-node";
    Group = "ethereum-lan-node";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ReadWritePaths = ["${top.stateDir}/games/${name}"];
    ProtectHome = true;
    PrivateTmp = true;
  };

  # What the landing page knows at build time. Links are made relative to the
  # host the visitor used, in the browser, so this holds ports and no hosts.
  landingConfig = {
    name = top.name;
    chainId = top.chain.chainId;
    rpcPort = top.chain.httpPort;
    hotspot =
      if top.network.ap.enable
      then {
        inherit (top.network.ap) ssid address;
      }
      else null;
    games =
      lib.mapAttrsToList (n: g: {
        id = n;
        inherit (g) title description webPort;
      })
      games;
    services =
      lib.mapAttrsToList (n: s: {
        id = n;
        inherit (s) title port path link unit;
      })
      top.services;
  };
  landing = pkgs.runCommand "ethereum-lan-node-landing" {} ''
    mkdir -p $out
    cp ${./landing/index.html} $out/index.html
    cp ${./landing/landing.js} $out/landing.js
    cp ${./landing/style.css} $out/style.css
    cp ${pkgs.writeText "config.json" (builtins.toJSON landingConfig)} $out/config.json
  '';

  # Every 10 s: addresses, unit states, head block, and a QR code per address
  # (served at /status.json and /qr/). qrencode, not a JS library: nothing
  # here may come from a CDN.
  statusScript = pkgs.writeShellApplication {
    name = "ethereum-lan-node-status";
    runtimeInputs = with pkgs; [iproute2 jq curl qrencode systemd coreutils];
    text = ''
      set +e
      out=${runDir}
      mkdir -p "$out/qr.new"
      addrs=$(ip -j -4 addr show scope global | jq -c '[.[] | select(.ifname != "tailscale0") | {ifname, addr: .addr_info[0].local}]')
      for a in $(echo "$addrs" | jq -r '.[].addr'); do
        qrencode -t SVG -m 1 -o "$out/qr.new/$a.svg" "http://$a/"
      done
      ${lib.optionalString top.network.ap.enable ''
        pass=${
          if top.network.ap.passphraseFile != null
          then ''"$(cat ${top.network.ap.passphraseFile})"''
          else lib.escapeShellArg top.network.ap.passphrase
        }
        esc() { printf '%s' "$1" | sed 's/[\\;,:"]/\\&/g'; }
        qrencode -t SVG -m 1 -o "$out/qr.new/wifi.svg" "WIFI:T:WPA;S:$(esc ${lib.escapeShellArg top.network.ap.ssid});P:$(esc "$pass");;"
      ''}
      rm -rf "$out/qr" && mv "$out/qr.new" "$out/qr"
      units='{}'
      ${lib.concatMapStrings (s: ''
          units=$(echo "$units" | jq -c --arg k ${lib.escapeShellArg s} --arg v "$(systemctl is-active ${lib.escapeShellArg s})" '. + {($k): $v}')
        '')
        (lib.unique ((lib.mapAttrsToList (_: s: s.unit) top.services)
          ++ lib.concatLists (lib.mapAttrsToList (n: g:
            lib.optional g.server.enable "ethereum-lan-node-game-${n}.service"
            ++ lib.optional g.deploy.enable "ethereum-lan-node-deploy-${n}.service")
          games)))}
      block=$(curl -sf -m 2 -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' ${top.chain.rpcUrl} | jq -r '.result // empty')
      blocknum=null
      if [ -n "$block" ]; then blocknum=$((16#''${block#0x})); fi
      jq -n --argjson addresses "$addrs" --argjson units "$units" --argjson block "$blocknum" \
        '{addresses: $addresses, units: $units, block: $block, time: now}' \
        > "$out/status.json.new" && mv "$out/status.json.new" "$out/status.json"
    '';
  };
in {
  options.services.ethereumLanNode = {
    games = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule gameModule);
      default = {};
      description = "The games this box hosts.";
    };
    landing = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Serve the landing page (games, services, addresses, QR codes).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 80;
      };
    };
  };

  config = lib.mkIf top.enable (lib.mkMerge [
    {
      assertions = let
        ports = lib.mapAttrsToList (n: g: g.webPort) games;
      in [
        {
          assertion = lib.length ports == lib.length (lib.unique ports);
          message = "services.ethereumLanNode.games: two games share a webPort.";
        }
      ];

      systemd.tmpfiles.rules =
        ["d ${top.stateDir}/games 0755 ethereum-lan-node ethereum-lan-node - -"]
        ++ lib.mapAttrsToList (n: _: "d ${top.stateDir}/games/${n} 0750 ethereum-lan-node ethereum-lan-node - -") games;

      services.caddy = {
        enable = true;
        globalConfig = ''
          auto_https off
        '';
        extraConfig = lib.concatStrings (lib.mapAttrsToList (n: g: ''
            :${toString g.webPort} {
              root * ${g.package}/web
              try_files {path} {path}/index.html {path}.html ${g.fallback}
              file_server
            }
          '')
          games);
      };

      networking.firewall.allowedTCPPorts = lib.mkIf top.openFirewall (
        lib.mapAttrsToList (_: g: g.webPort) games
        ++ lib.concatLists (lib.mapAttrsToList (_: g: lib.optional (g.server.enable && g.server.port != null) g.server.port) games)
      );

      systemd.services = lib.concatMapAttrs (n: g:
        lib.optionalAttrs g.deploy.enable {
          "ethereum-lan-node-deploy-${n}" = {
            description = "ethereum LAN node: deploy ${g.title}'s contracts";
            wantedBy = ["multi-user.target"];
            after = ["ethereum-lan-node-chain.service"];
            requires = ["ethereum-lan-node-chain.service"];
            environment = gameEnv n;
            serviceConfig =
              sandbox n
              // {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${g.package}/bin/${g.deploy.bin}";
              };
          };
        }
        // lib.optionalAttrs g.server.enable {
          "ethereum-lan-node-game-${n}" = {
            description = "ethereum LAN node: ${g.title} server";
            wantedBy = ["multi-user.target"];
            after = ["network.target"] ++ lib.optional g.deploy.enable "ethereum-lan-node-deploy-${n}.service";
            requires = lib.optional g.deploy.enable "ethereum-lan-node-deploy-${n}.service";
            environment = gameEnv n;
            script = "exec ${g.package}/bin/${g.server.bin} ${lib.concatStringsSep " " g.server.args}";
            serviceConfig =
              sandbox n
              // {
                Restart = "always";
                RestartSec = 2;
              };
          };
        })
      games;

      services.ethereumLanNode.resetUnits = lib.concatLists (lib.mapAttrsToList (n: g:
        lib.optional g.deploy.enable "ethereum-lan-node-deploy-${n}.service"
        ++ lib.optional g.server.enable "ethereum-lan-node-game-${n}.service")
      games);
    }

    (lib.mkIf top.landing.enable {
      services.caddy.extraConfig = ''
        :${toString top.landing.port} {
          handle /status.json {
            root * ${runDir}
            header Cache-Control no-store
            file_server
          }
          handle /qr/* {
            root * ${runDir}
            header Cache-Control no-store
            file_server
          }
          handle {
            root * ${landing}
            file_server
          }
        }
      '';
      networking.firewall.allowedTCPPorts = lib.mkIf top.openFirewall [top.landing.port];

      systemd.tmpfiles.rules = ["d ${runDir} 0755 root root - -"];
      systemd.services.ethereum-lan-node-status = {
        description = "ethereum LAN node: refresh the landing page's status";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe statusScript;
        };
      };
      systemd.timers.ethereum-lan-node-status = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "5s";
          OnUnitActiveSec = "10s";
          AccuracySec = "1s";
        };
      };
    })
  ]);
}
