# A stand-in game in the exact shape a real game's `lan` package has (see the
# header of nix/games.nix): a static page, a server, and a deploy that puts a
# contract on the chain DETERMINISTICALLY (CREATE2 through the factory the
# genesis predeploys), so its address is known before the chain exists.
{
  runCommand,
  writeShellApplication,
  writeText,
  foundry,
  python3,
  coreutils,
}: let
  # init code returning a 10-byte runtime that answers 42 to any call
  initCode = "0x600a600c600039600a6000f3602a60005260206000f3";
  salt = "0x0000000000000000000000000000000000000000000000000000000000000001";
  factory = "0x4e59b44847b379578588920ca78fbf26c0b4956c";

  deploy = writeShellApplication {
    name = "example-game-deploy";
    runtimeInputs = [foundry coreutils];
    text = ''
      addr=$(cast create2 --deployer ${factory} --salt ${salt} --init-code ${initCode})
      if [ "$(cast code --rpc-url "$ETH_NODE_URI" "$addr")" = "0x" ]; then
        cast send --rpc-url "$ETH_NODE_URI" --mnemonic "$MNEMONIC" \
          ${factory} "${salt}${builtins.substring 2 1000 initCode}" >/dev/null
      fi
      [ "$(cast code --rpc-url "$ETH_NODE_URI" "$addr")" != "0x" ]
      echo "$addr" > "$STATE_DIRECTORY/contract"
      echo "example-game: contract at $addr"
    '';
  };

  server = writeShellApplication {
    name = "example-game-server";
    runtimeInputs = [python3];
    text = ''
      exec python3 ${writeText "server.py" ''
        import http.server, json, os, sys
        port = int(sys.argv[1])
        state = os.environ["STATE_DIRECTORY"]
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                try:
                    contract = open(os.path.join(state, "contract")).read().strip()
                except OSError:
                    contract = None
                body = json.dumps({"game": "example", "contract": contract}).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("access-control-allow-origin", "*")
                self.end_headers()
                self.wfile.write(body)
        http.server.ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
      ''} "$@"
    '';
  };
in
  runCommand "example-game-lan" {
    passthru.lan = {
      title = "Example game";
      description = "A placeholder showing the shape of a game package.";
      server = {
        bin = "example-game-server";
        port = 30099;
        args = ["30099"];
      };
      deploy.bin = "example-game-deploy";
    };
  } ''
    mkdir -p $out/web $out/bin
    cat > $out/web/index.html <<'HTML'
    <!doctype html><meta charset="utf-8"><title>Example game</title>
    <h1>Example game</h1><pre id="s">asking the server...</pre>
    <script>
      fetch(location.protocol + '//' + location.hostname + ':30099/')
        .then(function (r) { return r.json(); })
        .then(function (j) { document.getElementById('s').textContent = JSON.stringify(j, null, 2); });
    </script>
    HTML
    ln -s ${deploy}/bin/example-game-deploy $out/bin/
    ln -s ${server}/bin/example-game-server $out/bin/
  ''
