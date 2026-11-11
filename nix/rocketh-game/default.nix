# A game from wighawag's template tree (jolly-roger and everything built on it:
# hardhat + rocketh in contracts/, SvelteKit in web/), packaged for this box in
# the shape nix/games.nix expects:
#
#   $out/web/              the SvelteKit static build
#   $out/bin/<deployBin>   puts the contracts on the box's chain, idempotently
#   passthru.lan           how the box should run it (no server: the game is
#                          the chain plus the page)
#
# Used from the game's own flake, as `lib.mkRockethGame pkgs {...}` (see the
# flake, and "A game from the template tree" in README.md). The game's repo
# carries only that call and its own values; everything below lives here, so a
# fix reaches every game with a flake update instead of a template cascade.
#
# Built with NO network, like every Nix build, which is the point: nothing the
# game needs at play time may come from the internet either.
#
# - Solidity: hardhat would download solc; it is given the official WASM build
#   instead (SOLC_PATH, which the repo's contracts/hardhat.config.ts passes as
#   the compiler `path`): the same compiler, so the same bytecode.
# - Addresses: the contracts are deployed at BUILD time into a throwaway chain
#   with the box's chain id (./build/deploy.ts, copied into the repo's
#   contracts/scripts/lan-build/ for the build). Every one goes through the
#   CREATE2 factory the box's genesis predeploys, so the box gets the same
#   addresses; the web app is built with them, and the deploy command replays
#   the recorded transactions on the box (./deploy.sh).
# - URLs: ./env.lan (unless the repo has its own web/.env.lan) names only
#   same-host urls (`//:8545`, the faucet at `//:34010`), so one build works on
#   the hotspot, on a venue network and by name.
#
# WHAT THE REPO MUST STILL CARRY, because nothing outside it can supply it:
# - `path: process.env.SOLC_PATH || undefined` on each solc profile of
#   contracts/hardhat.config.ts (hardhat has no other way to take a compiler
#   it did not download);
# - `withGuardRecording(extensions)` in contracts/rocketh/deploy.ts, with
#   contracts/rocketh/guard-recording.ts, so a guarded `execute` reports its
#   guard to ./build/record.ts (deploy scripts take `execute` from there, so
#   wrapping it here is not enough);
# - deploy scripts that deploy with `deterministic: true` and guard every other
#   transaction: ./build/replayable.ts refuses the build otherwise, and says
#   which transaction.
{
  # The repo, and the revision the web build is named after.
  src,
  rev ? "unknown",
  # THE GAME'S OWN VALUES. Each is read from the `"lan"` field of the repo's
  # root package.json, so a game carries them as plain data and no Nix:
  #
  #   "lan": {
  #     "pnpmDepsHash": "sha256-...",
  #     "preBuild": "pnpm --filter ./circuits exec tsc",
  #     "deployBin": "duel-deploy"
  #   }
  #
  # An argument given here wins over the field (a host may override one).
  #
  # pnpmDepsHash (REQUIRED): fetchPnpmDeps' hash of the packages the repo's
  # pnpm-lock.yaml names. After any lockfile change, set it to
  # sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= and run
  # `nix build git+file://$PWD#lan.pnpmDeps`, which fails with the right value.
  # Do not rely on a build passing: Nix trusts a hash it has already seen, so a
  # stale hash can quietly get another repo's packages.
  pnpmDepsHash ? null,
  # Default: the root package.json's "name"; the package is "<name>-lan".
  name ? null,
  # Defaults: web/src/web-config.json's "title" and "description".
  title ? null,
  description ? null,
  # What the box runs to deploy. Default: "<name>-deploy".
  deployBin ? null,
  # The solc WASM build, which must be the version contracts/hardhat.config.ts
  # compiles with: {"version": "0.8.28+commit.7893614a", "hash": "sha256-..."}
  # (the hash is the sha256 in https://binaries.soliditylang.org/wasm/list.json,
  # as an SRI hash: nix hash convert --to sri sha256:<hex>). Default: 0.8.28.
  solc ? null,
  # Shell, run from the repo root before the contracts are compiled (what they
  # or the web app need built first). Default: nothing.
  preBuild ? null,
  # Shell, run from the repo root after the contracts are deployed and exported
  # (web/src/lib/deployments.ts written, the contracts' dist/ built) and before
  # the web app is built: what needs the addresses, other than the web app (a
  # second export of the same records, workspaces built from them). Default:
  # nothing.
  preWebBuild ? null,
  lib,
  stdenv,
  fetchurl,
  nodejs_24,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  writeShellApplication,
  runCommand,
  foundry,
  jq,
}: let
  pnpm = pnpm_10;
  webConfig = lib.importJSON "${src}/web/src/web-config.json";
  packageJson = lib.importJSON "${src}/package.json";
  # The argument when given, else the package.json "lan" field's, else null.
  fromRepo = packageJson.lan or {};
  value = arg: field:
    if arg != null
    then arg
    else fromRepo.${field} or null;
  hash' =
    if value pnpmDepsHash "pnpmDepsHash" != null
    then value pnpmDepsHash "pnpmDepsHash"
    else
      throw (
        "${packageJson.name}: no pnpmDepsHash. Add \"lan\": {\"pnpmDepsHash\": \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"} "
        + "to package.json and run `nix build git+file://$PWD#lan.pnpmDeps`, which fails with the right value."
      );
  name' = value name "name";
  title' = value title "title";
  description' = value description "description";
  deployBin' = value deployBin "deployBin";
  solc' = value solc "solc";
  preBuild' =
    if value preBuild "preBuild" != null
    then value preBuild "preBuild"
    else "";
  preWebBuild' =
    if value preWebBuild "preWebBuild" != null
    then value preWebBuild "preWebBuild"
    else "";
  pname =
    if name' != null
    then name'
    else packageJson.name;
  deployCommand =
    if deployBin' != null
    then deployBin'
    else "${pname}-deploy";

  # The official WASM build of solc (https://binaries.soliditylang.org/wasm/list.json,
  # whose sha256 the hash is): the same compiler as the native build hardhat
  # would download, with nothing to patch. (The native build wants /lib64's
  # loader, and once patched, hardhat's binary-or-wasm sniffing takes it for
  # text.) The version must be the one in contracts/hardhat.config.ts: a repo
  # that compiles with another one says so with `solc`.
  solcBuild =
    if solc' != null
    then solc'
    else {
      version = "0.8.28+commit.7893614a";
      hash = "sha256-cu9YCm7FlDEwAo5SlDE/JOlDVSCsyJ+Mnb/QE52a4UY=";
    };
  soljson = fetchurl {
    url = "https://binaries.soliditylang.org/wasm/soljson-v${solcBuild.version}.js";
    inherit (solcBuild) hash;
  };

  # The deploy needs `cast` alone: copied out of foundry, it is 90 MB instead
  # of foundry's 370 (forge, anvil, chisel...), which matters when the closure
  # is copied to the box over an event's network.
  cast = runCommand "cast-${foundry.version}" {} ''
    install -Dm755 ${foundry}/bin/cast $out/bin/cast
  '';

  # The box's chain id, from the genesis it runs.
  chainId = (lib.importJSON ../genesis.json).config.chainId;

  deploy = writeShellApplication {
    name = "${deployCommand}-unwrapped";
    runtimeInputs = [cast jq];
    text = builtins.readFile ./deploy.sh;
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "${pname}-lan";
    version = "0.0.0";
    inherit src;

    nativeBuildInputs = [nodejs_24 pnpm pnpmConfigHook];

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 3;
      hash = hash';
    };

    env = {
      LAN_CHAIN_ID = toString chainId;
      SOLC_PATH = "${soljson}";
      HARDHAT_DISABLE_TELEMETRY_PROMPT = "true";
      # package.json pins a pnpm (packageManager), which pnpm would otherwise
      # try to download to run itself as; the one nixpkgs gives is a 10 too.
      npm_config_manage_package_manager_versions = "false";
    };

    preBuild = preBuild';
    preWebBuild = preWebBuild';

    buildPhase = ''
      export HOME=$TMPDIR
      # The same setting for a pnpm that a package.json script runs (`"build":
      # "... && pnpm build:bundle"`): `pnpm run` hands its scripts this
      # variable EMPTY, which reads as the default (true), so the inner pnpm
      # tries to download the pinned version and fails with no network. A user
      # .npmrc reaches every pnpm.
      echo "manage-package-manager-versions=false" >> $HOME/.npmrc
      runHook preBuild

      # The same-host urls, unless the game has its own.
      [ -e web/.env.lan ] || install -m644 ${./env.lan} web/.env.lan

      # The contracts, deployed into a throwaway chain with the box's chain id;
      # the transactions are kept for the deploy command, the records exported
      # to the app with the box's chain described (a chain no public list
      # knows, so the repo's rocketh config need not name it).
      pushd contracts
      cp -r ${./build} scripts/lan-build
      chmod -R u+w scripts/lan-build
      pnpm exec hardhat compile --build-profile production
      LAN_TRANSACTIONS=$TMPDIR/lan.transactions.json \
        pnpm exec hardhat run --build-profile production scripts/lan-build/deploy.ts
      LAN_EXPORT_TS=../web/src/lib/deployments.ts \
        pnpm exec hardhat run scripts/lan-build/export.ts
      # Gone before tsc, which compiles scripts/ into the package's JS.
      rm -r scripts/lan-build
      # The package's JS (dist/), which the web app may import: with/embedded-
      # chain's offline demo runs the deploy scripts in the browser.
      pnpm exec tsc
      popd

      runHook preWebBuild

      pushd web
      # svelte.config.js names the build after `git rev-parse`, falling back to a
      # timestamp that each build process computes differently, and then the
      # prerendered HTML names another build than its JS and never hydrates (as
      # found in conquest-demo's nix/lan.nix). There is no git here: pin it.
      substituteInPlace svelte.config.js \
        --replace-fail 'let VERSION = `timestamp_''${Date.now()}`;' 'let VERSION = "${rev}";'
      # PWA icons: cosmetic on a LAN (no service worker over plain http).
      pnpm generate-pwa-icons || echo "${pname}: pwa icons skipped"
      pnpm exec svelte-kit sync
      pnpm exec vite build --mode lan
      popd
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/share/${pname}
      cp -r web/build $out/web
      cp $TMPDIR/lan.transactions.json $out/share/${pname}/
      cat > $out/bin/${deployCommand} <<EOF
      #!${stdenv.shell}
      export TRANSACTIONS=$out/share/${pname}/lan.transactions.json
      export NAME=${deployCommand}
      exec ${deploy}/bin/${deployCommand}-unwrapped "\$@"
      EOF
      chmod +x $out/bin/${deployCommand}
      runHook postInstall
    '';

    passthru.lan = {
      title =
        if title' != null
        then title'
        else webConfig.title;
      description =
        if description' != null
        then description'
        else webConfig.description;
      # SvelteKit's SPA shell for routes that were not prerendered.
      fallback = "/404.html";
      deploy.bin = deployCommand;
    };

    meta = {
      # The repo's own, from package.json, when it declares one.
      license = lib.optionals (packageJson ? license) [(lib.getLicenseFromSpdxId packageJson.license)];
      platforms = ["x86_64-linux"];
    };
  })
