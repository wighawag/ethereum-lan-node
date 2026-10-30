# The faucet: faucet-server, paying out of account 0 of the chain's mnemonic.
#
# Players' wallets are generated in their browsers (burner / local signer),
# so they start empty; the games link here (`PUBLIC_FAUCET_LINK="//:34010"`)
# and the faucet funds them. No captcha: there is no internet to reach the
# captcha provider, and the money is a toy chain's.
{
  config,
  lib,
  pkgs,
  ...
}: let
  top = config.services.ethereumLanNode;
  cfg = top.faucet;
  stateDir = "${top.stateDir}/faucet";
in {
  options.services.ethereumLanNode.faucet = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the faucet.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./pkgs/faucet-server {};
      defaultText = lib.literalExpression "the faucet-server package from this flake";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 34010;
    };
    amount = lib.mkOption {
      type = lib.types.str;
      default = "1000000000000000000";
      description = "Wei per claim (default 1 ETH).";
    };
    privateKey = lib.mkOption {
      type = lib.types.str;
      # account 0 of `test test ... junk`, i.e. hardhat/anvil's first account.
      default = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
      description = "The key the faucet pays from. PUBLIC by default (the genesis funds the test mnemonic).";
    };
  };

  config = lib.mkIf (top.enable && cfg.enable) {
    systemd.tmpfiles.rules = ["d ${stateDir} 0750 ethereum-lan-node ethereum-lan-node - -"];

    systemd.services.ethereum-lan-node-faucet = {
      description = "ethereum LAN node: faucet";
      wantedBy = ["multi-user.target"];
      after = ["ethereum-lan-node-chain.service"];
      requires = ["ethereum-lan-node-chain.service"];
      environment = {
        FAUCET_PRIVATE_KEY = cfg.privateKey;
        "CHAIN_${toString top.chain.chainId}" = "${cfg.amount}:${top.chain.rpcUrl}";
        DB = "${stateDir}/faucet.db";
      };
      serviceConfig = {
        User = "ethereum-lan-node";
        Group = "ethereum-lan-node";
        ExecStart = "${lib.getExe cfg.package} --no-captcha --port ${toString cfg.port} --host 0.0.0.0";
        Restart = "always";
        RestartSec = 2;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [stateDir];
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf top.openFirewall [cfg.port];

    services.ethereumLanNode.services.faucet = {
      title = "Faucet";
      port = cfg.port;
      unit = "ethereum-lan-node-faucet.service";
    };
    services.ethereumLanNode.resetUnits = ["ethereum-lan-node-faucet.service"];
  };
}
