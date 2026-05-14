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
   │  │  cred-daemon  ssh-agent  ntfy publisher         │  │
   │  │  /etc/agent-vps/infisical-uauth      (0600)     │  │
   │  │  /var/lib/agent-vps/creds/github-ssh-key (0600) │  │
   │  │  /var/lib/agent-vps/creds/ntfy-topic     (0600) │  │
   │  └─────────────────┬────────────────────────────────┘ │
   │                    │ ssh-agent socket bridge          │
   │                    ▼  (raw key material does NOT      │
   │                       cross this boundary)            │
   │  ┌─ SANDBOX ZONE (rootless Docker container) ──────┐  │
   │  │  Claude Code, Codex (OAuth), tmux               │  │
   │  │  Node+pnpm, Python+uv                           │  │
   │  │  PATH shims (/opt/agent-vps-wrappers/) for      │  │
   │  │    hcloud, wrangler, gcloud, supabase           │  │
   │  │  /work  ←  mounted from /srv/dev/projects       │  │
   │  └────────────────────┬─────────────────────────────┘ │
   └────────┬──────────────┼─────────────────┬─────────────┘
            │              │                 │
       HTTPS│         HTTPS│            HTTPS│ (unrestricted egress)
            ▼              ▼                 ▼
   Infisical               Infisical    GitHub · GCP · Cloudflare · Hetzner
   (coding-agent-vps       (coding-agent npm · pypi · Anthropic · OpenAI · …
    project — host-side     -vps-tooling
    creds, daily fetch by   + per-app
    cred-daemon)            projects —
                            sandbox fetches
                            per-command via
                            `infisical run --`)
```

## Hetzner project topology

The agent VPS lives in its **own dedicated Hetzner Cloud project** (e.g. `coding-agent-vps`), separate from any project where the user actually deploys apps. Two distinct Hetzner API tokens:

| Token | Scope | Where it lives | What it can do |
|---|---|---|---|
| **Admin token** for `coding-agent-vps` project | full admin on the agent-vps project (this VPS, its firewall, its volumes) | Laptop only — kept in password manager, never enters the VPS | Provision/destroy the VPS, attach firewall, killswitch backstop |
| **Agent token** for user's apps project(s) | full access within those projects only | Stored in the `coding-agent-vps-tooling` Infisical project. Fetched per-command by the `hcloud` PATH shim in the sandbox via `infisical run --`; never persists on the VPS at rest. | Deploy and manage app resources for the user's actual workloads |

Cross-project isolation is at the Hetzner API level: the agent's Hetzner token doesn't have any permissions in the `coding-agent-vps` Hetzner project — even a fully compromised agent cannot list, modify, or delete the agent-vps VPS itself.

**Scaling pattern**: if a future project needs an isolated VPS (per REQUIREMENTS.md §3), it gets its own Hetzner project. Each VPS lives behind its own admin-token boundary.

## Trust zones

Three zones on the VPS, three trust levels.

### Host zone (root)

- **Owns**: Tailscale daemon, Docker engine, base OS, systemd
- **Active surface**: minimal after setup; only Tailscale and Docker accept inputs
- **Trust**: high but quiet — does not handle credentials

### Creds zone (user `creds`)

- **Owns**: cred-daemon (systemd service), Infisical Universal Auth bootstrap secret, ssh-agent process, ntfy publisher
- **Holds**: the GitHub SSH private key (loaded into ssh-agent) and the ntfy topic (read by the alert script). That's it — other cloud-CLI tokens never enter this zone.
- **Talks to outside**: HTTPS to the `coding-agent-vps` Infisical project (to refresh `github-ssh-key` and `ntfy-topic`), plus HTTPS to `ntfy.sh` from the alert script on cred-daemon failures. Does not call upstream APIs for credential lifecycle management — that's the user's responsibility per REQUIREMENTS.md §5.
- **Talks to sandbox**: only via the bridged ssh-agent unix socket — a signing oracle, never raw key material.
- **Trust**: highest — holds the raw GitHub SSH key.

### Sandbox zone (rootless Docker container)

- **Owns**: Claude Code, Codex, project working files, language runtimes, PATH shims for cloud CLIs (hcloud, wrangler, gcloud, supabase), tmux.
- **Talks to outside**:
  - Unrestricted HTTPS egress (per REQUIREMENTS.md §5 — matches laptop parity).
  - HTTPS to Infisical for the `coding-agent-vps-tooling` project (account-wide cloud-CLI tokens) and per-app projects (project-specific app secrets). One fetch per CLI invocation, via `infisical run --`. Tokens enter the subprocess environment for the duration of one command, never persist on disk inside the sandbox.
- **Talks to creds zone**: only via the bridged ssh-agent socket.
- **Cannot reach**: host zone files, creds zone files (`/etc/agent-vps`, `/var/lib/agent-vps/creds`), `/opt/agent-vps`.
- **Trust**: lowest — agent runs in YOLO mode here. Token exposure is bounded to one subprocess's lifetime.

## Components

| Component | Zone | Role |
|---|---|---|
| Tailscale daemon | host | Ingress (Tailscale-only, deny-all ACL) + outbound mesh |
| Docker engine | host | Container runtime, configured for rootless |
| cred-daemon | creds | Fetches host-side credentials (`github-ssh-key`, `ntfy-topic`) from the `coding-agent-vps` Infisical project. Runs at host boot, daily via systemd timer, and on manual `systemctl start`. Loads `github-ssh-key` into ssh-agent and writes `ntfy-topic` for the alert script. Alerts on failure. |
| ssh-agent | creds | Signs git/ssh challenges originating in sandbox (true signing oracle — private key never leaves creds zone) |
| PATH shims | sandbox | One executable per cloud CLI at `/opt/agent-vps-wrappers/` (first in `$PATH`). Wraps the real binary in `infisical run -- ...` so the secret lands in the subprocess env for one command. See "Per-CLI integration" below. |
| Sandbox container | sandbox | Runs the agent + project work |
| ntfy publisher | creds | Pushes alerts to phone (free tier of ntfy.sh) |

## Firewall & IPv6

Ingress is blocked at three deny-by-default layers, configured during cloud-init in this order. Each layer's deny rules apply to **both IPv4 and IPv6**:

1. **Hetzner Cloud firewall** — pre-created (e.g. `agent-vps-deny-all`, with explicit deny-all rules for both v4 and v6) and attached to the VPS **at server-creation time** via `hcloud server create --firewall ...`. Denies all public-internet inbound before the VPS first boots — no exposure window during cloud-init.
2. **`ufw` on the VPS** — `ufw default deny incoming` covers both v4 and v6 with one setting; defense in depth (Hetzner firewall + host firewall together).
3. **Tailscale ACL** — deny-by-default. Explicit allow: laptop → VPS (SSH and any other tailnet-only services). **NO rule allowing VPS → laptop in any direction** — a compromised VPS cannot reach laptop tailnet services (local dev servers, ssh-agent, etc.).

**IPv6 stays enabled** on the VPS (kernel and interface level). Disabling at the kernel was rejected because it causes silent failures for any service that binds to `::` and breaks IPv6-preferring DNS fallback for package mirrors. The security property we care about — "no public ingress" — is enforced at the firewall layers above, regardless of protocol.

Egress is unrestricted from the sandbox (per REQUIREMENTS.md §5 — laptop parity).

**Sandbox dev-server ports are exempt by design.** `docker-compose.yml` publishes a few port ranges (3000-3009, 5170-5179, 8000-8089) bound to `127.0.0.1` on the VPS host. They sit on the loopback interface, not on `eth0` or `tailscale0`, so the three deny layers above don't see them and don't need to — the only path that can reach them is SSH port forwarding from a Tailscale-authenticated laptop session, which is already the access model. See [USAGE.md "Exposing a sandbox dev server"](./USAGE.md#exposing-a-sandbox-dev-server).

## Per-CLI integration

Two patterns, picked per credential.

### Host-routed (ssh-agent only)

`git` over SSH uses `SSH_AUTH_SOCK` pointing at the ssh-agent bridge socket. The agent runs in the creds zone with `github-ssh-key` loaded by cred-daemon. The sandbox sees signing-oracle behavior — the private key never crosses the zone boundary. This is the strongest credential pattern in the system.

### Sandbox-fetched, per-command (everything else)

The sandbox has PATH shims at `/opt/agent-vps-wrappers/` (first in `$PATH`) for every cloud CLI that needs an account-wide token: `hcloud`, `wrangler`, `gcloud`, `supabase`. Each shim does roughly:

```bash
exec infisical run \
    --projectId "$INFISICAL_TOOLING_PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    -- <real-binary-abspath> "$@"
```

`infisical run --` exports each fetched secret as an env var with the **same name** as the secret in Infisical — so the secrets are stored under the env-var names the CLIs already read (uppercase, underscores). The token lands in the subprocess environment for the duration of one command, then gone. No persistent on-disk copy inside the sandbox. PATH shims (not shell functions) so every caller is wrapped — interactive shells, the agent's own `subprocess.Popen`, cron, `bash -c '...'`, all of them.

| CLI | Real binary path | Secret name in `coding-agent-vps-tooling` | Receives via |
|---|---|---|---|
| `hcloud` | `/usr/local/bin/hcloud` | `HCLOUD_TOKEN` | env var, set by `infisical run --` |
| `wrangler` | `/usr/local/pnpm/bin/wrangler` | `CLOUDFLARE_API_TOKEN` | env var, set by `infisical run --` |
| `supabase` | `/usr/local/bin/supabase` | `SUPABASE_ACCESS_TOKEN` | env var, set by `infisical run --` |
| `gcloud` | `/usr/bin/gcloud` | `GCP_SA_KEY_JSON` (the JSON content as a single secret value) | Shim writes `$GCP_SA_KEY_JSON` to `/dev/shm/<random>` (tmpfs, mode 0600), exports `GOOGLE_APPLICATION_CREDENTIALS` pointing at it, runs gcloud, deletes the temp on `EXIT`/`HUP`/`INT`/`TERM`. The gcloud shim wraps the `infisical run --` invocation with the file dance — not vanilla `infisical run`. |

Authentication to Infisical from the sandbox is interactive: `infisical login` once per container (device-code OAuth flow). The resulting session token lives at `~/.infisical/login/` inside the container, which is ephemeral by container-state policy — gone on rebuild, requires re-login. This is the friction we accept in exchange for not persisting any tooling secrets on the VPS at rest.

### Per-app projects

App-specific secrets (database URLs, anon keys, app-scoped API tokens) live in a per-app Infisical project (e.g. `dobudex`). In the project directory under `/work`, agents invoke commands via `infisical run --env=dev -- <cmd>`, which auto-detects the project from `.infisical.json` (committed to the repo) or from `infisical init`. Same trust model as the tooling project — secret in subprocess env for one command, never on disk.

(npm / PyPI / Docker Hub publishing not scaffolded in v1. The pattern for any added integration: secret in the `coding-agent-vps-tooling` Infisical project, plus a new shim at `/opt/agent-vps-wrappers/<cli>` that does `infisical run -- <real-binary-abspath> "$@"`.)

## Refresh flow

Two parallel paths — one for host-side credentials, one for sandbox-side.

### Host-side: cred-daemon (creds zone)

systemd timer (`cred-daemon.timer`, `OnCalendar=04:00 UTC` daily, `Persistent=true`), runs as `creds`. Also at host boot (`WantedBy=multi-user.target`) and on demand (`systemctl start cred-daemon`). The daemon's scope is just two credentials, both legitimately host-side:

1. Reads bootstrap secret from `/etc/agent-vps/infisical-uauth`.
2. Authenticates to the `coding-agent-vps` Infisical project via Universal Auth.
3. Fetches `github-ssh-key` and `ntfy-topic`.
4. `github-ssh-key`: validates with `ssh-keygen -y`, then `ssh-add -D` + `ssh-add <new>` against the creds-owned agent. The next signing request from the sandbox (via the bridged socket) sees the new key — no sandbox restart needed.
5. `ntfy-topic`: written to `/var/lib/agent-vps/creds/ntfy-topic` (mode 0600). The alert script reads it on each invocation.
6. On Infisical authentication or fetch failure: publish to ntfy topic.

The cred-daemon does **not** mint, rotate, or otherwise call any upstream service's API. All credential lifecycle management at the upstream is the user's responsibility — see REQUIREMENTS.md §5. The cred-daemon's job is "keep the local host-side cache in sync with Infisical."

### Sandbox-side: per-command via `infisical run --`

For every cloud CLI invocation (`hcloud`, `wrangler`, `gcloud`, `supabase`, and any per-app secret consumption), the relevant Infisical project is hit at command-time:

1. Shell calls `hcloud server list`. PATH resolves to `/opt/agent-vps-wrappers/hcloud`.
2. The shim execs `infisical run --projectId $INFISICAL_TOOLING_PROJECT_ID --env=dev -- /usr/local/bin/hcloud server list`.
3. `infisical run` fetches the secret named `HCLOUD_TOKEN` from the `coding-agent-vps-tooling` project, sets it as an env var of the same name in the child process, execs the real hcloud.
4. Real hcloud reads `HCLOUD_TOKEN`, makes its API call, exits.
5. Child process gone, env gone, no on-disk trace.

Rotation is immediate: change the value in Infisical → next CLI invocation picks it up. No daemon timer, no sandbox restart, no "stale env in running shell" footgun (since the env is only set per-subprocess, not in any persistent shell).

## Rebuild flow

**Scope note**: this is the *full VPS rebuild* flow (destroy server → recreate). For container-only refresh (`docker compose up -d --build` after a Dockerfile change), the named volumes `sandbox-state-claude` and `sandbox-state-codex` persist, so OAuth tokens survive — no OAuth re-login needed. The tmux session is killed on container recreate because tmux runs as a process inside the container. Full VPS rebuild loses all volumes (no backups in v1 — see REQUIREMENTS.md §6) and requires re-OAuth.

Triggered when the VPS is destroyed/compromised/lost. Runs from the laptop using the admin token for the `coding-agent-vps` Hetzner project (kept in laptop's password manager; never enters the VPS).

1. **Generate fresh Tailscale auth-key** from Tailscale admin UI (single-use, ≤24h TTL).
2. **Provision** (against the `coding-agent-vps` Hetzner project): `hcloud server create --firewall=agent-vps-deny-all ...` (firewall pre-created with v4+v6 deny-all inbound rules, attached at server-creation — no exposure window) with cloud-init user-data containing the Tailscale auth-key and the resolved clone URL (HTTPS for public repos, SSH-with-deploy-key for private). Cloud-init runs on first boot: installs Ubuntu LTS, Tailscale, rootless Docker (incl. buildx), enables ufw (`ufw default deny incoming` covers both v4 and v6), clones the configured `GH_REPO` (auto-detected from the local `origin` remote at provision time) into `/opt/agent-vps/`, builds the sandbox image with `docker build` from the repo's `sandbox/Dockerfile`, then runs `tailscale up --authkey=...`. Secrets Hetzner sees in user-data: the ephemeral Tailscale auth-key (single-use, short TTL) and — for private repos only — a read-only single-repo deploy key. Both acceptable since Hetzner is in §2's trusted-dependency set.
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
  infisical-uauth          0600  creds:creds   # bootstrap secret for `coding-agent-vps` project (client id+secret)
  config.env               0644  root:root     # cred-daemon config (project ID, env slug, URL)

/var/lib/agent-vps/
  creds/                                       # raw key material — sandbox cannot see this
    github-ssh-key         0600  creds:creds   # loaded into ssh-agent at refresh
    ntfy-topic             0600  creds:creds   # only the alert script reads this
  agent-config/                                # bind-mounted into the sandbox
    env/
      sandbox-config.sh                     0644  creds:creds  # `export INFISICAL_TOOLING_PROJECT_ID=…` + `INFISICAL_ENV=…` for the shims
  sockets/                                     # mounted into sandbox; 0755 dir, 0666 socket files
    ssh-agent.sock         0666  creds:creds   # raw ssh-agent — cred-daemon uses this directly
    ssh-agent-bridge.sock  0666  creds:creds   # socat relay — sandbox uses this (UID-namespace bridge)

/srv/dev/projects/                dev:dev   # mounted rw into sandbox at /work

/opt/agent-vps/                   root:root      # cloned from the configured GH_REPO at cloud-init time
  daemon/                                       # cred-daemon, ssh-agent-creds, ssh-agent-bridge units
  alerts/                                       # ntfy publisher (best-effort; logs to journal regardless)
  scripts/                                      # provision.sh (laptop), cloud-init-tasks.sh, bootstrap.sh
  sandbox/
    Dockerfile                                  # built on the VPS via `docker build` at cloud-init time
    entrypoint.sh                               # container entrypoint: sets SSH_AUTH_SOCK + exec tmux
    profile.d-agent-env.sh                      # sourced by interactive shells inside the container
    wrappers/                                   # PATH shims (hcloud, wrangler, gcloud, supabase) baked into image
```

**Inside the sandbox container:**
```
/opt/agent-vps-wrappers/         # first in $PATH
  hcloud, wrangler, gcloud, supabase            # executable shims; exec `infisical run -- <real-binary>`
/usr/local/bin/hcloud, /usr/local/bin/supabase  # real binaries (NOT first in $PATH for the wrapped tools)
/usr/local/pnpm/bin/wrangler                    # real binary
/usr/bin/gcloud                                 # real binary (apt-installed)
```

**Named Docker volumes** (host-side path varies by Docker storage driver; persist across container recreation):
- `sandbox-state-claude` → `/home/agent/.claude` (Claude Code OAuth refresh tokens + project state)
- `sandbox-state-codex` → `/home/agent/.codex` (Codex OAuth refresh tokens)
- `sandbox-state` → `/home/agent/.local/state/agent-state` (reserved for future agent-state persistence; currently no writes)

**Sandbox mounts (rootless Docker):**
- `/var/lib/agent-vps/sockets/` → `/run/sockets/` (socket mode 0666; the sandbox connects to `ssh-agent-bridge.sock`, not the raw `ssh-agent.sock` — see daemon/ssh-agent-bridge.service for why)
- `/var/lib/agent-vps/agent-config/env/` → `/run/agent-env/` (read-only; `/etc/profile.d/agent-env.sh` sources `*.sh` on shell start, picking up `INFISICAL_TOOLING_PROJECT_ID` + `INFISICAL_ENV` for the PATH shims)
- Named volumes (above) for `~/.claude`, `~/.codex`, `~/.local/state/agent-state`
- `/srv/dev/projects/` → `/work` (rw)

**Sandbox does NOT mount:** anything under `/etc/agent-vps/`, `/var/lib/agent-vps/creds/`, or `/opt/agent-vps/`. The Infisical Universal Auth bootstrap secret stays in the creds zone exclusively.

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
- Does not provide unattended sandbox-side cloud-CLI access. The sandbox needs an `infisical login` (interactive device-code OAuth) once per container, expiring with container rebuild. Cron jobs / background tasks inside the sandbox that need cloud APIs will fail until a human re-logs in. Trade for not persisting any tooling secret on the VPS at rest.
- Does not isolate the `coding-agent-vps-tooling` and per-app Infisical projects from each other inside the sandbox: a single human Infisical identity sees both. The scope split is for blast-radius and rotation cadence, not within-sandbox isolation.

These are explicit choices, not gaps.
