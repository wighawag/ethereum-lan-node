{
  description = "An ethereum LAN node: a dev chain, an explorer, a faucet, a Wi-Fi hotspot and browser games, on one NixOS box that works with no internet";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;
  in {
    # The whole box as one module. Everything is under
    # `services.ethereumLanNode` and off until `enable = true`.
    nixosModules.default = import ./nix/module.nix;
    nixosModules.ethereumLanNode = self.nixosModules.default;

    packages.${system} = {
      faucet-server = pkgs.callPackage ./nix/pkgs/faucet-server {};
      # A stand-in game: a static page plus a tiny HTTP server, in the exact
      # shape a real game's `lan` package has. Used by the VM test and handy
      # for checking a fresh box before any real game is added.
      example-game = pkgs.callPackage ./nix/pkgs/example-game {};
      genesis = pkgs.writeText "genesis.json" (builtins.readFile ./nix/genesis.json);
    };

    # A complete host anyone can birth (see examples/host.nix): this module,
    # a disk layout and the example game. Not a deployment of anybody's box.
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        ./examples/host.nix
        {
          services.ethereumLanNode.games.example = {
            package = self.packages.${system}.example-game;
            webPort = 8001;
          };
        }
      ];
    };

    checks.${system} = {
      vm = import ./nix/tests/vm.nix {
        inherit pkgs lib;
        module = self.nixosModules.default;
        exampleGame = self.packages.${system}.example-game;
      };
    };

    formatter.${system} = pkgs.alejandra;
  };
}
