# ethereum LAN node

A NixOS module that turns one small x86 box into a self-contained games-and-chain server you can carry to an event: a dev chain, an explorer with contract verification, a faucet, its own Wi-Fi hotspot, and browser games, all of it working with no internet and starting on boot with no manual step.

The previous Ubuntu + docker compose version is in [`legacy/`](legacy/README.md).

## What runs

| port | what |
| --- | --- |
| 80 | landing page: the games, the services and whether they run, the current block, the box's addresses, QR codes to join the Wi-Fi and to open the page |
| 8545 / 8546 | geth in dev mode (HTTP / WS), chain id 19216801, a block every 2 s |
| 4000 | blockscout explorer, with contract verification for the preloaded solc versions (0.8.24, 0.8.28) |
| 34010 | faucet (1 ETH a claim, no captcha) |
| one per game | each game's static site, plus any port its own server uses |

The genesis ([`nix/genesis.json`](nix/genesis.json)) funds the 20 accounts of the `test test test test test test test test test test test junk` mnemonic with 10000 ETH each and predeploys the deterministic-deployment proxy at `0x4e59b44847b379578588920ca78fbf26c0b4956c`, so CREATE2 deployments land at the same address on every box and after every reset. Every key involved is public: this is a toy chain.

Everything is in the system closure: the blockscout images are pinned by digest and never pulled, npm dependencies are vendored at build time, and the solc compilers are preloaded. The VM test runs with no network to prove it. The box survives a pulled power cable (geth, postgres and ext4 recover on their own).

## Hardware

Any x86_64 box that boots UEFI or BIOS, with 8 GB of RAM or more (blockscout and its postgres are the heavy part) and a disk of 64 GB or more.

**Two radios are best**: one for the hotspot, one to join networks, so they never have to agree on a channel. A USB dongle with a MediaTek mt76 chipset (this module was built on an MT7612U) makes a good hotspot radio; Intel cards are usually fine as the client but often refuse to start an access point on 5 GHz. Check a radio with `iw list`: it needs `AP` under "Supported interface modes", and "valid interface combinations" tells you whether one radio can do AP and client at once.

**Name the hotspot radio by driver**, not by the name the kernel happens to give it, so a replacement dongle of the same model just works:

```nix
systemd.network.links."10-hotspot" = {
  matchConfig.Driver = "mt76x2u";
  linkConfig.Name = "wlap0";
};
services.ethereumLanNode.network.ap.interface = "wlap0";
```

**Set a country** (`network.ap.countryCode`, default `GB`): without one, every 5 GHz channel is "no initiating radiation" and the hotspot cannot start there.

**Do not encrypt the disk** unless someone will be at a keyboard at every boot: an event box has to come up on its own.

**If the box also has another OS** (many mini PCs ship Windows on an eMMC), the firmware may put it first in the boot order after you install. Fix it once in the firmware setup, or keep NixOS first from NixOS itself with a boot-time `efibootmgr -o` (check the order with `bootctl status`).

## Install

Add the module to a NixOS configuration:

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
              interface = "wlap0"; # the radio that becomes the hotspot
            };
          };
        }
      ];
    };
  };
}
```

[`examples/host.nix`](examples/host.nix) is a complete minimal host (`nix build .#nixosConfigurations.example.config.system.build.toplevel` builds it). To install onto a box that runs any Linux you can ssh into as root, add a [disko](https://github.com/nix-community/disko) layout to your host and use [nixos-anywhere](https://github.com/nix-community/nixos-anywhere), which WIPES the disk you give it:

```
nix run github:nix-community/nixos-anywhere -- --flake .#my-box --target-host root@<box-ip>
```

## Reaching the box

- **On its own Wi-Fi**: SSID `master node`, passphrase `I am vitalik` (both options). The box is ALWAYS `http://10.42.0.1` there, so a printed card with the Wi-Fi QR (`http://10.42.0.1/qr/wifi.svg`) and that URL always works. Its DNS also answers `ethereum.lan` and `<hostname>.lan`.
- **On a network it joined** (Ethernet by DHCP, or Wi-Fi on the other radio): it gets whatever address that network hands out, different at every venue. Devices that do mDNS (laptops, iPhones) reach `<hostname>.local` if you enable Avahi (the example host does); most Android phones cannot resolve `.local`, so give them the IP. The landing page lists every current address with a QR code: open it once from a laptop and show the QR.
- **Both at once** is the normal case: the hotspot keeps running beside an uplink, and hotspot clients get the internet through it when there is some, but never the uplink's private ranges (the venue LAN, its router, a tailnet).

Everything is served over plain `http://<ip>`, which browsers do not treat as a secure context: no `crypto.subtle`, no `crypto.randomUUID`, no service worker. Games must work without them. Every URL a page uses should be same-host (`//:8545` meaning "the host this page came from, port 8545"), never `localhost` (which on a phone is the phone) and never a fixed IP.

## Deploying changes

Every change is: edit your config, build, switch. With plain NixOS tooling, from the machine where your config lives:

```
nixos-rebuild switch --flake .#my-box --target-host <user>@<hostname>.local --sudo
```

(`<user>` is any account with sudo on the box and your ssh key; the example host only has `root`, in which case drop `--sudo`. `--ask-sudo-password` if sudo needs one.) Any other deploy tool (colmena, deploy-rs) works the same way. Only what changed restarts; a game whose contracts the box deploys redeploys, idempotently, at the same address.

Rolling back, on the box itself, needs no build: `sudo nixos-rebuild switch --rollback`, or pick the previous generation in the boot menu.

## Games

### Writing a game package

A game is a package its OWN repo builds, so this flake never learns how any game is built:

```
$out/web/              the static site
$out/bin/<server>      optional: a long-running service (a room server, an indexer)
$out/bin/<deploy>      optional: deploys its contracts, idempotently
passthru.lan = {
  title = "My game";
  description = "One line for the landing page.";
  fallback = "/404.html";            # SPA shell for unknown routes (default /index.html)
  server = { bin = "my-game-server"; port = 30042; args = ["--port" "30042" "--db" "file:$STATE_DIRECTORY/db"]; };
  deploy.bin = "my-game-deploy";
};
```

The server and the deploy get `ETH_NODE_URI` (the chain, local), `CHAIN_ID`, `MNEMONIC` and their own `STATE_DIRECTORY` (wiped by a reset). The deploy runs once the chain answers and before the server starts. See [`nix/games.nix`](nix/games.nix), the example game in [`nix/pkgs/example-game`](nix/pkgs/example-game/default.nix), and conquest-demo's `nix/lan.nix` for a real SvelteKit + node one.

Things worth knowing when packaging:

- **Build the web app with same-host URLs** (`PUBLIC_NODE_URL="//:8545"`, a faucet at `//:34010`, a room server at the page's host and its own port), so one build works on every address the box answers on.
- **Deploy deterministically** (CREATE2 through the predeployed proxy): then the addresses the web build embeds are right on every box and after every reset, and the build can even run its deploy against a throwaway chain from the same genesis to get them.
- **Pin anything a build derives from git**: there is no `.git` in the Nix sandbox. A SvelteKit config that falls back to a timestamp computes a different one in each build process, and the prerendered HTML then names a different build than its JS, so the page renders and never hydrates.

### Adding, updating, removing

```nix
services.ethereumLanNode.games.my-game = {
  package = inputs.my-game.packages.x86_64-linux.lan;
  webPort = 8001; # one free port per game
};
```

- **Add**: a flake input for the game's repo, a `games.<name>` entry, deploy. The landing page lists it and the firewall opens its ports by themselves.
- **Update**: push to the game's repo, `nix flake update <input>`, deploy.
- **Remove**: delete the entry and its input, deploy. Its old state stays in `/var/lib/ethereum-lan-node/games/<name>/` until you delete it or reset.

**One port per game, never a hostname**: a port works the same on the hotspot, on a venue network, by IP and by mDNS name, with no DNS to set up, and a static build served at `/` needs no base path.

Today a game has ONE server. A game that needs several helper services needs the game module extended first.

## Services

The parts (`chain`, `explorer`, `faucet`, `network`, the landing page) each have their own `enable`. A service every LAN node should have goes in this repo as a file beside [`nix/faucet.nix`](nix/faucet.nix), following its pattern: a systemd unit under the shared `ethereum-lan-node` user, its state under `stateDir`, and two registrations, `services.ethereumLanNode.services.<id>` (so the landing page shows it) and `resetUnits` (so a reset restarts it). A helper only one game uses belongs in that game's package.

## Secrets

None are needed: every key here is public by design, and the hotspot passphrase is a public default meant to be printed. If you want a private one, use `network.ap.passphraseFile` with your secrets tool (sops-nix, agenix). Known Wi-Fi networks to join are plain NetworkManager config (`networking.networkmanager.ensureProfiles`, with `environmentFiles` for the passwords), or added on the box at the event (below).

## Before leaving for an event

The box itself needs no internet. Changing it at the event does, unless you prepare, because a deploy builds on the machine you deploy FROM and fetches whatever is not already in that machine's Nix store.

1. Deploy any pending change at home, and check the landing page.
2. From the laptop you will bring, run the same deploy once at home. Its store then holds the whole closure and the flake inputs, so the same deploy, or one that only changes options, can run offline. A change that needs NEW sources (a new game commit, new dependencies) cannot be built offline: build it before you go.
3. Print the hotspot card: the Wi-Fi QR and `http://10.42.0.1`.
4. Bring the hotspot dongle.

## At the event

- **Reach the box**: join its Wi-Fi and ssh to `<user>@10.42.0.1` (or `<hostname>.local`). A deploy tool that targets `<hostname>.local` can be pointed at the hotspot with `10.42.0.1 <hostname>.local` in the laptop's `/etc/hosts`.
- **Start clean** (wipes the chain, the explorer's database, the faucet's limits and every game's state; games redeploy at the same addresses):

  ```
  ssh <user>@10.42.0.1 sudo ethereum-lan-node-reset        # asks you to type `reset`; --yes skips it
  ```

- **Join the venue's Wi-Fi** on the client radio, no deploy needed (NetworkManager keeps it across reboots until you delete it):

  ```
  ssh <user>@10.42.0.1 sudo nmcli dev wifi connect "<venue SSID>" password "<password>" ifname <client radio>
  ssh <user>@10.42.0.1 sudo nmcli connection delete "<venue SSID>"   # afterwards
  ```

  Ethernet needs nothing: plug it in.
- **See what runs**: the landing page, or `systemctl --failed` and `journalctl -b -u <unit>` on the box. The units: `ethereum-lan-node-chain`, `ethereum-lan-node-faucet`, `ethereum-lan-node-game-<name>`, `ethereum-lan-node-deploy-<name>`, `podman-blockscout-{backend,frontend,verifier}`, `postgresql`, `caddy`, `hostapd`, `dnsmasq`, `ethereum-lan-node-status` (the landing page's feed, every 10 s).
- **Something broke after a deploy**: `sudo nixos-rebuild switch --rollback` on the box.
- **Old phones cannot see the hotspot**: `network.ap.band = "2g";` (channel 6), deploy.
- **Turning it off**: `sudo systemctl poweroff` is cleanest; pulling the cable is survivable.

## Options

All under `services.ethereumLanNode`:

| option | default | |
| --- | --- | --- |
| `enable` | false | the whole box |
| `name` | `"LAN"` | the chain's display name |
| `stateDir` | `/var/lib/ethereum-lan-node` | everything the box remembers; the reset empties it |
| `openFirewall` | true | open every service port on every interface |
| `chain.{enable,package,genesis,blockTime,httpPort,wsPort,mnemonic}` | on, go-ethereum, `nix/genesis.json`, 2, 8545, 8546, test junk | `chain.chainId` and `chain.rpcUrl` are read-only, derived |
| `explorer.{enable,port,solc}` | on, 4000, 0.8.24 + 0.8.28 | `solc` entries are soliditylang's `list.json` entries |
| `faucet.{enable,package,port,amount,privateKey}` | on, faucet-server, 34010, 1 ETH, account 0 | |
| `network.networkmanager` | true | NetworkManager manages the uplinks |
| `network.shareInternet` | true | NAT hotspot clients out of any uplink |
| `network.ap.{enable,interface,ssid,passphrase,passphraseFile,countryCode,band,channel,htCapabilities,address,blockPrivateNetworks}` | off, -, `master node`, `I am vitalik`, null, `GB`, `5g`, 36 (6 on 2g), HT40 + short GI, `10.42.0.1`, true | |
| `games.<name>.{package,webPort,title,description,fallback,server.*,deploy.*}` | | the rest default from `package.passthru.lan` |
| `landing.{enable,port}` | on, 80 | |

## Test

```
nix build .#checks.x86_64-linux.vm -L
```

boots the whole box in a VM with no internet, with two simulated radios: it checks the chain, the faucet, the explorer (including that it answers on whatever host it is reached by), a deterministic game deploy, a phone joining the hotspot with WPA2 and getting a DHCP lease, and the reset.

Not covered yet: a deploy from a fully offline laptop, and `<hostname>.local` from a phone on the hotspot.

## Layout

```
flake.nix                 nixosModules.default, packages, the example host, checks.vm
nix/module.nix            top-level options, the reset command
nix/chain.nix             geth dev chain
nix/explorer.nix          blockscout + postgres + offline solc
nix/faucet.nix            the faucet
nix/network.nix           hotspot, uplinks, NAT
nix/games.nix             games, landing page, status feed
nix/landing/              the landing page (plain HTML/JS, no CDN)
nix/genesis.json          the chain's genesis
nix/pkgs/                 faucet-server and the example game
nix/tests/vm.nix          the VM test
examples/host.nix         a minimal host to start from
legacy/                   the old docker compose setup
```

## License

AGPL-3.0-only, see [LICENSE](LICENSE).
