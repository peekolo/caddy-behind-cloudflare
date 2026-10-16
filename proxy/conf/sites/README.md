One file per project: `<project>.caddy`, owned by that project. Only `*.caddy` files are loaded.

- First line of each site block: `import cloudflare_origin <zone>` (Origin CA cert + drops non-Cloudflare traffic).
- Inside each `reverse_proxy` block: `import forward_client_ip` (one X-Forwarded-For address: the visitor).
- Upstream to your alias on the `proxy` network (`sh-web:3000`, `bl-api:8080`), never a bare service name.
- Snippets from the main Caddyfile: `import security_headers` or `import hsts_only`, `import access_log`.
  Snippets only one project needs belong in its own file (prefix the name, e.g. `(bl_no_internal)`).
- After an edit run `/srv/proxy/reload.sh`: it validates the whole config first and reloads without dropping
  connections. A file that fails validation is never applied; fix or remove it.
