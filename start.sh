#!/usr/bin/env bash
# start.sh — single entrypoint for the container. Requires no manual setup:
# Python deps, Node.js, and bore are already baked into the image at build time.
set -u

# Start (or restart) the proxy + tunnel in the background; don't block the bot.
bash "$(dirname "$0")/proxy-up.sh" || echo "WARNING: proxy/tunnel failed to start — see proxy.log/bore.log"

# Run the Discord bot in the foreground (keeps the container alive).
exec python main.py
