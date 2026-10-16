#!/bin/sh
# Validate the whole config (main Caddyfile + every sites/*.caddy) inside the running proxy, then reload it with
# no dropped connections. Nothing is applied when validation fails.
set -eu
cd "$(dirname "$0")"
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
echo "proxy reloaded"
