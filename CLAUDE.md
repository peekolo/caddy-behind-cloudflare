# caddy-behind-cloudflare: deploy runbook for all projects

One way to put any project on a server, written for AI agents and humans alike. Every change is a script in `bin/`
with parameters. Each script checks before it changes anything, can be re-run safely, and has `--dry-run`. This file
says what to run, in what order, and what to check. **Do not improvise around a script: if one does not fit, fix the
script (and this file) first.**

Projects live on many servers. Do not assume the project you are working on shares a server with any other, or with this
workstation. The server list is in `hosts/`. Box hardening is a separate script, serverbeef, expected at `../serverbeef`
(prerequisite, section 3.2; not part of this repo: any hardening that gives key-only SSH on a non-standard port, ufw and
Docker will do).

## 0. Rules

1. **Secrets stay on the workstation.** `cloudflare.token` (scoped API token, mode 600, gitignored) is read only by
   `lib/common.sh`. Never print it, paste it, copy it to a server or put it in a project repo. A server never holds
   a credential that can change DNS.
2. **Orange cloud everywhere.** Every public hostname is proxied by Cloudflare (SSL "Full (strict)"). The origin IP
   is never published in DNS as grey/DNS-only, not even briefly (DNS history keeps it forever).
3. **One front door per server: the shared Caddy in `/srv/proxy`.** It is the only container that publishes host
   ports (80, 443). Projects never publish ports; they join the Docker network `proxy` (10.89.0.0/24) under a
   unique alias. This is true on individual servers too (section 8).
4. **Origin lock, twice.** The provider firewall admits 80/443 from Cloudflare only (Docker skips ufw), and Caddy
   drops any connection not from Cloudflare's ranges. A request that reaches an app came through Cloudflare.
5. **Two users.** The admin user (from serverbeef, has sudo, the owner's) does root steps only. Everything else
   runs as `deploy`: docker group, **no sudo**, owns `/srv/*`. Agents never have sudo; root steps are the owner's.
6. **Logs live 14 days at most** (journald, host-wide). Containers log to journald.
7. **Order that never breaks a live site:** certificate -> zone settings -> project up on `proxy` -> site file
   -> DNS -> verify. `bin/site-add` runs exactly that.
8. After any change: `bin/host-check <host>`, and update the host's row in the host table (section 2) if anything
   there changed.

## 1. How it fits together

```
visitor ─▶ Cloudflare edge (TLS, cache, floods) ─▶ provider firewall (80/443 from Cloudflare only)
        ─▶ /srv/proxy: caddy (Origin CA cert per zone, CF-Connecting-IP -> client_ip, drops non-Cloudflare)
        ─▶ network `proxy` 10.89.0.0/24 ─▶ <alias>:<port> of each project (its own compose project in /srv/<project>)
                                           databases etc. stay on the project's own networks, never on `proxy`
```

| Piece | Where | Owner |
|---|---|---|
| Proxy compose, main Caddyfile, snippets, Cloudflare ranges | `proxy/` here -> `/srv/proxy` (`bin/proxy-install`) | this repo |
| One site file per project | the project's repo (e.g. `deploy/proxy-site.caddy`) -> `/srv/proxy/conf/sites/<project>.caddy` (`bin/site-add`) | the project |
| Origin CA cert per zone (`<zone>`, `*.<zone>`, 15 years) | `/srv/proxy/certs/<zone>.pem` + `.key` (key made on the box, never leaves it) | `bin/site-add` |
| Zone settings + DNS | Cloudflare, via the API token | `bin/site-add` |
| Project stack | `/srv/<project>`, its own compose project | the project |

Upstream headers: Caddy sends `X-Forwarded-For` and `X-Real-IP` with **exactly one address, the visitor's**, and
`X-Forwarded-Proto: https`. Apps trust those from 10.89.0.0/24 only.

Cloudflare limits to design for: a proxied response that sends nothing for 100 s is cut (524), so long streams need
keep-alives and long work runs as jobs; request bodies max 100 MB (free plan); WebSockets and SSE pass through.

## 2. Hosts

One file per server in `hosts/<name>.env` (IP, ssh alias of `deploy`, type, projects, aliases). The scripts read it.
The ssh aliases must exist in `~/.ssh/config` of the machine that runs the scripts.

**Your real servers stay out of this repo.** `hosts/*.env` (except `hosts/example.env`) and `CLAUDE.local.md` are
gitignored: they hold IPs, which the orange cloud exists to hide, and admin user names. Keep the host table below in
`CLAUDE.local.md` (Claude Code loads it next to this file; other agents: read it if it exists). Example row:

| Host | Type | Provider | IP | ssh (deploy / admin) | Projects (alias on `proxy`) | State |
|---|---|---|---|---|---|---|
| myhost | shared | Vultr EWR, Ubuntu 26.04, 4 vCPU / 8 GB | 203.0.113.10 | `myhost_deploy` / `myhost` (`<admin>`) | shop (`sh-web:3000`), blog (`bl-web:8080`, `bl-api:8080`) | proxy up 2026-01-15; certs for example.com |

Aliases are unique per host. Pick `<2-3 letter project prefix>-<role>` (`sh-web`, `bl-api`) and add it to the host
table before you use it.

## 3. New server (once per server)

**3.1 Owner, at the provider.** Ubuntu 26.04 LTS x64, your SSH key. Pick this server's SSH port (any free port in
1025-9999 that apps don't use, e.g. `shuf -i 1025-9999 -n 1`; one per server, never a shared default). Attach a
**firewall group**, inbound IPv4: TCP 22 and `<ssh-port>` from anywhere (or your IP; drop 22 after 3.2), TCP 80 and 443
from source **Cloudflare** (Vultr has it as a source; elsewhere enter the IPv4 ranges from `proxy/cloudflare.env`),
nothing else. No IPv6 unless you plan for it (then AAAA records and the IPv6 ranges too).

**3.2 Owner, root: serverbeef.** `../serverbeef/serverbeef.sh` hardens the box (SSH on `<ssh-port>`, key-only, ufw,
fail2ban, unattended upgrades, swap, Docker). Run it with **your own admin name, never `deploy`** (its default),
because `deploy` must not get sudo:

```bash
scp ../serverbeef/serverbeef.sh root@<ip>:     # first login is root on port 22
ssh -t root@<ip> 'bash serverbeef.sh --user <admin> --ssh-port <ssh-port> --docker --udp-ports none'
# keep that session open; test `ssh -p <ssh-port> <admin>@<ip>` from a new terminal before closing it
```

**3.3 Owner, root: bootstrap.** journald 14 days, the `deploy` user (same SSH keys as the admin), `/srv/*`:

```bash
scp -P <ssh-port> bin/host-bootstrap.sh <admin>@<ip>:
ssh -t -p <ssh-port> <admin>@<ip> 'sudo bash host-bootstrap.sh --admin <admin> --projects "<project> <project>"'
```

Optional `--docker-journald` makes journald Docker's default log driver (restarts dockerd; containers stay up).

**3.4 Workstation (agent or human).** Add ssh aliases (`<host>` for the admin, `<host>_deploy` for deploy, both on
`<ssh-port>`; the port lives only there and in the firewall group, never in this repo), write `hosts/<host>.env` (copy
`hosts/example.env`), add the row to the host table (section 2), then:

```bash
bin/proxy-install <host>          # network `proxy`, /srv/proxy, caddy up (no sites yet)
bin/host-check <host>             # expect: only proxy-caddy-1 publishes ports, 80/443 closed to this machine
```

## 4. Add a project to a server

**4.1 Domain (owner, once per domain).** Add the domain to Cloudflare (Free plan is fine) and set its nameservers at
the registrar. The token covers every zone in the account, so nothing else is needed. Check: `bin/cf-zone <zone>`.

**4.2 The project's side (in its repo; the project's agent does this).**

- A compose overlay for this server (e.g. `docker-compose.shared-host.yml`), used last in `COMPOSE_FILE`:
  - **no host ports** on any service (`ports: !reset []`, Compose >= 2.24),
  - the public service(s) join the external network `proxy` with the alias from section 2; data services never do,
  - `mem_limit` / `cpus` per service (sum of limits on a host must leave ~1 GB for the page cache),
  - `logging: {driver: journald, options: {tag: "{{.Name}}"}}` on every service.

  ```yaml
  services:
    web:
      ports: !reset []
      networks:
        default:
        proxy:
          aliases: [sh-web]
      mem_limit: 64m
      cpus: 0.5
  networks:
    proxy:
      external: true
      name: proxy
  ```
- **Real client IP:** trust `X-Forwarded-For` / `X-Real-IP` / `X-Forwarded-Proto` from `10.89.0.0/24` only. The
  header holds one address. nginx: `set_real_ip_from 10.89.0.0/24; real_ip_header X-Forwarded-For;`.
  Frameworks: their trusted-proxy setting = `10.89.0.0/24`. Secure cookies need `X-Forwarded-Proto` passed through.
- **Site file** in the repo (`deploy/proxy-site.caddy`). Rules (`bin/site-add` refuses a file that breaks the first two):
  1. first line of every site block, redirects too: `import cloudflare_origin <zone>`
  2. every `reverse_proxy` has a block whose first line is `import forward_client_ip`
  3. upstream = your alias on `proxy`, never a bare service name (`web`, `api` exist in every project)
  4. snippets available: `security_headers` (or `hsts_only` if the app sets its own headers), `access_log`
     (journald, visitor IP, query strings cut, credentials redacted). A snippet of your own needs a project prefix
     (`(sh_something)`); snippet names are global on the host.

  ```caddyfile
  www.example.com {
  	import cloudflare_origin example.com
  	redir https://example.com{uri} permanent
  }

  example.com {
  	import cloudflare_origin example.com
  	import security_headers
  	import access_log
  	encode zstd gzip
  	reverse_proxy ex-web:3000 {
  		import forward_client_ip
  		health_uri /health
  		health_interval 15s
  	}
  }
  ```
- Checkout at `/srv/<project>` as `deploy` (read-only GitHub deploy key per repo). Prefer images built in CI and
  pulled (`docker compose pull`); a build on a shared box can OOM its neighbours.

**4.3 Certificate and zone settings (any time, even before the project runs).**

```bash
bin/site-add --host <host> --zone <zone> --only cert,settings [--bot-fight off]
```

Use `--bot-fight off` for zones that serve APIs, MCP, webhooks or other non-browser clients. If the zone has proxied
records pointing at other servers, the script stops: Full (strict) is zone-wide, so those origins need valid
certificates first (`--force-zone` once they do).

**4.4 Start the project** (its own procedure) and check its container is on `proxy`:
`ssh <host>_deploy "docker network inspect proxy -f '{{range .Containers}}{{.Name}} {{end}}'"`.

**4.5 Go live:**

```bash
bin/site-add --host <host> --zone <zone> --project <project> \
             --site-file /path/to/repo/deploy/proxy-site.caddy --names "@ www" --dry-run   # read the plan
bin/site-add --host <host> --zone <zone> --project <project> \
             --site-file /path/to/repo/deploy/proxy-site.caddy --names "@ www"
```

It installs the site file (validated; the previous one is restored if the proxy refuses it), points each name at the
host (proxied), and verifies: each name answers through Cloudflare, and the origin refuses a direct connection.
Then `bin/host-check <host>`, update section 2, and check the real client IP: a request made through Cloudflare must show
up in the app's own log with the visitor's address. `10.89.0.x` there means the app does not trust the proxy subnet
(section 4.2); fix that before handing the site over, because rate limits and abuse logs key on that address.

## 5. Day-2 operations

| Task | Command |
|---|---|
| State of a server | `bin/host-check <host>` |
| State of a zone | `bin/cf-zone <zone>` |
| Change a project's site file | edit it in the project repo, then `bin/site-add ... --only site,verify` |
| Change the proxy itself (Caddyfile, snippets, compose) | edit `proxy/` here, `bin/proxy-install <host>` on **every** host in section 2 |
| Cloudflare changed its IP ranges | `proxy/cloudflare-ips.sh` (writes `proxy/cloudflare.env`), then `bin/proxy-install <host>` per host; update the firewall group if it lists ranges by hand |
| Add a hostname to a project | add it to the site file, `bin/site-add ... --names "<new name>" --only site,dns,verify` |
| Take a project off a server | `bin/site-remove --host <host> --project <p> [--zone <z> --names "@ www"]`, then stop its stack |
| Move a project to another server | bring it up on the new host (section 4, `--only cert,settings,site`), copy data, then `--only dns,verify` there (DNS switches instantly behind Cloudflare), then `bin/site-remove` on the old host |
| Certificates | Origin CA certs last 15 years; `site-add` renews one with < 30 days left. Cloudflare must not be grey for the zone while it uses them |

The site file on the box is a copy. Change it in the project repo and re-run `site-add`, never on the box: the next
`site-add` would overwrite a hand edit. Old versions are kept in `/srv/proxy/sites-backup/`.

## 6. Troubleshooting

| Symptom | Meaning | Look at |
|---|---|---|
| 521 | Cloudflare reached the IP, nothing accepted | proxy down (`bin/host-check`), or Caddy dropped the source (Cloudflare ranges outdated?) |
| 522 | Cloudflare timed out | firewall group does not admit Cloudflare on 443 |
| 525 / 526 | TLS to origin failed | no site file for that name, or cert missing / wrong zone in `import cloudflare_origin` |
| 502 | proxy fine, app not reachable | project not up, or not on `proxy` with that alias |
| 524 | app silent for 100 s | make it stream keep-alives or run the work as a job |
| reload refused | a site file is invalid | `ssh <host>_deploy /srv/proxy/reload.sh` prints the file and line; one broken file blocks every reload on the host |
| app logs one IP for everyone | app does not trust 10.89.0.0/24, or reads the wrong header | section 4.2 |

Logs: `ssh <host>_deploy 'cd /srv/proxy && docker compose logs --since 10m caddy'`; access lines carry
`request.client_ip` (visitor) and `request.remote_ip` (Cloudflare edge).

## 7. Files here

```
CLAUDE.md (= AGENTS.md)   this runbook (README.md: overview for people, LICENSE: MIT)
cloudflare.token          scoped Cloudflare API token (secret, mode 600, gitignored)
lib/common.sh             shared helpers: host records, ssh, Cloudflare API (token handling)
bin/host-bootstrap.sh     ROOT, on the box: journald 14 d, deploy user, /srv folders          (section 3.3)
bin/proxy-install         workstation: install/update /srv/proxy on a host                    (3.4, 5)
bin/site-add              workstation: cert, zone settings, site file, DNS, verify            (4.3, 4.5)
bin/site-remove           workstation: site file off, optional DNS records removed            (5)
bin/host-check            workstation: read-only server status                                (everywhere)
bin/cf-zone               workstation: read-only Cloudflare zone status
proxy/                    the files of /srv/proxy (compose.yaml, conf/Caddyfile, reload.sh, cloudflare.env ...)
hosts/<name>.env          one per server (gitignored; hosts/example.env is the template)
CLAUDE.local.md           your host table (gitignored)
```

Cloudflare token permissions (Custom token, zone resources "All zones from an account"): Zone Read, DNS Edit, Zone
Settings Edit, SSL and Certificates Edit, Bot Management Edit. It cannot create or delete zones or touch billing.
Provider firewalls stay manual by design: provider API keys (Vultr's, for one) cannot be scoped, and a key that
can change firewalls can also delete servers.

## 8. Individual servers

An individual server is the same recipe with one project: serverbeef, `host-bootstrap.sh`, `proxy-install`,
`site-add`. Keeping the shared proxy even for one project means a second project can join later without touching
the first, a project can move between shared and individual servers by changing DNS only, and every server is
operated with the same commands. Mark it `TYPE=individual` in `hosts/<name>.env`. A project that needs something the
proxy cannot do (raw TCP, UDP, its own TLS termination) is the exception: write it down here before building it.

## 9. Open items

- A provider without a firewall in front of the box: Docker-published ports skip ufw, so 80/443 would need
  `DOCKER-USER` iptables rules limited to Cloudflare. Not built yet; no such server exists.
- Authenticated Origin Pulls (mTLS from Cloudflare) would also stop traffic sent through someone else's Cloudflare
  account. Not on yet; the IP lock plus Host/SNI matching covers the practical cases.
