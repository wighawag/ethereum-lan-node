# The explorer: blockscout, with contract verification, offline.
#
# Blockscout is not in nixpkgs, so its three parts run as oci-containers
# (podman) with images PINNED BY DIGEST and carried in the system closure via
# `imageFile`: nothing is pulled at boot (`pull = "never"`), a box at a venue
# with no internet starts the same as one at home. Postgres is the native
# nixpkgs one. Stats, visualizer, sig-provider, user-ops-indexer and redis are
# dropped: they are optional, and every one of them was another thing to keep
# alive.
#
# THE HOST PROBLEM, and the one trick here. The frontend is a Next.js app that
# calls the API at `NEXT_PUBLIC_API_HOST`, ONE hostname fixed at start. This
# box has no fixed hostname: it is 10.42.0.1 on its hotspot, some DHCP address
# on a venue network, ethereum.local, ethereum.lan. So Caddy fronts port 4000
# and serves the browser's copy of the frontend's runtime config
# (`/assets/envs.js`, which the page loads and `getEnvValue` reads from
# `window.__envs`) as a TEMPLATE filled with the Host the visitor used. The
# server side keeps 127.0.0.1. Every address the box answers on then gets an
# explorer that talks back to that same address.
#
# Verification offline: the verifier downloads solc on demand from
# binaries.soliditylang.org. Here it is given a compilers directory preloaded
# with the versions in `solc` (copied in, because it refuses symlinks), and a
# list.json served from this box carrying exactly those versions and their
# sha256, which it validates them against.
{
  config,
  lib,
  pkgs,
  ...
}: let
  top = config.services.ethereumLanNode;
  cfg = top.explorer;
  stateDir = "${top.stateDir}/explorer";
  chainId = toString top.chain.chainId;

  backendPort = 4001;
  frontendPort = 4002;
  verifierPort = 4003;
  solcListPort = 4004;

  images = {
    backend = {
      imageName = "ghcr.io/blockscout/blockscout";
      imageDigest = "sha256:7659f168e4e2f6b73dd559ae5278fe96ba67bc2905ea01b57a814c68adf5a9dc";
      finalImageTag = "9.0.2";
      hash = "sha256-or7XVq6eKzXEaQAH/fsCqq4u36WdM9bUTd2OMUjx0Oc=";
    };
    frontend = {
      imageName = "ghcr.io/blockscout/frontend";
      imageDigest = "sha256:4b69f44148414b55c6b8550bc3270c63c9f99e923d54ef0b307e762af6bac90a";
      finalImageTag = "v2.3.5";
      hash = "sha256-Zf7nZTOaoaHUsQnB1V1bfBap3mBiqiBWKD1Cgda5g08=";
    };
    verifier = {
      imageName = "ghcr.io/blockscout/smart-contract-verifier";
      imageDigest = "sha256:2b2fc0f344d031a7571501adb744ed9d3978a94d25ca5a220f6e06b240f93579";
      # v1.10.0, the release of the same era as backend 9.0.2. (v1.11 refuses
      # to start unless told to run compilers in docker or "native".)
      finalImageTag = "v1.10.0";
      hash = "sha256-sMtQ5gkRgD41oYP2wx6NKPFtS2VzC1e5ZhdHjcibrek=";
    };
  };
  pull = i:
    pkgs.dockerTools.pullImage {
      inherit (i) imageName imageDigest finalImageTag hash;
      os = "linux";
      arch = "amd64";
    };
  ref = i: "${i.imageName}:${i.finalImageTag}";

  # The solc builds the verifier may use, as soliditylang's list.json writes
  # them. Add an entry to support another version (the sha256 comes from
  # https://binaries.soliditylang.org/linux-amd64/list.json).
  solcList = {
    builds = cfg.solc;
    releases = lib.listToAttrs (map (b: lib.nameValuePair b.version b.path) cfg.solc);
    latestRelease = (lib.last cfg.solc).version;
  };
  solcListDir = pkgs.writeTextDir "list.json" (builtins.toJSON solcList);
  compilers = pkgs.linkFarm "eln-solc" (map (b: {
      name = "v${b.longVersion}/solc";
      path = pkgs.fetchurl {
        url = "https://binaries.soliditylang.org/linux-amd64/${b.path}";
        # The flat hash IS the list's sha256, so the pin and the verifier's
        # own check are the same number. (No `executable`: that switches
        # fetchurl to a NAR hash; the copy in preStart sets the mode.)
        sha256 = lib.removePrefix "0x" b.sha256;
      };
    })
    cfg.solc);

  frontendEnv = host: {
    NEXT_PUBLIC_API_HOST = host;
    NEXT_PUBLIC_API_PORT = toString cfg.port;
    NEXT_PUBLIC_API_PROTOCOL = "http";
    NEXT_PUBLIC_API_WEBSOCKET_PROTOCOL = "ws";
    NEXT_PUBLIC_API_BASE_PATH = "/";
    NEXT_PUBLIC_APP_HOST = host;
    NEXT_PUBLIC_APP_PORT = toString cfg.port;
    NEXT_PUBLIC_APP_PROTOCOL = "http";
    NEXT_PUBLIC_NETWORK_NAME = top.name;
    NEXT_PUBLIC_NETWORK_SHORT_NAME = top.name;
    NEXT_PUBLIC_NETWORK_ID = chainId;
    NEXT_PUBLIC_NETWORK_RPC_URL = "http://${host}:${toString top.chain.httpPort}";
    NEXT_PUBLIC_NETWORK_CURRENCY_NAME = "Ether";
    NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL = "ETH";
    NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS = "18";
    NEXT_PUBLIC_IS_TESTNET = "true";
    NEXT_PUBLIC_HOMEPAGE_CHARTS = "[]";
    NEXT_PUBLIC_AD_BANNER_PROVIDER = "none";
    NEXT_PUBLIC_AD_TEXT_PROVIDER = "none";
  };

  # The browser's runtime config, one per request: `{{.Host}}` is the host the
  # visitor typed (no port). Same shape as the frontend's own
  # make_envs_script.sh output.
  envsJs = pkgs.writeTextDir "assets/envs.js" ''
    window.__envs = {
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}: \"${v}\",") (frontendEnv "{{.Host}}"))}
    }
  '';
in {
  options.services.ethereumLanNode.explorer = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run blockscout.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
    };
    solc = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      description = "solc builds preloaded for offline verification, as entries of soliditylang's linux-amd64 list.json.";
      default = [
        {
          path = "solc-linux-amd64-v0.8.24+commit.e11b9ed9";
          version = "0.8.24";
          build = "commit.e11b9ed9";
          longVersion = "0.8.24+commit.e11b9ed9";
          keccak256 = "0x5a127e73ef8c90f2df60ff2fe9dd79709da9e90d2d075cf05784c9a3efee2528";
          sha256 = "0xfb03a29a517452b9f12bcf459ef37d0a543765bb3bbc911e70a87d6a37c30d5f";
        }
        {
          path = "solc-linux-amd64-v0.8.28+commit.7893614a";
          version = "0.8.28";
          build = "commit.7893614a";
          longVersion = "0.8.28+commit.7893614a";
          keccak256 = "0x0d387f5ca7d0f298e79243cec5af7ab42eeb0a414e42f15c66f855d701479c43";
          sha256 = "0x9a0fb7e0db2c0641dbae1c5cc645dc686820c83af516226abb1c0a2f76636f25";
        }
      ];
    };
  };

  config = lib.mkIf (top.enable && cfg.enable) {
    services.postgresql = {
      enable = true;
      ensureDatabases = ["blockscout"];
      ensureUsers = [
        {
          name = "blockscout";
          ensureDBOwnership = true;
        }
      ];
      # Loopback only, and only this role and database. The containers share
      # the host network, so the backend reaches postgres on 127.0.0.1. Trust
      # rather than a password: the data is a public toy chain's, and anything
      # that can open a loopback socket on this box already runs as one of its
      # services.
      authentication = lib.mkBefore ''
        host blockscout blockscout 127.0.0.1/32 trust
      '';
    };

    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers = {
      blockscout-backend = {
        image = ref images.backend;
        imageFile = pull images.backend;
        pull = "never";
        extraOptions = ["--network=host"];
        cmd = ["sh" "-c" "bin/blockscout eval \"Elixir.Explorer.ReleaseTasks.create_and_migrate()\" && bin/blockscout start"];
        environmentFiles = ["${stateDir}/backend.env"];
        environment = {
          PORT = toString backendPort;
          CHAIN_ID = chainId;
          NETWORK = top.name;
          SUBNETWORK = top.name;
          COIN = "ETH";
          COIN_NAME = "Ether";
          ETHEREUM_JSONRPC_VARIANT = "geth";
          ETHEREUM_JSONRPC_TRANSPORT = "http";
          ETHEREUM_JSONRPC_HTTP_URL = "${top.chain.rpcUrl}/";
          ETHEREUM_JSONRPC_TRACE_URL = "${top.chain.rpcUrl}/";
          ETHEREUM_JSONRPC_WS_URL = "ws://127.0.0.1:${toString top.chain.wsPort}";
          ETHEREUM_JSONRPC_DISABLE_ARCHIVE_BALANCES = "false";
          # A password the server ignores (trust on loopback): blockscout's URL
          # parser fails on a URL without one.
          DATABASE_URL = "postgresql://blockscout:blockscout@127.0.0.1:5432/blockscout";
          ECTO_USE_SSL = "false";
          POOL_SIZE = "20";
          POOL_SIZE_API = "10";
          DISABLE_MARKET = "true";
          DISABLE_EXCHANGE_RATES = "true";
          DISABLE_FILE_LOGGING = "true";
          RE_CAPTCHA_DISABLED = "true";
          ACCOUNT_ENABLED = "false";
          ADMIN_PANEL_ENABLED = "false";
          NFT_MEDIA_HANDLER_ENABLED = "false";
          MICROSERVICE_SC_VERIFIER_ENABLED = "true";
          MICROSERVICE_SC_VERIFIER_TYPE = "sc_verifier";
          MICROSERVICE_SC_VERIFIER_URL = "http://127.0.0.1:${toString verifierPort}/";
          MICROSERVICE_VISUALIZE_SOL2UML_ENABLED = "false";
          MICROSERVICE_SIG_PROVIDER_ENABLED = "false";
          DECODE_NOT_A_CONTRACT_CALLS = "true";
          HEART_BEAT_TIMEOUT = "30";
          TXS_STATS_DAYS_TO_COMPILE_AT_INIT = "1";
        };
        volumes = ["${stateDir}/dets:/app/dets"];
      };

      blockscout-frontend = {
        image = ref images.frontend;
        imageFile = pull images.frontend;
        pull = "never";
        extraOptions = ["--network=host"];
        environment =
          frontendEnv "127.0.0.1"
          // {
            PORT = toString frontendPort;
            HOSTNAME = "127.0.0.1";
          };
      };

      blockscout-verifier = {
        image = ref images.verifier;
        imageFile = pull images.verifier;
        pull = "never";
        extraOptions = ["--network=host"];
        environment = {
          SMART_CONTRACT_VERIFIER__SERVER__HTTP__ENABLED = "true";
          SMART_CONTRACT_VERIFIER__SERVER__HTTP__ADDR = "127.0.0.1:${toString verifierPort}";
          SMART_CONTRACT_VERIFIER__SERVER__HTTP__MAX_BODY_SIZE = "2097152";
          SMART_CONTRACT_VERIFIER__SERVER__GRPC__ENABLED = "false";
          SMART_CONTRACT_VERIFIER__SOLIDITY__ENABLED = "true";
          SMART_CONTRACT_VERIFIER__SOLIDITY__COMPILERS_DIR = "/compilers";
          SMART_CONTRACT_VERIFIER__SOLIDITY__FETCHER__LIST__LIST_URL = "http://127.0.0.1:${toString solcListPort}/list.json";
          SMART_CONTRACT_VERIFIER__VYPER__ENABLED = "false";
          SMART_CONTRACT_VERIFIER__SOURCIFY__ENABLED = "false";
          # On by default, and it fetches its compiler list from the internet at
          # START, so the verifier would not boot offline.
          SMART_CONTRACT_VERIFIER__ZKSYNC_SOLIDITY__ENABLED = "false";
          SMART_CONTRACT_VERIFIER__METRICS__ENABLED = "false";
          SMART_CONTRACT_VERIFIER__JAEGER__ENABLED = "false";
        };
        volumes = ["${stateDir}/compilers:/compilers"];
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root root - -"
      "d ${stateDir}/dets 0750 root root - -"
    ];

    # Secrets nobody needs to know, minted on first start and kept with the
    # rest of the explorer's state (so a reset mints new ones).
    systemd.services.podman-blockscout-backend = {
      after = ["postgresql.service" "ethereum-lan-node-chain.service"];
      requires = ["postgresql.service" "ethereum-lan-node-chain.service"];
      preStart = lib.mkBefore ''
        mkdir -p ${stateDir}/dets
        if [ ! -s ${stateDir}/backend.env ]; then
          umask 077
          {
            echo "SECRET_KEY_BASE=$(${pkgs.openssl}/bin/openssl rand -hex 64)"
            echo "RELEASE_COOKIE=$(${pkgs.openssl}/bin/openssl rand -hex 32)"
          } > ${stateDir}/backend.env
        fi
      '';
    };
    systemd.services.podman-blockscout-frontend = {
      after = ["podman-blockscout-backend.service"];
    };
    systemd.services.podman-blockscout-verifier = {
      after = ["caddy.service"];
      # Real files in real directories: the verifier ignores symlinks.
      preStart = lib.mkBefore ''
        rm -rf ${stateDir}/compilers
        mkdir -p ${stateDir}/compilers
        cp -rL --no-preserve=mode ${compilers}/. ${stateDir}/compilers/
        chmod -R u+rwX,go+rX ${stateDir}/compilers
        find ${stateDir}/compilers -name solc -exec chmod 0755 {} +
      '';
    };

    services.caddy = {
      enable = true;
      globalConfig = ''
        auto_https off
      '';
      extraConfig = ''
        :${toString cfg.port} {
          handle /assets/envs.js {
            root * ${envsJs}
            header Cache-Control no-store
            templates {
              mime text/javascript application/javascript
            }
            file_server
          }
          @api path /api /api/* /socket /socket/* /sitemap.xml
          handle @api {
            reverse_proxy 127.0.0.1:${toString backendPort}
          }
          handle {
            reverse_proxy 127.0.0.1:${toString frontendPort}
          }
        }

        http://127.0.0.1:${toString solcListPort} {
          root * ${solcListDir}
          file_server
        }
      '';
    };

    networking.firewall.allowedTCPPorts = lib.mkIf top.openFirewall [cfg.port];

    services.ethereumLanNode.services.explorer = {
      title = "Explorer (blockscout)";
      port = cfg.port;
      unit = "podman-blockscout-backend.service";
    };
    services.ethereumLanNode.resetUnits = [
      "podman-blockscout-frontend.service"
      "podman-blockscout-backend.service"
      "podman-blockscout-verifier.service"
    ];
    services.ethereumLanNode.resetCommands = ''
      ${config.systemd.package}/bin/systemctl start postgresql.service
      ${pkgs.util-linux}/bin/runuser -u postgres -- ${config.services.postgresql.package}/bin/dropdb --if-exists --force blockscout
      ${pkgs.util-linux}/bin/runuser -u postgres -- ${config.services.postgresql.package}/bin/createdb -O blockscout blockscout
    '';
  };
}
