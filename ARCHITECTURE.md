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
| cred-daemon | creds | Daily re-mint, socket server, alerting publisher |
| ssh-agent | creds | Signs git/ssh challenges originating in sandbox |
| Git credential helper | creds | Vends GitHub HTTPS tokens to sandbox on socket request |
| gcloud / hcloud / wrangler token helpers | creds | Vend cloud tokens on socket request |
| Sandbox container | sandbox | Runs the agent + project work |
| ntfy publisher | creds | Pushes alerts to phone (free tier of ntfy.sh) |

## Daily re-mint flow

Cron at 04:00 in the creds zone, executed as `creds` user:

1. cred-daemon reads bootstrap secret from `/etc/agent-vps/infisical-uauth`
2. Authenticates to Infisical Universal Auth → receives short-lived access token
3. For each credential category, **re-mint upstream**:
   - **GitHub**: create new fine-grained PAT via GitHub API, store in Infisical + locally, revoke previous PAT
   - **GCP**: `gcloud iam service-accounts keys create` new key, store, then `keys delete` previous
   - **Cloudflare**: API token rotation via Cloudflare API, similar pattern
   - **Hetzner**: API token rotation via Hetzner Cloud API
   - **SSH key**: generate new keypair, push public key to GitHub via API, revoke old SSH key from GitHub
   - **npm / PyPI publish tokens** (static, no rotation API): re-fetch from Infisical only. *Residual: these don't truly rotate; revocation latency for them is bounded only by Infisical refresh, not upstream.*
4. Write derived values to `/var/lib/agent-vps/creds/<name>` (mode 0600, owner `creds:creds`)
5. Reload ssh-agent and credential helpers (they read from disk on each request, so usually a no-op signal)
6. Sandbox container does NOT need restart — next socket request to a helper vends the new value
7. On any failure: publish to ntfy topic

## Rebuild flow

Triggered when the VPS is destroyed/compromised/lost:

1. **Provision**: `hcloud server create` (or single shell script) creates a new CX22 with cloud-init from this repo
2. **Cloud-init installs**: Ubuntu LTS base, Tailscale, rootless Docker, cred-daemon source from this repo
3. **Paste #1 — Tailscale auth-key**: generated fresh from Tailscale admin UI (single-use, ≤24h TTL), pasted into the bootstrap script → `tailscale up`
4. **SSH in** from laptop via Tailscale
5. **Paste #2 — Infisical Universal Auth client secret**: written to `/etc/agent-vps/infisical-uauth` (0600 creds:creds)
6. **cred-daemon starts**, runs first refresh, populates `/var/lib/agent-vps/creds/`
7. **Sandbox container starts** (Docker pulls or builds image)
8. **`docker exec -it sandbox tmux new`** — get a shell inside the sandbox
9. **`claude login`** — interactive OAuth, browser flow on laptop, refresh token persists in `~/.claude/` inside sandbox
10. **`codex login`** — same
11. **tmux detach**, agent is ready

**Total manual touchpoints**: 2 pastes + 2 interactive OAuth logins ≈ 3 minutes if things work.

## File layout on VPS

```
/etc/agent-vps/
  infisical-uauth          0600  creds:creds   # bootstrap secret
  config.yaml              0644  root:root     # cred-daemon config (which creds, which upstream)

/var/lib/agent-vps/
  creds/                                       # raw key material — sandbox cannot see this
    github-pat             0600  creds:creds
    gcp-sa-key.json        0600  creds:creds
    cloudflare-token       0600  creds:creds
    hetzner-token          0600  creds:creds
    ssh-key                0600  creds:creds
    npm-token              0600  creds:creds
  sockets/                                     # mounted into sandbox
    ssh-agent.sock         0660  creds:creds
    git-helper.sock        0660  creds:creds

/srv/dev/projects/                merijn:merijn   # mounted rw into sandbox at /work

/opt/agent-vps/                   root:root      # cred-daemon source (read-only at runtime)
  daemon/                                       # systemd service unit + main loop
  refresh/                                      # per-credential re-mint scripts
  alerts/                                       # ntfy publisher
```

**Sandbox mounts (rootless Docker):**
- `/var/lib/agent-vps/sockets/` → `/run/sockets/` (rw on the sockets only)
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

- Does not prevent the agent from misusing credentials in-session once authenticated (§2 residual + §5 defense table: credential isolation is Partial against active misuse).
- Does not isolate projects from each other (§3 + §8: cross-project leakage residual is accepted).
- Does not filter outbound traffic from the sandbox (§5 + §8: parity with laptop).
- Does not gate any specific action (per-action approval, deploy approval, protected branches) — by design (§1 principle).
- Does not protect against a laptop compromise reaching the VPS over Tailscale (§2 out of scope).

These are explicit choices, not gaps.
