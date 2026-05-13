# Architecture — Coding Agent VPS

Concrete component layout and data flows for the system specified in [REQUIREMENTS.md](./REQUIREMENTS.md).

## Overview

```
   ┌─ Laptop (you) ──────────────────────┐
   │  Tailscale | Browser (for OAuth)    │
   └─────────────────┬───────────────────┘
                     │ Tailscale only (no public ingress)
   ┌─────────────────▼─────────────────────────────────────┐
   │  VPS — Hetzner CX23                                   │
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
       (daily fetch)              npm · pypi · Anthropic · OpenAI · …
```

## Hetzner project topology

The agent VPS lives in its **own dedicated Hetzner Cloud project** (e.g. `coding-agent-vps`), separate from any project where the user actually deploys apps. Two distinct Hetzner API tokens:

| Token | Scope | Where it lives | What it can do |
|---|---|---|---|
| **Admin token** for `coding-agent-vps` project | full admin on the agent-vps project (this VPS, its firewall, its volumes) | Laptop only — kept in password manager, never enters the VPS | Provision/destroy the VPS, attach firewall, killswitch backstop |
| **Agent token** for user's apps project(s) | full access within those projects only | Stored in Infisical, fetched by cred-daemon, mounted into sandbox as `HCLOUD_TOKEN` | Deploy and manage app resources for the user's actual workloads |

Cross-project isolation is at the Hetzner API level: the agent's `HCLOUD_TOKEN` doesn't have any permissions in the `coding-agent-vps` project — even a fully compromised agent cannot list, modify, or delete the agent-vps VPS itself.

**Scaling pattern**: if a future project needs an isolated VPS (per REQUIREMENTS.md §3), it gets its own Hetzner project. Each VPS lives behind its own admin-token boundary.

## Trust zones

Three zones on the VPS, three trust levels.

### Host zone (root)

- **Owns**: Tailscale daemon, Docker engine, base OS, systemd
- **Active surface**: minimal after setup; only Tailscale and Docker accept inputs
- **Trust**: high but quiet — does not handle credentials

### Creds zone (user `creds`)

- **Owns**: cred-daemon (systemd service), Infisical Universal Auth bootstrap secret, daily-refreshed derived secrets, ssh-agent process, credential-helper sockets
- **Talks to outside**: HTTPS to Infisical only (to fetch credential values). Does not call upstream APIs — credential lifecycle at the upstream is the user's responsibility per REQUIREMENTS.md §5.
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

Ingress is blocked at three deny-by-default layers, configured during cloud-init in this order. Each layer's deny rules apply to **both IPv4 and IPv6**:

1. **Hetzner Cloud firewall** — pre-created (e.g. `agent-vps-deny-all`, with explicit deny-all rules for both v4 and v6) and attached to the VPS **at server-creation time** via `hcloud server create --firewall ...`. Denies all public-internet inbound before the VPS first boots — no exposure window during cloud-init.
2. **`ufw` on the VPS** — `ufw default deny incoming` covers both v4 and v6 with one setting; defense in depth (Hetzner firewall + host firewall together).
3. **Tailscale ACL** — deny-by-default. Explicit allow: laptop → VPS (SSH and any other tailnet-only services). **NO rule allowing VPS → laptop in any direction** — a compromised VPS cannot reach laptop tailnet services (local dev servers, ssh-agent, etc.).

**IPv6 stays enabled** on the VPS (kernel and interface level). Disabling at the kernel was rejected because it causes silent failures for any service that binds to `::` and breaks IPv6-preferring DNS fallback for package mirrors. The security property we care about — "no public ingress" — is enforced at the firewall layers above, regardless of protocol.

Egress is unrestricted from the sandbox (per REQUIREMENTS.md §5 — laptop parity).

## Per-CLI integration

There is no single "credential socket protocol." Each non-SSH CLI consumes credentials from a different place. The cred-daemon writes the appropriate config file or env-export from Infisical-fetched values:

| CLI | Where it reads creds | What cred-daemon writes |
|---|---|---|
| `git` (SSH) | `SSH_AUTH_SOCK` | ssh-agent socket — signing oracle, no raw key in sandbox |
| `gcloud` | `~/.config/gcloud/application_default_credentials.json` | daemon writes to `/var/lib/agent-vps/agent-config/gcloud/application_default_credentials.json`; bind-mounted read-only into sandbox at the expected path |
| `wrangler` | `CLOUDFLARE_API_TOKEN` env var | daemon writes `/var/lib/agent-vps/agent-config/env/cloudflare.sh`; container entrypoint sources it on shell start. Footgun: running shells keep stale value until re-source (see Daily refresh flow step 5) |
| `hcloud` | `HCLOUD_TOKEN` env var (apps-only scope, no VPS-management) | daemon writes `/var/lib/agent-vps/agent-config/env/hetzner.sh`; same sourcing pattern as wrangler |
| `npm` (publish) | `~/.npmrc` `_authToken` | daemon writes `/var/lib/agent-vps/agent-config/npm/npmrc`; bind-mounted read-only into sandbox as `~/.npmrc` |

All of these except SSH put the raw bearer token somewhere the sandbox process can read at use-time. SSH via ssh-agent is the only true signing oracle (private key never enters the sandbox). For `git` operations we use SSH only; the agent does not have `gh` or any other GitHub API tooling in-sandbox — those operations happen from the laptop instead.

## Daily refresh flow

Cron at 04:00 in the creds zone, executed as `creds` user. Also triggered on sandbox container startup.

1. cred-daemon reads bootstrap secret from `/etc/agent-vps/infisical-uauth`
2. Authenticates to Infisical Universal Auth → receives short-lived access token
3. Fetches current credential values from Infisical for each entry the daemon manages
4. For each value that changed since last refresh: write to `/var/lib/agent-vps/creds/<name>` (mode 0600, owner `creds:creds`), reload the corresponding helper (e.g. `ssh-add -d <old>` + `ssh-add <new>` for SSH keys)
5. Propagation to the sandbox depends on the credential type:
   - **SSH** (socket-served): next signing request sees the new key — no restart needed.
   - **gcloud ADC, `~/.npmrc`** (file-read at each use): next CLI invocation reads the new value — no restart needed.
   - **`CLOUDFLARE_API_TOKEN`, `HCLOUD_TOKEN`** (env vars sourced at shell start): running tmux sessions keep stale values until the shell re-sources its env-export or is restarted. Document this as a known footgun; users should `exec $SHELL` or detach/reattach tmux after a known rotation.
6. On Infisical authentication or fetch failure: publish to ntfy topic

The cred-daemon does **not** mint, rotate, or otherwise call any upstream service's API. All credential lifecycle management at the upstream (GitHub, GCP, Cloudflare, Hetzner, npm, etc.) is the user's responsibility — see REQUIREMENTS.md §5. The cred-daemon's job is "keep the local cache in sync with Infisical."

## Rebuild flow

**Scope note**: this is the *full VPS rebuild* flow (destroy server → recreate). For container-only refresh (`docker compose up -d --build` after a Dockerfile change), the named volumes `sandbox-state-claude` and `sandbox-state-codex` persist, so OAuth tokens survive — no OAuth re-login needed. The tmux session is killed on container recreate because tmux runs as a process inside the container. Full VPS rebuild loses all volumes (no backups in v1 — see REQUIREMENTS.md §6) and requires re-OAuth.

Triggered when the VPS is destroyed/compromised/lost. Runs from the laptop using the admin token for the `coding-agent-vps` Hetzner project (kept in laptop's password manager; never enters the VPS).

1. **Generate fresh Tailscale auth-key** from Tailscale admin UI (single-use, ≤24h TTL).
2. **Provision** (against the `coding-agent-vps` Hetzner project): `hcloud server create --firewall=agent-vps-deny-all ...` (firewall pre-created with v4+v6 deny-all inbound rules, attached at server-creation — no exposure window) with cloud-init user-data containing the Tailscale auth-key AND a read-only deploy key for the repo. Cloud-init runs on first boot: installs Ubuntu LTS, Tailscale, rootless Docker (incl. buildx), enables ufw (`ufw default deny incoming` covers both v4 and v6), clones the configured `GH_REPO` (auto-detected from the local `origin` remote at provision time) into `/opt/agent-vps/`, builds the sandbox image with `docker build` from the repo's `sandbox/Dockerfile`, then runs `tailscale up --authkey=...`. Hetzner sees the ephemeral Tailscale key and the deploy key — both acceptable: single-use / short-TTL / read-only-on-one-repo, and Hetzner is in §2's trusted-dependency set.
3. **SSH in** from laptop via Tailscale.
4. **Paste — Infisical Universal Auth client secret** into `/etc/agent-vps/infisical-uauth` (0600 creds:creds).
5. **cred-daemon starts**, runs first fetch, populates `/var/lib/agent-vps/creds/`.
6. **Sandbox container starts**. The named volumes `sandbox-state-claude` and `sandbox-state-codex` are created (if first-ever bootstrap) or attached (if reusing previous state — the case after a container rebuild that doesn't destroy the VPS).
7. **`docker exec -it sandbox tmux attach -t main`** — attach to the sandbox's tmux session (the container's entrypoint runs `tmux new -A -s main`).
8. **`claude login`** + **`codex login`** — only required on first-ever bootstrap or if the named volumes were wiped (i.e., full VPS rebuild). On container rebuilds, refresh tokens persist in the named volumes and the agents are already authenticated.
9. **tmux detach**, agent is ready.

**Manual touchpoints**: 1 paste (Infisical Universal Auth client ID + client secret) + (first time only) 2 interactive OAuth logins. Roughly 2 minutes if the named volumes survive; 3–4 minutes if first-ever bootstrap.

## File layout on VPS

```
/etc/agent-vps/
  infisical-uauth          0600  creds:creds   # bootstrap secret (client id+secret)
  config.env               0644  root:root     # cred-daemon config (project ID, env slug, URL)

/var/lib/agent-vps/
  creds/                                       # raw key material — sandbox cannot see this
    github-ssh-key         0600  creds:creds   # loaded into ssh-agent at refresh
    ntfy-topic             0600  creds:creds   # only the alert script reads this
  agent-config/                                # per-CLI config files; bind-mounted read-only into the sandbox
    gcloud/
      application_default_credentials.json  0644  creds:creds  # → /home/agent/.config/gcloud/...
    npm/
      npmrc                                 0644  creds:creds  # → /home/agent/.npmrc
    env/
      cloudflare.sh                         0644  creds:creds  # sourced by entrypoint → CLOUDFLARE_API_TOKEN
      hetzner.sh                            0644  creds:creds  # sourced by entrypoint → HCLOUD_TOKEN (apps-only)
      pypi.sh                               0644  creds:creds  # sourced by entrypoint → UV_PUBLISH_TOKEN, TWINE_*
  sockets/                                     # mounted into sandbox; 0755 dir, 0666 socket files
    ssh-agent.sock         0666  creds:creds   # raw ssh-agent — cred-daemon uses this directly
    ssh-agent-bridge.sock  0666  creds:creds   # socat relay — sandbox uses this (UID-namespace bridge)

/srv/dev/projects/                merijn:merijn   # mounted rw into sandbox at /work

/opt/agent-vps/                   root:root      # cloned from the configured GH_REPO at cloud-init time
  daemon/                                       # cred-daemon, ssh-agent-creds, ssh-agent-bridge units
  alerts/                                       # ntfy publisher (best-effort; logs to journal regardless)
  scripts/                                      # provision.sh (laptop), cloud-init-tasks.sh, bootstrap.sh
  sandbox/
    Dockerfile                                  # built on the VPS via `docker build` at cloud-init time
    entrypoint.sh                               # container entrypoint: sets SSH_AUTH_SOCK + exec tmux
    profile.d-agent-env.sh                      # sourced by interactive shells inside the container
```

**Named Docker volumes** (host-side path varies by Docker storage driver; persist across container recreation):
- `sandbox-state-claude` → `/home/agent/.claude` (Claude Code OAuth refresh tokens + project state)
- `sandbox-state-codex` → `/home/agent/.codex` (Codex OAuth refresh tokens)
- `sandbox-state` → `/home/agent/.local/state/agent-state` (reserved for future agent-state persistence; currently no writes)

**Sandbox mounts (rootless Docker):**
- `/var/lib/agent-vps/sockets/` → `/run/sockets/` (socket mode 0666; the sandbox connects to `ssh-agent-bridge.sock`, not the raw `ssh-agent.sock` — see daemon/ssh-agent-bridge.service for why)
- `/var/lib/agent-vps/agent-config/gcloud/` → `/home/agent/.config/gcloud/` (read-only)
- `/var/lib/agent-vps/agent-config/npm/npmrc` → `/home/agent/.npmrc` (read-only)
- `/var/lib/agent-vps/agent-config/env/` → `/run/agent-env/` (read-only; `/etc/profile.d/agent-env.sh` sources `*.sh` on shell start to set env-var creds)
- Named volumes (above) for `~/.claude`, `~/.codex`, `~/.local/state/agent-state`
- `/srv/dev/projects/` → `/work` (rw)

**Sandbox does NOT mount:** anything under `/etc/agent-vps/`, `/var/lib/agent-vps/creds/`, or `/opt/agent-vps/`.

## Alerting

ntfy.sh free tier. cred-daemon calls a tiny ~20-line shell script (`alerts/ntfy.sh`) that always logs to stderr (captured by systemd journal) and additionally publishes to a private ntfy topic *if* `ntfy-topic` was populated in Infisical.

Events that currently trigger an alert (all from `cred-daemon.sh`):

- Infisical fetch / auth failure (revoked identity, network down, malformed API response)
- Invalid `github-ssh-key` material in Infisical (fails `ssh-keygen -y -P ''` validation; the previous key stays loaded)
- `ssh-add` failure after key validation passed

Without `ntfy-topic` configured, alerts only go to the journal (`journalctl -u cred-daemon.service`) — no push notifications, but the audit trail is preserved.

## Decisions still open at architecture level

These are architecture-adjacent choices the design works with regardless. Decide at implementation time:

- **OS**: Ubuntu LTS (default — recommend for v1) vs NixOS (declarative rebuilds, more involved).
- **cred-daemon language**: shell + jq (most transparent), Python (most maintainable), Go (single binary). Recommend shell + jq for v1.
- **VPS provisioning**: hcloud CLI + bash script (recommend) vs Terraform (overkill for one box).
- **Image update cadence**: image is built on the VPS from the repo's Dockerfile (no registry). Rebuilds are user-triggered after Dockerfile changes (`git pull && docker build && docker compose up -d`). Could also be a daily cron pulling `main` and rebuilding if you want auto-updates. Watchtower doesn't apply since we don't pull from a registry.
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
