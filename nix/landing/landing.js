// The landing page. Plain script, no build step, no CDN, and no API that needs a
// secure context: it is served over http from whatever address the visitor used.
(function () {
  var host = window.location.hostname;
  var proto = window.location.protocol;
  function url(port, path) {
    return proto + '//' + host + ':' + port + (path || '/');
  }
  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    for (var k in attrs || {}) {
      if (k === 'text') e.textContent = attrs[k];
      else e.setAttribute(k, attrs[k]);
    }
    (children || []).forEach(function (c) { if (c) e.appendChild(c); });
    return e;
  }
  function get(path, cb) {
    var x = new XMLHttpRequest();
    x.open('GET', path + '?t=' + Date.now());
    x.onload = function () {
      try { cb(x.status === 200 ? JSON.parse(x.responseText) : null); } catch (e) { cb(null); }
    };
    x.onerror = function () { cb(null); };
    x.send();
  }

  var config = null;
  var status = null;

  function render() {
    if (!config) return;
    document.getElementById('name').textContent = config.name + ' LAN node';
    document.title = config.name + ' LAN node';
    var block = status && status.block !== null && status.block !== undefined ? ', block ' + status.block : '';
    document.getElementById('chain').textContent =
      'Chain id ' + config.chainId + ', RPC ' + url(config.rpcPort, '') + block;

    var games = document.getElementById('games');
    games.innerHTML = '';
    if (config.games.length === 0) games.appendChild(el('li', {text: 'No games installed yet.'}));
    config.games.forEach(function (g) {
      games.appendChild(el('li', {}, [
        el('a', {href: url(g.webPort), class: 'card'}, [
          el('strong', {text: g.title}),
          g.description ? el('span', {text: g.description}) : null
        ])
      ]));
    });

    var services = document.getElementById('services');
    services.innerHTML = '';
    config.services.forEach(function (s) {
      var unitState = status && status.units ? (findUnit(s.id) || 'unknown') : 'unknown';
      var label = s.link ? el('a', {href: url(s.port, s.path), text: s.title}) : el('span', {text: s.title + ' (port ' + s.port + ')'});
      services.appendChild(el('li', {}, [label, el('span', {class: 'state ' + unitState, text: unitState})]));
    });

    var share = document.getElementById('share');
    share.innerHTML = '';
    if (config.hotspot) {
      share.appendChild(el('figure', {class: 'card'}, [
        el('img', {src: '/qr/wifi.svg', alt: 'Wi-Fi QR code'}),
        el('figcaption', {text: 'Join Wi-Fi "' + config.hotspot.ssid + '", then open http://' + config.hotspot.address + '/'})
      ]));
    }
    ((status && status.addresses) || []).forEach(function (a) {
      if (config.hotspot && a.addr === config.hotspot.address) return;
      share.appendChild(el('figure', {class: 'card'}, [
        el('img', {src: '/qr/' + a.addr + '.svg', alt: 'QR code for http://' + a.addr + '/'}),
        el('figcaption', {text: 'http://' + a.addr + '/ (' + a.ifname + ')'})
      ]));
    });
    if (config.hotspot) {
      share.appendChild(el('figure', {class: 'card'}, [
        el('img', {src: '/qr/' + config.hotspot.address + '.svg', alt: 'QR code for the hotspot address'}),
        el('figcaption', {text: 'http://' + config.hotspot.address + '/ (on the hotspot)'})
      ]));
    }
    if (status && status.time) {
      document.getElementById('updated').textContent = 'Status as of ' + new Date(status.time * 1000).toLocaleTimeString();
    }
  }

  function findUnit(id) {
    if (!status || !status.units) return null;
    var s = config.services.filter(function (x) { return x.id === id; })[0];
    return s && s.unit ? status.units[s.unit] : null;
  }

  var add = document.getElementById('add-network');
  add.addEventListener('click', function () {
    if (!window.ethereum || !config) return;
    window.ethereum.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: '0x' + config.chainId.toString(16),
        chainName: config.name,
        nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18},
        rpcUrls: [url(config.rpcPort, '')]
      }]
    }).catch(function () {});
  });

  get('config.json', function (c) {
    config = c;
    if (window.ethereum) add.hidden = false;
    render();
  });
  function poll() {
    get('status.json', function (s) { if (s) status = s; render(); });
  }
  poll();
  setInterval(poll, 5000);
})();
