# The whole box in a VM, with NO network beyond the test's own (so anything
# that tries to fetch from the internet at runtime fails here first).
#
# The hotspot is real: mac80211_hwsim gives the VM two radios; wlan0 becomes
# the AP and wlan1 is moved into a network namespace to play a phone, which
# associates with WPA2, takes a DHCP lease and loads the landing page.
{
  pkgs,
  lib,
  module,
  exampleGame,
}:
pkgs.testers.runNixOSTest {
  name = "ethereum-lan-node";

  nodes.box = {pkgs, ...}: {
    imports = [module];

    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
    virtualisation.diskSize = 8192;

    boot.kernelModules = ["mac80211_hwsim"];
    environment.systemPackages = [pkgs.foundry pkgs.wpa_supplicant pkgs.iw pkgs.curl pkgs.jq pkgs.busybox];

    services.ethereumLanNode = {
      enable = true;
      games.example = {
        package = exampleGame;
        webPort = 8001;
      };
      network = {
        # The test drives the client radio by hand.
        networkmanager = false;
        ap = {
          enable = true;
          interface = "wlan0";
          band = "2g";
          # hwsim does not advertise HT40; ask for nothing it lacks.
          htCapabilities = [];
        };
      };
    };
  };

  testScript = ''
    import json, shlex

    def rpc_cmd(method, params, url="http://127.0.0.1:8545"):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        return f"curl -sf -H 'content-type: application/json' -d {shlex.quote(body)} {url}"

    def rpc(method, params, machine=None):
        return json.loads(box.succeed(rpc_cmd(method, params)))["result"]

    box.start()

    with subtest("the chain answers with the LAN chain id and the funded accounts"):
        box.wait_for_unit("ethereum-lan-node-chain.service")
        assert rpc("eth_chainId", []) == "0x12539a1"
        assert int(rpc("eth_getBalance", ["0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "latest"]), 16) == 10000 * 10**18
        box.wait_until_succeeds(rpc_cmd("eth_blockNumber", []) + " | jq -e '.result != \"0x0\" and .result != \"0x1\"'", timeout=60)

    with subtest("the example game deployed deterministically and its server sees it"):
        box.wait_for_unit("ethereum-lan-node-deploy-example.service")
        box.wait_for_unit("ethereum-lan-node-game-example.service")
        addr = box.succeed("cast create2 --deployer 0x4e59b44847b379578588920ca78fbf26c0b4956c --salt 0x0000000000000000000000000000000000000000000000000000000000000001 --init-code 0x600a600c600039600a6000f3602a60005260206000f3").strip()
        code = box.succeed(f"cast code --rpc-url http://127.0.0.1:8545 {addr}").strip()
        assert code == "0x602a60005260206000f3", code
        box.wait_until_succeeds(f"curl -sf http://127.0.0.1:30099/ | jq -e '.contract == \"{addr}\"'", timeout=30)
        box.wait_for_unit("caddy.service")
        box.wait_for_open_port(8001)
        box.succeed("curl -sf http://127.0.0.1:8001/ | grep -q 'Example game'")

    with subtest("the faucet funds a fresh address"):
        box.wait_for_unit("ethereum-lan-node-faucet.service")
        box.wait_for_open_port(34010)
        fresh = "0x000000000000000000000000000000000000beef"
        box.succeed(f"curl -sf -X POST -H 'content-type: application/json' -d '{{\"token\":\"none\",\"chainId\":\"19216801\",\"address\":\"{fresh}\"}}' http://127.0.0.1:34010/api/claim")
        box.wait_until_succeeds(f"[ \"$(cast balance --rpc-url http://127.0.0.1:8545 {fresh})\" != 0 ]", timeout=30)

    with subtest("the landing page lists the game and reports the units"):
        box.wait_for_open_port(80)
        cfg = json.loads(box.succeed("curl -sf http://127.0.0.1/config.json"))
        assert cfg["chainId"] == 19216801 and cfg["games"][0]["webPort"] == 8001, cfg
        box.wait_until_succeeds("curl -sf http://127.0.0.1/status.json | jq -e '.units[\"ethereum-lan-node-chain.service\"] == \"active\" and .block > 0'", timeout=60)
        box.succeed("curl -sf http://127.0.0.1/qr/wifi.svg | grep -q '<svg'")

    with subtest("the explorer comes up and talks back to whatever host it was reached on"):
        box.wait_for_unit("podman-blockscout-backend.service")
        box.wait_until_succeeds("curl -sf http://127.0.0.1:4000/api/v2/stats | jq -e '.total_blocks != null'", timeout=600)
        box.wait_until_succeeds("curl -sf -o /dev/null http://127.0.0.1:4000/", timeout=300)
        envs = box.succeed("curl -sf -H 'Host: 10.42.0.1:4000' http://127.0.0.1:4000/assets/envs.js")
        assert 'NEXT_PUBLIC_API_HOST: "10.42.0.1"' in envs, envs
        assert 'NEXT_PUBLIC_NETWORK_ID: "19216801"' in envs, envs
        box.wait_until_succeeds("curl -sf http://127.0.0.1:4003/health || curl -sf http://127.0.0.1:4003/api/v2/verifier/solidity/versions | grep -q 0.8.28", timeout=120)
        box.succeed("curl -sf http://127.0.0.1:4003/api/v2/verifier/solidity/versions | grep -q 'v0.8.28+commit.7893614a'")

    with subtest("a phone joins the hotspot, gets a lease and loads the landing page"):
        box.wait_for_unit("hostapd.service")
        box.wait_for_unit("dnsmasq.service")
        box.succeed("ip netns add phone")
        box.succeed("iw phy phy1 set netns name phone")
        box.succeed("ip netns exec phone ip link set lo up")
        box.succeed("printf 'network={\\n ssid=\"master node\"\\n psk=\"I am vitalik\"\\n key_mgmt=WPA-PSK\\n}\\n' > /tmp/phone.conf")
        box.succeed("ip netns exec phone wpa_supplicant -B -i wlan1 -c /tmp/phone.conf")
        box.wait_until_succeeds("ip netns exec phone iw dev wlan1 link | grep -q 'SSID: master node'", timeout=60)
        # busybox udhcpc, not dhcpcd: the box's own dhcpcd owns dhcpcd's pid file.
        box.succeed("printf '#!/bin/sh\\n[ \"$1\" = bound ] && ip addr add $ip/24 dev $interface\\nexit 0\\n' > /tmp/udhcpc.sh && chmod +x /tmp/udhcpc.sh")
        box.succeed("ip netns exec phone busybox udhcpc -i wlan1 -n -q -t 10 -s /tmp/udhcpc.sh")
        box.succeed("ip netns exec phone ip -4 addr show wlan1 | grep -q 'inet 10.42.0.'")
        box.succeed("ip netns exec phone curl -sf http://10.42.0.1/config.json | jq -e '.hotspot.ssid == \"master node\"'")
        box.succeed("ip netns exec phone curl -sf http://10.42.0.1:8001/ | grep -q 'Example game'")
        box.succeed("ip netns exec phone " + rpc_cmd("eth_chainId", [], "http://10.42.0.1:8545") + " | grep -q 0x12539a1")

    with subtest("one command resets the chain, and the game redeploys at the same address"):
        box.succeed("ethereum-lan-node-reset --yes")
        box.wait_for_unit("ethereum-lan-node-deploy-example.service")
        assert int(rpc("eth_getBalance", ["0x000000000000000000000000000000000000beef", "latest"]), 16) == 0
        code = box.succeed(f"cast code --rpc-url http://127.0.0.1:8545 {addr}").strip()
        assert code == "0x602a60005260206000f3", code
  '';
}
