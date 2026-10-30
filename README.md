# ethereum LAN node

A NixOS module that turns one small x86 box into a self-contained games-and-chain server you can carry to an event: a dev chain, an explorer with contract verification, a faucet, its own Wi-Fi hotspot, and browser games, all of it working with no internet and starting on boot with no manual step.

The previous Ubuntu + docker compose version is in [`legacy/`](legacy/README.md).

## What runs

| port | what |
| --- | --- |
| 80 | landing page: the games, the services and their state, QR codes to join the Wi-Fi and to open the page |
| 8545 / 8546 | geth in dev mode (HTTP / WS), chain id 19216801, a block every 2 s |
| 4000 | blockscout explorer, with verification for the preloaded solc versions |
| 34010 | faucet (1 ETH a claim, no captcha) |
| one per game | each game's static site, plus any port its own server uses |

The genesis ([`nix/genesis.json`](nix/genesis.json)) funds the 20 accounts of the `test test test test test test test test test test test junk` mnemonic with 10000 ETH each and predeploys the deterministic-deployment proxy at `0x4e59b44847b379578588920ca78fbf26c0b4956c`, so CREATE2 deployments land at the same address on every box and after every reset. Every key involved is public: this is a toy chain.

The hotspot is SSID `master node`, passphrase `I am vitalik`, at `10.42.0.1`. The box also joins Ethernet and known Wi-Fi networks (NetworkManager), keeps the hotspot up beside them, and shares the internet with hotspot clients when there is some, but never the uplink's private networks.

## Use it

```nix
{
  inputs.ethereum-lan-node.url = "github:wighawag/ethereum-lan-node";
  outputs = {nixpkgs, ethereum-lan-node, ...}: {
    nixosConfigurations.my-box = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ethereum-lan-node.nixosModules.default
        ./host.nix # start from examples/host.nix
        {
          services.ethereumLanNode = {
            enable = true;
            network.ap = {
              enable = true;
              interface = "wlan0"; # the radio that becomes the hotspot
            };
          };
        }
      ];
    };
  };
}
```

`examples/host.nix` is a complete minimal host; `nix build .#nixosConfigurations.example.config.system.build.toplevel` builds it.

Two radios are best (one for the hotspot, one to join networks); a USB dongle with a mt76 chipset is a good hotspot radio. Without a country code there is no 5 GHz hotspot (`network.ap.countryCode`, default `GB`).

## Add a game

A game is a package its own repo builds, with this shape:

```
$out/web/              static site, built with same-host URLs ("//:8545", "//:34010")
$out/bin/<server>      optional long-running service
$out/bin/<deploy>      optional, deploys its contracts (idempotently)
passthru.lan = { title; description; server = { bin; port; args; }; deploy.bin; };
```

and the host enables it on a port:

```nix
services.ethereumLanNode.games.my-game = {
  package = inputs.my-game.packages.x86_64-linux.lan;
  webPort = 8001;
};
```

Its server and deploy get `ETH_NODE_URI`, `CHAIN_ID`, `MNEMONIC` and `STATE_DIRECTORY`. See [`nix/games.nix`](nix/games.nix) and the example game in [`nix/pkgs/example-game`](nix/pkgs/example-game/default.nix).

Pages are served over plain `http://<ip>`, which browsers do not treat as a secure context: `crypto.subtle`, `crypto.randomUUID` and service workers are unavailable, so a game must not depend on them.

## Reset

```
sudo ethereum-lan-node-reset
```

stops everything that remembers the chain, deletes the chain, the explorer's database, the faucet's limits and every game's state, and starts it all again; games redeploy at the same addresses.

## Test

```
nix build .#checks.x86_64-linux.vm -L
```

boots the whole box in a VM with no internet, with two simulated radios: it checks the chain, the faucet, the explorer (including that it answers on whatever host it is reached by), a deterministic game deploy, a phone joining the hotspot with WPA2 and getting a DHCP lease, and the reset.

## License

AGPL-3.0-only, see [LICENSE](LICENSE).
