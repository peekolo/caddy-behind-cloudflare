#!/usr/bin/env bash
# host-bootstrap.sh: the one-time ROOT steps that turn a serverbeef'd Ubuntu box into a caddy-behind-cloudflare host.
# Runs ON the box, as root. Idempotent: safe to re-run (it only adds what is missing).
#
#   scp -P <ssh-port> bin/host-bootstrap.sh <admin>@<ip>:   (or: scp bin/host-bootstrap.sh <admin-ssh-alias>:)
#   ssh -t <admin-ssh-alias> 'sudo bash host-bootstrap.sh --admin <admin> --projects "app1 app2"'
#
# Prerequisite: ../serverbeef/serverbeef.sh already ran on this box with --docker (SSH on its own port, ufw, fail2ban,
# unattended upgrades, swap, Docker). This script does NOT repeat any of that. It adds:
#   1. journald: no log entry older than 14 days (overrides serverbeef's 1 month), one file per day
#   2. the `deploy` user: docker + ssh-users groups, NO sudo, same SSH keys as the admin
#   3. /srv/proxy and /srv/<project> per project, owned by deploy, group-writable (setgid)
#   4. optional --docker-journald: Docker's default log driver -> journald (restarts dockerd; live-restore keeps
#      containers running)
set -Eeuo pipefail

ADMIN="" PROJECTS="" DOCKER_JOURNALD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin) ADMIN=$2; shift 2 ;;
    --projects) PROJECTS=$2; shift 2 ;;
    --docker-journald) DOCKER_JOURNALD=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run as root (sudo bash $0 ...)" >&2; exit 1; }
[[ -n "$ADMIN" ]] && id "$ADMIN" >/dev/null 2>&1 || { echo "--admin <existing sudo user> is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is missing: run serverbeef.sh with --docker first" >&2; exit 1; }
getent group ssh-users >/dev/null || { echo "group ssh-users missing: run serverbeef.sh first" >&2; exit 1; }

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
id deploy >/dev/null 2>&1 || adduser --disabled-password --gecos "" deploy
usermod -aG docker,ssh-users deploy
usermod -aG deploy "$ADMIN"
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
admin_home=$(getent passwd "$ADMIN" | cut -d: -f6)
if [[ -s "$admin_home/.ssh/authorized_keys" ]]; then
  touch /home/deploy/.ssh/authorized_keys
  sort -u "$admin_home/.ssh/authorized_keys" /home/deploy/.ssh/authorized_keys -o /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys; chmod 600 /home/deploy/.ssh/authorized_keys
fi
if sudo -l -U deploy 2>/dev/null | grep -q '(ALL'; then echo "WARNING: deploy has sudo rights; it should not" >&2; fi
id deploy

echo "== 3. /srv folders"
for d in proxy $PROJECTS backups; do
  install -d -m 2775 -o deploy -g deploy "/srv/$d"
done
ls -la /srv

if [[ $DOCKER_JOURNALD == 1 ]]; then
  echo "== 4. Docker default log driver -> journald"
  python3 - <<'PY'
import json, os
p = "/etc/docker/daemon.json"
d = json.load(open(p)) if os.path.exists(p) else {}
d["log-driver"] = "journald"; d.pop("log-opts", None); d["live-restore"] = True
json.dump(d, open(p, "w"), indent=2); print(open(p).read())
PY
  systemctl restart docker && docker ps --format '{{.Names}} {{.Status}}'
fi

echo
echo "Done. deploy's gid is $(id -g deploy) (DEPLOY_GID in /srv/proxy/.env). Next, from the workstation: bin/proxy-install <host>."
