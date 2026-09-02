#!/usr/bin/env bash
# proxy-up.sh — start/restart SOCKS5 (with UDP) + bore tunnel
set -u

PROXY_PORT="${PROXY_PORT:-8080}"
PUBLIC_PORT="${PUBLIC_PORT:-53755}"
PASS_FILE="$HOME/proxy.pass"

# Fixed proxy password — edit this to rotate it.
PROXY_PASSWORD="YJg7zx11Dy5Dih3r"

stop_all() {
  pkill -f '[g]ost' 2>/dev/null
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
if [ ! -x /tmp/bore ]; then
  echo "downloading bore..."
  curl -sL --max-time 60 -o /tmp/bore.tar.gz \
    "https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-unknown-linux-musl.tar.gz"
  tar xzf /tmp/bore.tar.gz -C /tmp
  if [ ! -x /tmp/bore ]; then
    BORE_BIN=$(find /tmp -maxdepth 2 -type f -name bore -not -path '/tmp/bore' | head -1)
    [ -n "$BORE_BIN" ] && cp "$BORE_BIN" /tmp/bore
  fi
  chmod +x /tmp/bore
fi

# --- make sure the gost binary exists (SOCKS5 + UDP Server) ---------------
if [ ! -x /tmp/gost ]; then
  echo "downloading gost..."
  curl -sL --max-time 60 -o /tmp/gost.gz \
    "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
  gzip -d -c /tmp/gost.gz > /tmp/gost
  chmod +x /tmp/gost
  rm -f /tmp/gost.gz
fi

# --- credentials -----------------------------------------------------------
PW="$PROXY_PASSWORD"
printf '%s' "$PW" > "$PASS_FILE"
chmod 600 "$PASS_FILE"
echo "using fixed password"

# --- start GOST (SOCKS5 with UDP enabled) ----------------------------------
setsid /tmp/gost -L "socks5://proxy:${PW}@0.0.0.0:${PROXY_PORT}?udp=true" \
  > "$HOME/proxy.log" 2>&1 < /dev/null &
sleep 1

# --- start the tunnel -------------------------------------------------------
setsid /tmp/bore local "$PROXY_PORT" --to bore.pub --port "$PUBLIC_PORT" \
  > "$HOME/bore.log" 2>&1 < /dev/null &
sleep 3
if ! grep -q "listening at bore.pub:$PUBLIC_PORT" "$HOME/bore.log"; then
  echo "fixed port $PUBLIC_PORT unavailable, falling back to a random port..."
  pkill -f '[b]ore local' 2>/dev/null
  sleep 1
  setsid /tmp/bore local "$PROXY_PORT" --to bore.pub > "$HOME/bore.log" 2>&1 < /dev/null &
  sleep 3
fi

ACTUAL_PORT=$(grep -oE 'bore\.pub:[0-9]+' "$HOME/bore.log" | head -1 | cut -d: -f2)
if [ -z "$ACTUAL_PORT" ]; then
  echo "ERROR: tunnel failed to start (see $HOME/bore.log)"
  exit 1
fi

# --- verify -----------------------------------------------------------------
echo
echo "SOCKS5 Proxy Address: socks5://proxy:$PW@bore.pub:$ACTUAL_PORT"
echo