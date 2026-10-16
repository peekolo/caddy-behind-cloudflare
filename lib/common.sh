# Shared helpers for caddy-behind-cloudflare scripts. Sourced, never run. Needs bash, curl, jq, ssh, rsync on the workstation.
set -Eeuo pipefail

AIDEPLOY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROXY_NET=proxy
PROXY_SUBNET=10.89.0.0/24
PROXY_DIR=/srv/proxy
DRY_RUN=${DRY_RUN:-0}

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
step() { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s  ok%s   %s\n' "$G" "$N" "$*"; }
skip() { printf '%s  skip%s %s\n' "$Y" "$N" "$*"; }
warn() { printf '%s  warn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s  FAIL%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
# Run a changing action, or only print it with --dry-run.
act()  { if [[ "$DRY_RUN" == 1 ]]; then printf '%s  would%s %s\n' "$Y" "$N" "$1"; return 1; fi; printf '  do   %s\n' "$1"; return 0; }

need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing command on this machine: $c"; done; }

# load_host <name>: reads hosts/<name>.env into HOST_* variables.
load_host() {
  local f="$AIDEPLOY/hosts/$1.env"
  [[ -f "$f" ]] || die "no host record $f (copy hosts/example.env and edit it)"
  # shellcheck disable=SC1090
  HOST_NAME= HOST_IP= HOST_SSH= HOST_TYPE=; eval "$(sed -nE 's/^(NAME|IP|SSH|TYPE)=([^#]*).*/HOST_\1=\2/p' "$f")"
  HOST_NAME=${HOST_NAME//[\" ]/}; HOST_IP=${HOST_IP//[\" ]/}; HOST_SSH=${HOST_SSH//[\" ]/}; HOST_TYPE=${HOST_TYPE//[\" ]/}
  [[ -n "$HOST_IP" && -n "$HOST_SSH" ]] || die "$f needs IP= and SSH="
}

# on_host <command...>: run on the box as the deploy user (no tty, fails on error).
on_host() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST_SSH" "$@"; }

# ---- Cloudflare API (token from cloudflare.token or CF_API_TOKEN; never printed, never sent to a server) ------

cf_token() {
  if [[ -n "${CF_API_TOKEN:-}" ]]; then printf '%s' "$CF_API_TOKEN"; return; fi
  local f="$AIDEPLOY/cloudflare.token"
  [[ -r "$f" ]] || die "no Cloudflare token: put it in $f (mode 600) or export CF_API_TOKEN"
  [[ "$(stat -c %a "$f")" == 600 ]] || chmod 600 "$f"
  head -1 "$f" | tr -d '[:space:]'
}

# cf <METHOD> <path> [json-body]: prints the JSON reply; dies with Cloudflare's error text on failure.
cf() {
  local method=$1 path=$2 body=${3:-} out
  local args=(-sS -X "$method" -H "Authorization: Bearer $(cf_token)" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  out=$(curl "${args[@]}" "https://api.cloudflare.com/client/v4$path") || die "Cloudflare API unreachable ($method $path)"
  if [[ "$(jq -r '.success' <<<"$out")" != true ]]; then
    die "Cloudflare $method $path: $(jq -c '.errors' <<<"$out")"
  fi
  printf '%s' "$out"
}

cf_zone_id() {
  local id; id=$(cf GET "/zones?name=$1" | jq -r '.result[0].id // empty')
  [[ -n "$id" ]] || die "zone $1 is not in this Cloudflare account (add the domain to Cloudflare first)"
  printf '%s' "$id"
}

# fqdn <zone> <name>: "@" -> zone, "www" -> www.zone, a full name stays as is.
fqdn() { if [[ "$2" == "@" ]]; then printf '%s' "$1"; elif [[ "$2" == *".$1" || "$2" == "$1" ]]; then printf '%s' "$2"; else printf '%s.%s' "$2" "$1"; fi; }
