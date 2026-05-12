# Architecture — Secure Agent VPS

Concrete component layout and data flows for the system specified in [REQUIREMENTS.md](./REQUIREMENTS.md).

## Overview

```
   ┌─ Laptop (you) ──────────────────────┐
   │  Tailscale | Browser (for OAuth)    │
   └─────────────────┬───────────────────┘
                     │ Tailscale only (no public ingress)
   ┌─────────────────▼─────────────────────────────────────┐
   │  VPS — Hetzner CX22                                   │
   │                                                       │
   │  ┌─ HOST ZONE (root) ──────────────────────────────┐  │
   │  │  Tailscale daemon | Docker (rootless) | OS      │  │
   │  └──────────────────────────────────────────────────┘ │
   │                                                       │
   │  ┌─ CREDS ZONE (user: creds) ──────────────────────┐  │
   │  │  cred-daemon  ssh-agent  credential helpers     │  │
   │  │  /etc/agent-vps/infisical-uauth      (0600)     │  │
   │  │  /var/lib/agent-vps/creds/*          (0600)     │  │
   │  └─────────────────┬────────────────────────────────┘ │
   │                    │ unix sockets only                │
   │                    ▼  (raw key material does NOT      │
   │                       cross this boundary)            │
   │  ┌─ SANDBOX ZONE (rootless Docker container) ──────┐  │
   │  │  Claude Code, Codex (OAuth), tmux               │  │
   │  │  Node+pnpm, Python+uv                           │  │
   │  │  wrangler, gcloud, hcloud                       │  │
   │  │  /work  ←  mounted from /srv/dev/projects       │  │
   │  └──────────────────────────────────────────────────┘ │
   └────────┬──────────────────────────┬───────────────────┘
            │                          │
            │ HTTPS                    │ HTTPS (unrestricted egress)
            ▼                          ▼
       Infisical                  GitHub · GCP · Cloudflare · Hetzner
       (daily re-mint)            npm · pypi · Anthropic · OpenAI · …
```

## Trust zones

Three zones on the VPS, three trust levels.

### Host zone (root)

- **Owns**: Tailscale daemon, Docker engine, base OS, systemd
- **Active surface**: minimal after setup; only Tailscale and Docker accept inputs
- **Trust**: high but quiet — does not handle credentials

### Creds zone (user `creds`)

- **Owns**: cred-daemon (systemd service), Infisical Universal Auth bootstrap secret, daily-refreshed derived secrets, ssh-agent process, credential-helper sockets
- **Talks to outside**: HTTPS to Infisical and each upstream API (GitHub, GCP, Cloudflare, Hetzner) for re-mint
- **Talks to sandbox**: only via unix sockets that vend signatures/tokens on demand — never raw key material
- **Trust**: highest — holds everything sensitive

### Sandbox zone (rootless Docker container)

- **Owns**: Claude Code, Codex, project working files, language runtimes, deploy CLIs, tmux
- **Talks to outside**: unrestricted HTTPS egress (per §5 — matches laptop parity)
- **Talks to creds zone**: only via mounted sockets (ssh-agent + credential helpers)
- **Cannot reach**: host zone files, creds zone files, /etc/agent-vps, /var/lib/agent-vps/creds, /opt/agent-vps
- **Trust**: lowest — agent runs in YOLO mode here

## Components

| Component | Zone | Role |
|---|---|---|
| Tailscale daemon | host | Ingress (Tailscale-only, deny-all ACL) + outbound mesh |
| Docker engine | host | Container runtime, configured for rootless |
| cred-daemon | creds | Fetches credentials from Infisical (daily + on sandbox start), runs socket server, publishes alerts |
| ssh-agent | creds | Signs git/ssh challenges originating in sandbox (true signing oracle — private key never leaves creds zone) |
| Per-CLI credential shims | creds | Bespoke per upstream CLI; see "Per-CLI integration" below |
| Sandbox container | sandbox | Runs the agent + project work |
| ntfy publisher | creds | Pushes alerts to phone (free tier of ntfy.sh) |

## Firewall & IPv6

Ingress is blocked at three deny-by-default layers, configured during cloud-init in this order:

1. **Hetzner Cloud firewall** attached to the VPS — denies all public-internet inbound IPv4.
2. **`ufw` on the VPS** — same deny-all-inbound rule on the box itself; defense in depth (Hetzner firewall + host firewall together).
3. **Tailscale ACL** — deny-by-default, then explicit allow rules for tags applied to my own tailnet nodes.

**IPv6 is disabled** entirely on the VPS:
- Cloud-init: `hcloud server create --without-ipv6`
- Kernel sysctl: `net.ipv6.conf.all.disable_ipv6 = 1`, `net.ipv6.conf.default.disable_ipv6 = 1`
- No ip6tables / ufw v6 rules to maintain
- All outbound dependencies (GitHub, GCP, Cloudflare, Hetzner, npm, pypi, Anthropic, OpenAI, Infisical, Tailscale) support IPv4

Egress is unrestricted from the sandbox (per REQUIREMENTS.md §5 — laptop parity).

## Per-CLI integration

There is no single "credential socket protocol." Each non-SSH CLI consumes credentials from a different place. The cred-daemon writes the appropriate config file or env-export from Infisical-fetched values:

| CLI | Where it reads creds | What cred-daemon writes |
|---|---|---|
| `git` (SSH) | `SSH_AUTH_SOCK` | ssh-agent socket — signing oracle, no raw key in sandbox |
| `gcloud` | `~/.config/gcloud/application_default_credentials.json` | the SA key JSON (file) |
| `wrangler` | `CLOUDFLARE_API_TOKEN` env var | env-export script the agent sources at startup |
| `hcloud` | `HCLOUD_TOKEN` env var | env-export script |
| `npm` (publish) | `~/.npmrc` `_authToken` | per-registry auth line (config file) |

All of these except SSH put the raw bearer token somewhere the sandbox process can read at use-time. SSH via ssh-agent is the only true signing oracle (private key never enters the sandbox). For `git` operations we use SSH only; the agent does not have `gh` or any other GitHub API tooling in-sandbox — those operations happen from the laptop instead.

## Daily refresh flow

Cron at 04:00 in the creds zone, executed as `creds` user. Also triggered on sandbox container startup.

1. cred-daemon reads bootstrap secret from `/etc/agent-vps/infisical-uauth`
2. Authenticates to Infisical Universal Auth → receives short-lived access token
3. Fetches current credential values from Infisical for each entry the daemon manages
4. For each value that changed since last refresh: write to `/var/lib/agent-vps/creds/<name>` (mode 0600, owner `creds:creds`), reload the corresponding helper (e.g. `ssh-add -d <old>` + `ssh-add <new>` for SSH keys)
5. Sandbox container does NOT need restart — next socket request to a helper vends the current value
6. On Infisical authentication or fetch failure: publish to ntfy topic

The cred-daemon does **not** mint, rotate, or otherwise call any upstream service's API. All credential lifecycle management at the upstream (GitHub, GCP, Cloudflare, Hetzner, npm, etc.) is the user's responsibility — see REQUIREMENTS.md §5. The cred-daemon's job is "keep the local cache in sync with Infisical."

## Rebuild flow

Triggered when the VPS is destroyed/compromised/lost:

1. **Generate fresh Tailscale auth-key** from Tailscale admin UI (single-use, ≤24h TTL).
2. **Provision**: `hcloud server create --without-ipv6 ...` with cloud-init user-data containing the Tailscale auth-key. Cloud-init runs on first boot: installs Ubuntu LTS, Tailscale, rootless Docker, cred-daemon source, applies the Hetzner Cloud firewall, configures ufw + IPv6-disable sysctls, then runs `tailscale up --authkey=...`. Hetzner sees the ephemeral key, which is acceptable — single-use + short TTL + Hetzner is in §2's trusted-dependency set.
3. **SSH in** from laptop via Tailscale.
4. **Paste — Infisical Universal Auth client secret** into `/etc/agent-vps/infisical-uauth` (0600 creds:creds).
5. **cred-daemon starts**, runs first fetch, populates `/var/lib/agent-vps/creds/`.
6. **Sandbox container starts**. The named volume `agent-state` is created (if first-ever rebuild) or attached (if reusing previous state).
7. **`docker exec -it sandbox tmux new`** — get a shell inside the sandbox.
8. **`claude login`** + **`codex login`** — only required on first-ever bootstrap or if the named volume was wiped. On subsequent rebuilds, refresh tokens persist in the named volume and the agents are already authenticated.
9. **tmux detach**, agent is ready.

**Manual touchpoints**: 1 paste (Infisical secret) + (first time only) 2 interactive OAuth logins. Roughly 2 minutes if the named volume survives; 3–4 minutes if first-ever bootstrap.

## File layout on VPS

```
/etc/agent-vps/
  infisical-uauth          0600  creds:creds   # bootstrap secret
  config.yaml              0644  root:root     # cred-daemon config (which creds, which upstream)

/var/lib/agent-vps/
  creds/                                       # raw key material — sandbox cannot see this
    gcp-sa-key.json        0600  creds:creds
    cloudflare-token       0600  creds:creds
    hetzner-token          0600  creds:creds
    ssh-key                0600  creds:creds
    npm-token              0600  creds:creds
  sockets/                                     # mounted into sandbox; group-shared for rootless Docker subgid mapping
    ssh-agent.sock         0660  creds:agent-sockets
    git-helper.sock        0660  creds:agent-sockets
  sandbox-state/                               # named Docker volume — persists across container/image refresh
    home-claude/                               # /home/agent/.claude (OAuth refresh tokens)
    home-codex/                                # /home/agent/.codex (OAuth refresh tokens)
    tmux/                                      # tmux socket + state

/srv/dev/projects/                merijn:merijn   # mounted rw into sandbox at /work

/opt/agent-vps/                   root:root      # cred-daemon source (read-only at runtime)
  daemon/                                       # systemd service unit + main loop (fetch from Infisical, serve sockets)
  integrations/                                 # per-CLI integration shims (write ADC file / env exports / config files)
  alerts/                                       # ntfy publisher
```

**Sandbox mounts (rootless Docker):**
- `/var/lib/agent-vps/sockets/` → `/run/sockets/` (the sandbox container's user is mapped via subgid to GID `agent-sockets` so it can `connect()` to the sockets, but cannot `unlink()` files in the dir)
- `/var/lib/agent-vps/sandbox-state/` → `/home/agent/` and `/tmp/tmux-*` (named volume, rw, survives image refresh — preserves OAuth tokens and tmux session state)
- `/srv/dev/projects/` → `/work` (rw)

**Sandbox does NOT mount:** anything under `/etc/agent-vps/`, `/var/lib/agent-vps/creds/`, or `/opt/agent-vps/`.

## Alerting

ntfy.sh free tier. cred-daemon publishes to a private topic; phone subscribes via the ntfy app.

Events that trigger an alert:

- Infisical refresh failure (any reason)
- Upstream re-mint failure (any of GitHub / GCP / Cloudflare / Hetzner)
- Production deploy detected (poll GCP/Cloudflare audit logs in cred-daemon's cron)
- LLM rate-limit hit (tail Claude/Codex stderr for known error patterns)

No alerting infrastructure beyond a ~20-line shell script using `curl` to publish to ntfy.

## Decisions still open at architecture level

These are architecture-adjacent choices the design works with regardless. Decide at implementation time:

- **OS**: Ubuntu LTS (default — recommend for v1) vs NixOS (declarative rebuilds, more involved).
- **cred-daemon language**: shell + jq (most transparent), Python (most maintainable), Go (single binary). Recommend shell + jq for v1.
- **VPS provisioning**: hcloud CLI + bash script (recommend) vs Terraform (overkill for one box).
- **Image update mechanism**: watchtower with a fixed window (e.g. 03:00, before 04:00 refresh) vs manual pulls.
- **Production deploy detection for alerting**: poll cloud audit logs (recommend) vs webhook ingest (requires a public endpoint).

## What this architecture does NOT do

Tracking back to REQUIREMENTS.md residuals and non-goals:

- Does not mint, rotate, or otherwise manage upstream credentials. That is the user's responsibility — setting TTLs at each service where supported and manually updating values in Infisical (§5).
- Does not prevent the agent from misusing credentials in-session once authenticated (§2 residual + §5 defense table: credential isolation is Partial against active misuse).
- Does not isolate projects from each other (§3 + §8: cross-project leakage residual is accepted).
- Does not filter outbound traffic from the sandbox (§5 + §8: parity with laptop).
- Does not gate any specific action (per-action approval, deploy approval, protected branches) — by design (§1 principle).
- Does not protect against a laptop compromise reaching the VPS over Tailscale (§2 out of scope).
- Does not provide GitHub API access from the sandbox (no `gh` CLI, no PAT). Git operations use SSH only (signing oracle, no bearer token in sandbox); PR creation, issues, and CI status happen from the laptop.

These are explicit choices, not gaps.
