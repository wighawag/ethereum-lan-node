# faucet-server (npm, wighawag/faucet-server) as a store path.
#
# The npm tarball ships no lockfile, so this directory carries a one-line
# package.json depending on the exact version plus the lockfile npm resolved
# for it. Bumping the faucet: change the version in package.json, run
# `npm install --package-lock-only --ignore-scripts` here, and update
# npmDepsHash (the build prints the right one).
{
  buildNpmPackage,
  nodejs_22,
  makeWrapper,
  lib,
}:
buildNpmPackage {
  pname = "faucet-server";
  version = "0.2.0";
  src = ./.;
  nodejs = nodejs_22;
  npmDepsHash = "sha256-d7nWo4bQ9C+4P+f3GyyRft1jaf/5xsWU3qw8ip7bX9I=";
  dontNpmBuild = true;
  npmFlags = ["--ignore-scripts"];
  nativeBuildInputs = [makeWrapper];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/bin
    cp -r node_modules $out/lib/node_modules
    makeWrapper ${lib.getExe nodejs_22} $out/bin/faucet \
      --add-flags $out/lib/node_modules/faucet-server/dist/cli.js
    runHook postInstall
  '';
  meta.mainProgram = "faucet";
}
