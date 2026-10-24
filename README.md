# caddy-behind-cloudflare

**Put your apps on the internet the safe way, with your AI doing the work.**

You built an app with AI. Now you want it online at your own domain, without learning how servers work and
without leaving the door open for attackers. This repo is a step-by-step playbook your AI assistant follows to do
exactly that, on a cheap server you rent.

## What you get

- **Your app at your own domain**, with HTTPS (the padlock) set up for you.
- **Protection from [Cloudflare](https://www.cloudflare.com/plans/free/)**, free: it blocks attacks and floods of fake
  traffic before they reach your server, and your server's real address stays hidden.
- **Many apps on one server.** Add your second and third app to the same server, so you pay for one machine.
- **A locked-down server**: no passwords to guess, a firewall, automatic security updates.
- **Safe for AI to run.** Every step checks before it changes anything, can show what it would do first, and can
  be repeated without breaking things. The AI never gets administrator rights on your server, and the server
  never holds the key to your domain.

## What you need

| | Cost |
|---|---|
| An AI coding assistant that can run commands, such as [Claude Code](https://claude.com/claude-code) | your existing plan |
| A server (a "VPS") with Ubuntu 26.04, for example from [Vultr](https://www.vultr.com/) | a few dollars a month |
| A domain name, for example `myapp.com` | about $10 a year |
| A [Cloudflare account](https://dash.cloudflare.com/sign-up) | free |
| Your app, packaged with Docker (your AI can do this) | free |

## Start here

1. **Download this repo** and the server hardening script it uses,
   [serverbeef](https://github.com/peekolo/serverbeef), into the same folder:

   ```bash
   git clone https://github.com/peekolo/caddy-behind-cloudflare.git
   git clone https://github.com/peekolo/serverbeef.git
   ```

2. **Open your AI assistant in the `caddy-behind-cloudflare` folder** and tell it:

   > Read CLAUDE.md and help me put my app online. My app is in `<folder of your app>` and my domain is
   > `<your domain>`. Walk me through every step I need to do myself.

That's it. The AI reads the playbook ([CLAUDE.md](CLAUDE.md), also available as `AGENTS.md`) and guides you. A few
steps need you, because they involve your accounts and passwords:

- creating the server at your provider and setting its firewall,
- adding your domain to Cloudflare ([how](https://developers.cloudflare.com/fundamentals/manage-domains/add-site/)),
- creating a Cloudflare API token ([how](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/))
  and saving it in a file called `cloudflare.token` in this folder (the AI tells you which permissions),
- running two setup commands on the new server as its administrator. The AI gives you the exact commands to paste.

Everything else (installing the web server, certificates, connecting your domain, checking that it all works) the
AI does with the scripts in this repo.

---

## How it works

The rest of this page is for the technically curious.

Shell scripts and a runbook for hosting several Docker Compose projects on a few small servers, all behind
Cloudflare. They were written so that an AI coding agent can run deployments safely, and they work just as well for
a person at a terminal.

Each server gets one shared Caddy reverse proxy. Projects never open ports of their own; they join a Docker network
and Caddy routes to them. Every public hostname is proxied by Cloudflare, and the server only accepts web traffic
from Cloudflare's IP ranges, so its real IP is never needed by visitors and is never in DNS.

```
visitor ─▶ Cloudflare ─▶ provider firewall (80/443 from Cloudflare only)
        ─▶ Caddy in ~/srv/proxy, run by deploy (drops anything not from Cloudflare)
        ─▶ Docker network "proxy" ─▶ your project's container, by alias
```

### What the scripts do

All of them run from your workstation over SSH as the unprivileged `deploy` user; none needs root. Each one checks
the current state before changing anything, can be re-run, and takes `--dry-run`.

| Script | Does |
|---|---|
| `bin/proxy-install <host>` | Installs or updates the shared Caddy in `~/srv/proxy` |
| `bin/project-add <host> <project>` | Puts a project on a server as `deploy`: a read-only deploy key for its repo (made on the server, you add the public key at GitHub), the checkout in `~/srv/<project>`, its `.env`, a check that the compose overlay publishes no ports and joins the proxy network, then `compose up`, or the project's own release script when its repo has an `aideploy.env` (a stack in a subdirectory, a deploy script with migrations and rollback). Run again to deploy an update |
| `bin/site-add` | Puts a domain live: Cloudflare Origin CA certificate (key generated on the server), zone settings (Full strict SSL, HTTPS only, TLS 1.2+), the project's Caddy site file (validated, rolled back if Caddy rejects it), proxied DNS records, then checks that the site answers through Cloudflare and that the origin refuses direct connections |
| `bin/site-remove` | Takes a site off a server, and optionally its DNS records |
| `bin/host-check <host>` | Read-only server status: proxy health, drift from this repo, certificates, published ports, log retention |
| `bin/cf-zone <zone>` | Read-only Cloudflare zone status: DNS records, settings, certificates |

### Design choices

- The Cloudflare API token stays on the workstation, and no server holds a credential that can change DNS. The token
  is scoped to DNS, zone settings, SSL and bot settings; it cannot delete zones or touch billing.
- Each server has two users: an admin whose sudo asks for a password only the owner knows, for the few root
  steps, and `deploy` (its own rootless Docker daemon, no sudo, no docker group) for everything else. An agent
  only ever gets `deploy`, and nothing it does through Docker can reach root.
- Going live always follows the same order: certificate, zone settings, project running, site file, DNS, verify.
  DNS changes last, so a visitor never reaches a name the server cannot answer yet.
- Caddy sends the app exactly one client IP in `X-Forwarded-For` and `X-Real-IP`, taken from Cloudflare's
  `CF-Connecting-IP`. Apps trust those headers from the proxy subnet `10.89.0.0/24` only.
- A server with only one project still runs the shared proxy, so every server is set up the same way and a project
  can move between servers with a DNS change.

### Requirements

- Ubuntu 26.04 servers with rootless Docker running as `deploy`, key-only SSH on a port of your choosing (one per
  server), and separate keys for the admin and for `deploy`. The runbook uses a separate hardening script
  (serverbeef, with its workstation helper `serverbeef-local.sh`) for this; any equivalent setup works.
- A provider firewall in front of each server that can restrict 80/443 to Cloudflare: the layer that does not
  depend on the box being intact.
- Domains on Cloudflare (the Free plan is fine) and a custom API token with Zone Read, DNS Edit, Zone Settings Edit,
  SSL and Certificates Edit, and Bot Management Edit.
- On the workstation: bash, ssh, scp, rsync, curl, jq, openssl and dig.

### Getting started (manual)

1. Put your Cloudflare token in `cloudflare.token` (mode 600, gitignored), or export `CF_API_TOKEN`.
2. Prepare the server (sections 3.1 and 3.2 of the runbook): provider firewall, then serverbeef, which also writes
   the `<name>` and `<name>_deploy` ssh aliases. Root is never needed after that.
3. Copy `hosts/example.env` to `hosts/<name>.env` and fill it in.
4. `bin/proxy-install <name>`, then `bin/host-check <name>`.
5. For each project: add a compose overlay that joins the `proxy` network and a Caddy site file to the project's
   repo, run `bin/project-add <name> <project> --repo <owner>/<repo>`, then `bin/site-add` with `--dry-run` first
   (runbook section 4).

The full procedure, with the rules for site files, troubleshooting by Cloudflare error code and day-2 tasks, is in
[CLAUDE.md](CLAUDE.md) (also available as `AGENTS.md`). It is written as instructions for an agent, and people can
follow it too.

### Keeping your servers private

The origin lock only helps while your servers' IPs stay private. Your host records (`hosts/*.env` other than the
example) and your own host table (`CLAUDE.local.md`) are gitignored for that reason. Keep it that way if you fork
this into a public repo.

### Not covered yet

- Servers with no provider firewall. Rootless Docker's ports obey ufw, so ufw rules limited to Cloudflare's ranges
  would do; not built.
- Authenticated Origin Pulls (mTLS between Cloudflare and the origin).
- IPv6.

## License

MIT, see [LICENSE](LICENSE).
