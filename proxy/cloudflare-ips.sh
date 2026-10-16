#!/bin/sh
# Refresh cloudflare.env (CF_RANGES, used by the Caddyfile for trusted_proxies and the origin gate) from
# Cloudflare's published lists, show what changed, and remind about the provider firewall. Then ./reload.sh.
# Cloudflare changes these rarely; run monthly or when Cloudflare announces a change.
set -eu
cd "$(dirname "$0")"
v4=$(curl -fsS https://www.cloudflare.com/ips-v4 | tr -s '\n' ' ')
v6=$(curl -fsS https://www.cloudflare.com/ips-v6 | tr -s '\n' ' ')
[ -n "$v4" ] && [ -n "$v6" ] || { echo "empty list from cloudflare.com, nothing changed" >&2; exit 1; }
new=$(printf '# Cloudflare edge ranges (https://www.cloudflare.com/ips/), fetched %s by cloudflare-ips.sh.\nCF_RANGES=%s %s\n' \
  "$(date -u +%Y-%m-%d)" "$v4" "$v6" | sed 's/ *$//')
if [ -f cloudflare.env ] && [ "$(grep '^CF_RANGES=' cloudflare.env)" = "$(printf '%s\n' "$new" | grep '^CF_RANGES=')" ]; then
  echo "cloudflare.env is current"; exit 0
fi
printf '%s\n' "$new" > cloudflare.env
echo "cloudflare.env updated. Recreate caddy so it sees the new env: docker compose up -d --wait caddy"
echo "If the provider firewall lists ranges by hand (not its Cloudflare source), update it too."
