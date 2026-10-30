# The chain: geth in dev mode, from a FIXED genesis.
#
# Dev mode because a LAN chain has one node and no consensus to speak of:
# geth's simulated beacon seals a block every `blockTime` seconds. The genesis
# is fixed (./genesis.json) so the chain id, the prefunded accounts and the
# predeployed CREATE2 factory are the same on every box and after every reset,
# which is what lets a game's web build carry its contract addresses.
#
# The genesis is geth 1.17's own dev genesis (all fork system contracts and
# the blob schedule geth now insists on) with three changes: chain id
# 19216801, the 20 accounts of the `test test ... junk` mnemonic at 10000 ETH
# each instead of a random dev account, and the deterministic-deployment proxy
# (0x4e59b44847b379578588920ca78fbf26c0b4956c, the code anvil and hardhat
# predeploy) so CREATE2 deployments land at the same address everywhere.
#
# WHY INIT FAILURE IS FATAL HERE: with an unusable genesis `geth init` fails,
# and `geth --dev` then starts happily on its DEFAULT dev chain (id 1337, a
# random account). The old genesis did exactly that on geth 1.17
# (`missing entry for fork "cancun" in blobSchedule`). A chain with the wrong
# id is worse than no chain, so ExecStartPre refuses instead.
{
  config,
  lib,
  pkgs,
  ...
}: let
  top = config.services.ethereumLanNode;
  cfg = top.chain;
  dataDir = "${top.stateDir}/chain";
  apis = "eth,net,web3,debug,txpool";
  rpc = "http://127.0.0.1:${toString cfg.httpPort}";
in {
  options.services.ethereumLanNode.chain = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the dev chain.";
    };
    package = lib.mkPackageOption pkgs "go-ethereum" {};
    genesis = lib.mkOption {
      type = lib.types.path;
      default = ./genesis.json;
      description = "The genesis file. Its chain id is read from it.";
    };
    chainId = lib.mkOption {
      type = lib.types.int;
      readOnly = true;
      default = (lib.importJSON cfg.genesis).config.chainId;
      description = "The chain id, read from the genesis.";
    };
    blockTime = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Seconds between blocks.";
    };
    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8545;
    };
    wsPort = lib.mkOption {
      type = lib.types.port;
      default = 8546;
    };
    rpcUrl = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = rpc;
      description = "The chain's RPC as seen from this box (what local services use).";
    };
    mnemonic = lib.mkOption {
      type = lib.types.str;
      default = "test test test test test test test test test test test junk";
      description = "The mnemonic whose accounts the genesis funds. PUBLIC by design: this is a toy chain.";
    };
  };

  config = lib.mkIf (top.enable && cfg.enable) {
    users.users.ethereum-lan-node = {
      isSystemUser = true;
      group = "ethereum-lan-node";
    };
    users.groups.ethereum-lan-node = {};

    systemd.tmpfiles.rules = ["d ${dataDir} 0750 ethereum-lan-node ethereum-lan-node - -"];

    systemd.services.ethereum-lan-node-chain = {
      description = "ethereum LAN node: geth dev chain ${toString cfg.chainId}";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      path = [cfg.package pkgs.curl pkgs.coreutils];
      serviceConfig = {
        User = "ethereum-lan-node";
        Group = "ethereum-lan-node";
        Restart = "always";
        RestartSec = 2;
        # Initialise once; a datadir that already holds a chain is kept.
        ExecStartPre = pkgs.writeShellScript "eln-chain-init" ''
          set -eu
          if [ ! -d ${dataDir}/geth/chaindata ]; then
            geth --datadir ${dataDir} --state.scheme hash init ${cfg.genesis}
          fi
        '';
        ExecStart = lib.concatStringsSep " " [
          "${lib.getExe' cfg.package "geth"}"
          "--dev --dev.period ${toString cfg.blockTime}"
          "--datadir ${dataDir}"
          # Archive: blockscout reads historical balances and traces old blocks.
          "--state.scheme hash --gcmode archive --syncmode full"
          "--http --http.addr 0.0.0.0 --http.port ${toString cfg.httpPort}"
          "--http.vhosts '*' --http.corsdomain '*' --http.api ${apis}"
          "--ws --ws.addr 0.0.0.0 --ws.port ${toString cfg.wsPort} --ws.origins '*' --ws.api ${apis}"
          "--rpc.allow-unprotected-txs"
          "--authrpc.addr 127.0.0.1"
          "--nodiscover --maxpeers 0"
        ];
        # "Started" means "answering": everything ordered after this unit can
        # call the RPC immediately.
        ExecStartPost = pkgs.writeShellScript "eln-chain-ready" ''
          for _ in $(seq 1 120); do
            if curl -sf -m 2 -H 'content-type: application/json' \
              -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' ${rpc} \
              | grep -q '"result":"0x${lib.toLower (lib.toHexString cfg.chainId)}"'; then
              exit 0
            fi
            sleep 0.5
          done
          echo "chain did not answer with chain id ${toString cfg.chainId}" >&2
          exit 1
        '';
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [dataDir];
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf top.openFirewall [cfg.httpPort cfg.wsPort];

    services.ethereumLanNode.services.chain = {
      title = "Chain RPC (chain id ${toString cfg.chainId})";
      port = cfg.httpPort;
      unit = "ethereum-lan-node-chain.service";
      link = false;
    };
    services.ethereumLanNode.resetUnits = ["ethereum-lan-node-chain.service"];
  };
}
