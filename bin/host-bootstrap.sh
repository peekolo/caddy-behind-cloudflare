#!/usr/bin/env bash
# host-bootstrap.sh: the one-time ROOT steps that turn a serverbeef'd Ubuntu box into a caddy-behind-cloudflare host.
# Runs ON the box, as root. Idempotent: safe to re-run (it only adds what is missing).
#
#   scp -P <ssh-port> bin/host-bootstrap.sh <admin>@<ip>:   (or: scp bin/host-bootstrap.sh <admin-ssh-alias>:)
#   ssh -t <admin-ssh-alias> 'sudo bash host-bootstrap.sh'                # asks the questions below
#   ssh -t <admin-ssh-alias> 'sudo bash host-bootstrap.sh --admin <admin> [--projects "app1 app2"] [--docker-journald]'
#
# Without options it asks for the admin user (default: who ran sudo), the projects to create now (optional:
# bin/project-add creates them later) and the journald log driver, then shows a summary and waits for a yes.
#
# Prerequisite: ../serverbeef/serverbeef.sh already ran on this box with `--docker` (SSH on its
# own port, ufw, fail2ban, unattended upgrades, swap, and rootless Docker running as `deploy`: the root daemon is off
# and nobody is in the docker group, so nothing an agent does through Docker can reach root). This script does NOT
# repeat any of that. It adds:
#   1. journald: no log entry older than 14 days (overrides serverbeef's 1 month), one file per day
#   2. checks the `deploy` user serverbeef made: ssh-users group, its own key (never the admin's), NO sudo, NO docker group
#   3. /srv owned by deploy (so bin/project-add can add projects later without root), /srv/proxy and
#      /srv/<project> per --projects, group-writable (setgid)
#   4. optional --docker-journald: journald as the default log driver of deploy's daemon (restarts it; containers
#      with a restart policy come back)
set -Eeuo pipefail

ADMIN="" PROJECTS="" DOCKER_JOURNALD=0 NARGS=$#
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin) ADMIN=$2; shift 2 ;;
    --projects) PROJECTS=$2; shift 2 ;;       # optional: bin/project-add creates /srv/<project> too
    --docker-journald) DOCKER_JOURNALD=1; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run as root (sudo bash $0 ...)" >&2; exit 1; }

valid_admin() { [[ -n "$1" && "$1" != root && "$1" != deploy ]] && id "$1" >/dev/null 2>&1; }
valid_projects() { local p; for p in $1; do [[ "$p" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1; done; }
if [[ $NARGS -eq 0 ]]; then
  # No options: ask. Prompts read from /dev/tty so the answers never come from a pipe.
  { : < /dev/tty; } 2>/dev/null || { echo "no options and no terminal: pass --admin <user> (see --help)" >&2; exit 1; }
  ask() { local __ans; read -r -p "  $2 [${3:-none}]: " __ans < /dev/tty || { echo; echo "no answer: nothing changed"; exit 1; }; printf -v "$1" '%s' "${__ans:-$3}"; }
  guess=${SUDO_USER:-}; valid_admin "$guess" || guess=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -vxE 'root|deploy|' | head -1)
  echo "host-bootstrap: the root steps that make this box a caddy-behind-cloudflare host. Enter keeps the default."
  until valid_admin "$ADMIN"; do
    [[ -z "$ADMIN" ]] || echo "    $ADMIN is not an existing user other than root and deploy"
    ask ADMIN "Admin user (the sudo user from serverbeef)" "$guess"
  done
  while :; do
    ask PROJECTS "Projects to create under /srv now, space separated (bin/project-add can add them later)" ""
    valid_projects "$PROJECTS" && break; echo "    names are lowercase letters, digits and dashes"
  done
  j=""; ask j "journald as the default log driver of deploy's Docker (restarts it)? y/n" y
  [[ "$j" =~ ^[Yy] ]] && DOCKER_JOURNALD=1 || DOCKER_JOURNALD=0
  echo; echo "  Admin user ........ $ADMIN (joins the deploy group for shared files; deploy keeps its own key, no sudo)"
  echo "  Projects .......... ${PROJECTS:-none now}"
  echo "  Docker logs ....... $([[ $DOCKER_JOURNALD == 1 ]] && echo journald || echo unchanged)"
  echo "  Also: journald keeps 14 days, /srv is handed to deploy"
  go=""; ask go "Proceed? y/n" y; [[ "$go" =~ ^[Yy] ]] || { echo "nothing changed"; exit 1; }
  echo
fi
valid_admin "$ADMIN" || { echo "--admin <existing sudo user other than root and deploy> is required" >&2; exit 1; }
valid_projects "$PROJECTS" || { echo "--projects: names are lowercase letters, digits and dashes" >&2; exit 1; }
getent group ssh-users >/dev/null || { echo "group ssh-users missing: run serverbeef.sh first" >&2; exit 1; }
id deploy >/dev/null 2>&1 || { echo "user deploy is missing: run serverbeef.sh with --docker first" >&2; exit 1; }
DEPLOY_UID=$(id -u deploy)
DEPLOY_HOME=$(getent passwd deploy | cut -d: -f6)
[[ -S "/run/user/$DEPLOY_UID/docker.sock" ]] \
  || { echo "deploy has no rootless Docker daemon: run serverbeef.sh with --docker" >&2; exit 1; }
# run a command as deploy, with what its systemd user instance and Docker need
as_deploy() {
  runuser -u deploy -- env HOME="$DEPLOY_HOME" USER=deploy LOGNAME=deploy XDG_RUNTIME_DIR="/run/user/$DEPLOY_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DEPLOY_UID/bus" DOCKER_HOST="unix:///run/user/$DEPLOY_UID/docker.sock" "$@"
}

echo "== 1. journald: 14 days at most"
cat > /etc/systemd/journald.conf.d/95-aideploy-retention.conf <<'CONF'
# caddy-behind-cloudflare: no entry older than 14 days (a new file per day, whole files dropped after 13 days).
# Sorts after serverbeef's 90-serverbeef.conf, so it overrides its MaxRetentionSec; SystemMaxUse there still applies.
[Journal]
Storage=persistent
MaxFileSec=1day
MaxRetentionSec=13day
CONF
# an older copy of the same rule, written by hand before this script existed
[[ -f /etc/systemd/journald.conf.d/95-retention-14d.conf ]] && rm -f /etc/systemd/journald.conf.d/95-retention-14d.conf
systemctl restart systemd-journald
journalctl --vacuum-time=13d >/dev/null 2>&1 || true
systemd-analyze cat-config systemd/journald.conf | grep -E '^MaxRetentionSec' | tail -1

echo "== 2. deploy user"
usermod -aG ssh-users deploy
# the docker group is root on a root daemon; deploy never gets it (an older bootstrap added it)
if id -nG deploy | tr ' ' '\n' | grep -qx docker; then gpasswd -d deploy docker >/dev/null; fi
usermod -aG deploy "$ADMIN"
# deploy logs in with its own key (serverbeef --deploy-key, made by serverbeef-local.sh), never the admin's:
# an agent holding the deploy key must not be able to log in as the admin, and the other way round.
if [[ ! -s "$DEPLOY_HOME/.ssh/authorized_keys" ]]; then
  echo "WARNING: deploy has no SSH key; nothing can deploy yet. Add one: sudo serverbeef --deploy-key '<public key>'" >&2
fi
if sudo -l -U deploy 2>/dev/null | grep -q '(ALL'; then echo "WARNING: deploy has sudo rights; it should not" >&2; fi
if systemctl is-active --quiet docker; then echo "WARNING: the root Docker daemon is running; serverbeef --docker turns it off" >&2; fi
id deploy
if as_deploy docker info --format '{{.ServerVersion}} {{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  echo "  rootless Docker $(as_deploy docker version --format '{{.Server.Version}}') runs as deploy"
else
  echo "deploy's rootless Docker daemon is not answering: sudo -iu deploy systemctl --user status serverbeef-docker" >&2; exit 1
fi

echo "== 3. /srv folders"
install -d -m 2775 -o deploy -g deploy /srv
for d in proxy $PROJECTS backups; do
  install -d -m 2775 -o deploy -g deploy "/srv/$d"
done
ls -la /srv

if [[ $DOCKER_JOURNALD == 1 ]]; then
  echo "== 4. deploy's Docker: default log driver -> journald"
  as_deploy python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.config/docker/daemon.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
d = json.load(open(p)) if os.path.exists(p) else {}
d["log-driver"] = "journald"; d.pop("log-opts", None)
json.dump(d, open(p, "w"), indent=2); print(open(p).read())
PY
  as_deploy systemctl --user restart serverbeef-docker.service
  sleep 3
  as_deploy docker ps --format '{{.Names}} {{.Status}}'
fi

echo
echo "Done. Next, from the workstation: bin/proxy-install <host>."
