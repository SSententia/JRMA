#!/usr/bin/env bash
# proxy-up.sh — start/restart the sandbox proxy + bore tunnel in one command.
#   bash ~/proxy-up.sh          start or restart everything
#   bash ~/proxy-up.sh stop     stop everything
#
# Survives a full sandbox recycle: re-downloads the bore binary if /tmp was
# wiped, regenerates ~/proxy-server.js if it's missing or stale, and generates
# a fresh password on first run (reuses ~/proxy.pass when present).
# Tries the fixed public port first, falls back to a random one if it's taken.
set -u

PROXY_PORT="${PROXY_PORT:-8080}"
PUBLIC_PORT="${PUBLIC_PORT:-53755}"
PASS_FILE="$HOME/proxy.pass"
PROXY_FILE="$HOME/proxy-server.js"

# Prefer the bore binary baked into the image; fall back to /tmp (downloaded).
BORE_BIN=/usr/local/bin/bore
[ -x "$BORE_BIN" ] || BORE_BIN=/tmp/bore

# Fixed proxy password — edit this to rotate it.
PROXY_PASSWORD="YJg7zx11Dy5Dih3r"

stop_all() {
  pkill -f '[p]roxy-server\.js' 2>/dev/null
  pkill -f '[b]ore local' 2>/dev/null
  sleep 1
}

if [ "${1:-}" = "stop" ]; then
  stop_all
  echo "stopped proxy + tunnel"
  exit 0
fi

stop_all

# --- make sure the bore binary exists -------------------------------------
if [ ! -x "$BORE_BIN" ]; then
  echo "downloading bore..."
  curl -sL --max-time 60 -o /tmp/bore.tar.gz \
    "https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-unknown-linux-musl.tar.gz"
  tar xzf /tmp/bore.tar.gz -C /tmp
  if [ ! -x /tmp/bore ]; then   # tar layout differs: locate the binary
    FOUND=$(find /tmp -maxdepth 2 -type f -name bore -not -path '/tmp/bore' | head -1)
    [ -n "$FOUND" ] && cp "$FOUND" /tmp/bore
  fi
  chmod +x "$BORE_BIN"
fi

# --- make sure the proxy server file exists --------------------------------
ensure_proxy_server() {
  cat > "$HOME/.proxy-server.js.expected" <<'PROXY_EOF'
// Minimal zero-dependency forward HTTP(S) proxy with Basic auth.
// Supports: absolute-URI HTTP requests + CONNECT tunneling (HTTPS).
// Credentials come from env: PROXY_USER, PROXY_PASS (defaults: proxy / changeme).
// Usage: PROXY_USER=u PROXY_PASS=p node proxy-server.js [port]
'use strict';

const http = require('http');
const net = require('net');

const PORT = parseInt(process.argv[2] || '8080', 10);
const USER = process.env.PROXY_USER || 'proxy';
const PASS = process.env.PROXY_PASS || 'changeme';
const AUTH = 'Basic ' + Buffer.from(`${USER}:${PASS}`).toString('base64');

function authorized(req) {
  const provided = req.headers['proxy-authorization'] || '';
  return provided === AUTH;
}

function deny(res) {
  res.writeHead(407, {
    'Proxy-Authenticate': 'Basic realm="sandbox-proxy"',
    'content-type': 'text/plain',
  });
  res.end('Proxy authentication required.\n');
}

const server = http.createServer((req, res) => {
  if (!authorized(req)) return deny(res);

  // HTTP proxies receive absolute-form requests: GET http://example.com/path HTTP/1.1
  let target;
  try {
    target = new URL(req.url);
  } catch {
    res.writeHead(400, { 'content-type': 'text/plain' });
    res.end('Proxy requires absolute-URI requests (this is a forward proxy).\n');
    return;
  }

  const headers = { ...req.headers };
  delete headers['proxy-connection'];
  delete headers['proxy-authorization'];

  const proxyReq = http.request({
    hostname: target.hostname,
    port: target.port || 80,
    path: target.pathname + target.search,
    method: req.method,
    headers,
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (err) => {
    res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`Proxy error: ${err.message}\n`);
  });

  req.pipe(proxyReq);
});

// CONNECT <host>:<port> -> raw TCP tunnel (used for HTTPS)
server.on('connect', (req, clientSocket, head) => {
  if (!authorized(req)) {
    clientSocket.write(
      'HTTP/1.1 407 Proxy Authentication Required\r\n' +
      'Proxy-Authenticate: Basic realm="sandbox-proxy"\r\n\r\n'
    );
    clientSocket.destroy();
    return;
  }

  const [host, port] = req.url.split(':');
  const targetSocket = net.connect(parseInt(port, 10) || 443, host, () => {
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) targetSocket.write(head);
    targetSocket.pipe(clientSocket);
    clientSocket.pipe(targetSocket);
  });
  targetSocket.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => targetSocket.destroy());
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`proxy listening on 0.0.0.0:${PORT} (auth: ${USER}/***)`);
});
PROXY_EOF
  EXPECTED_SUM=$(sha256sum < "$HOME/.proxy-server.js.expected")
  CURRENT_SUM=$( [ -f "$PROXY_FILE" ] && sha256sum < "$PROXY_FILE" 2>/dev/null )
  if [ "$EXPECTED_SUM" != "$CURRENT_SUM" ]; then
    cp "$HOME/.proxy-server.js.expected" "$PROXY_FILE"
    chmod 600 "$PROXY_FILE"
    echo "wrote proxy server to $PROXY_FILE"
  else
    echo "proxy server already up to date"
  fi
  rm -f "$HOME/.proxy-server.js.expected"
}
ensure_proxy_server

# --- credentials -----------------------------------------------------------
PW="$PROXY_PASSWORD"
printf '%s' "$PW" > "$PASS_FILE"
chmod 600 "$PASS_FILE"
echo "using fixed password (edit PROXY_PASSWORD at the top of $0 to rotate)"

# --- start the proxy --------------------------------------------------------
PROXY_USER=proxy PROXY_PASS="$PW" setsid node "$PROXY_FILE" "$PROXY_PORT" \
  > "$HOME/proxy.log" 2>&1 < /dev/null &
sleep 1

# --- start the tunnel -------------------------------------------------------
setsid "$BORE_BIN" local "$PROXY_PORT" --to bore.pub --port "$PUBLIC_PORT" \
  > "$HOME/bore.log" 2>&1 < /dev/null &
sleep 3
if ! grep -q "listening at bore.pub:$PUBLIC_PORT" "$HOME/bore.log"; then
  echo "fixed port $PUBLIC_PORT unavailable, falling back to a random port..."
  pkill -f '[b]ore local' 2>/dev/null
  sleep 1
  setsid "$BORE_BIN" local "$PROXY_PORT" --to bore.pub > "$HOME/bore.log" 2>&1 < /dev/null &
  sleep 3
fi

ACTUAL_PORT=$(grep -oE 'bore\.pub:[0-9]+' "$HOME/bore.log" | head -1 | cut -d: -f2)
if [ -z "$ACTUAL_PORT" ]; then
  echo "ERROR: tunnel failed to start (see $HOME/bore.log)"
  exit 1
fi

# --- verify -----------------------------------------------------------------
echo
echo "proxy address: http://proxy:$PW@bore.pub:$ACTUAL_PORT"
echo

HTTP_CODE=$(curl -s -U "proxy:$PW" -x "http://localhost:$PROXY_PORT" -o /dev/null \
  -w '%{http_code}' --max-time 15 http://example.com)
echo "local check:  HTTP $HTTP_CODE (expect 200)"

IP=$(curl -s -U "proxy:$PW" -x "http://bore.pub:$ACTUAL_PORT" --max-time 25 https://ifconfig.me)
if [ -n "$IP" ]; then
  echo "public check: CONNECT OK, egress IP $IP"
else
  echo "public check: FAILED — tunnel not reachable yet, wait a few seconds and re-run"
fi
