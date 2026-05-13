# Coding Agent VPS — Goals & Requirements

> Working document. Captures **what** we want and **why**. Decisions about **how** to build it live elsewhere.

## 1. Background & motivation

I run AI coding CLIs (Claude Code, Codex) routinely in `--dangerously-skip-permissions` / `--yolo` mode on my laptop because per-action approval prompts ruin the workflow. The 2025–2026 npm supply chain wave (Shai-Hulud 1.0/2.0, mini Shai-Hulud, Bitwarden CLI compromise) demonstrated that this posture means a single poisoned dependency can harvest GitHub/npm/AWS/SSH credentials from a developer's machine and propagate through their published packages.

The goal: **move the agent off my laptop and into a tightly-scoped sandbox on a VPS**, so a worst-case agent compromise is bounded — without giving up the YOLO ergonomics that make agents useful.

**Key design principles:**

- **Security boundary is the sandbox, not per-action approval.** Inside the box: agent runs freely, no prompts. Outside the box: hard limits the agent cannot bypass.
- **The VPS hardens credential *storage and access*, not credential *usage*.** What the agent can do once authenticated matches the laptop's experience. The whole project derisks creds at rest and in transit — not at the moment of action. Anything that would narrow what the agent does once authenticated (egress filtering, per-project token scoping, deploy gates, command allowlists) is out of scope by definition.

## 2. Threat model

### What we're defending against (all weighted equally)

- **MUST** — Credential cascade (worm): agent reads creds from my environment, exfils them, attacker mass-publishes poisoned packages from my GitHub/npm accounts. *(Acknowledged residual: an active-attack agent can still **use** credentials in-session via ssh-agent / CLIs to push, publish, or deploy — even without seeing raw key material. Stolen credentials remain valid until manually revoked at each upstream service; user-set TTLs bound the worst case where the upstream supports them. Multi-project sharing — see §3 — means a compromise in one project's deps reaches all other projects' tokens.)*
- **MUST** — Code / IP / data leakage: agent reads files it shouldn't (private repos, `.env`, client code) and exfils them. *(Acknowledged residual: under active agent compromise, whatever is currently mounted into the sandbox is reachable. Mitigated by keeping mounted scope minimal and recoverable from GitHub, not by trying to make the sandbox unreadable.)*
- **MUST** — Identity hijack: stolen GitHub/npm creds used to push malicious commits as me, damaging reputation and downstream users. *(Acknowledged residual: the system does not bound the impact of a hijack once authenticated. Duration is bounded by user-set TTLs at each upstream and by manual revocation. No protected-branch enforcement or commit-signing requirement in v1.)*
- **MUST** — Runaway LLM / cloud bill: stolen API key racks up large charges before I notice.

### Attacker capability we're modeling

- Malicious package in the dependency graph (npm/pip/cargo postinstall scripts).
- Malicious MCP server installed by the agent.
- Compromised Claude Code / Codex update or plugin.
- The agent itself making a catastrophic mistake under YOLO (e.g. `rm -rf`, force-push).

### Out of scope (explicitly)

- Nation-state attackers with physical access to my devices.
- Compromise of Tailscale, Hetzner, or Infisical at the infrastructure level (treated as trusted dependencies — see §7).
- Side-channel attacks (timing, electromagnetic, etc.).
- Laptop compromise → VPS via Tailscale. The laptop is on the tailnet by design and can reach the VPS; a fully-owned laptop reaches the VPS too. The project's value is bounding *agent-on-VPS* compromise from reaching back into the laptop, not the other direction.

## 3. Usage patterns

- **MUST** — Mixed interactive + occasional longer runs.
- **MUST** — Single laptop, primary driver. Multi-laptop / device-portability is not in scope.
- **MUST** — Multiple projects in parallel on the same VPS, no internal walls between them. If a project needs stronger isolation, spin up a separate VPS in its own Hetzner project for it (do not retrofit internal walls into v1).
- **SHOULD** — Replicate the laptop development experience reasonably closely, just relocated to the VPS.
- **WON'T** — Multi-user / team collaboration. This is a personal setup.
- **WON'T** — IDE / VS Code Remote / IDE-over-SSH integration. I don't use an IDE; terminal-only.

## 4. Functional requirements

### Workloads supported

- **MUST** — Personal projects (hobby, learning, experimentation).
- **MUST** — Production code for my own company's apps (development, deploys, hotfix capability).

### Credential categories the system needs to handle

- **MUST** — Source control: GitHub git operations via SSH key only (signing oracle — private key stays in the creds zone, no bearer token in sandbox).
- **MUST** — Publishing: npm and PyPI publish tokens.
- **WON'T (v1)** — Docker Hub publish from the sandbox. `docker login` needs a username + password pair (not a single env var), and pushes typically rely on auth in `~/.docker/config.json`. Adding it cleanly requires both a username secret and a pre-exec login step; deferred until there's an actual publish workflow that demands it. (Note in `daemon/cred-daemon.sh` documents the same.)
- **MUST** — Cloud infra & app platforms: Cloudflare, GCP, Hetzner — the platforms I actually deploy to. Corresponding CLIs (`wrangler`, `gcloud`, `hcloud`) baked into the sandbox image.
- **MUST** — The agent VPS lives in a dedicated Hetzner Cloud project (e.g. `coding-agent-vps`), separate from any project where apps are deployed. The agent's `HCLOUD_TOKEN` is scoped to the **apps project(s) only** — it has no permissions in the agent-vps project, so even a fully compromised agent cannot reach its own host. The admin token for the agent-vps project lives on the laptop (password manager) and is used for provisioning and the "kill from Hetzner panel" backstop.
- **MUST** — LLM auth: Claude Max + Codex Pro subscriptions via interactive OAuth. OAuth is the only auth method that routes usage through subscription billing; API keys would bill against separate pay-per-use API accounts at significantly higher cost. The interactive bootstrap step (§6) and in-sandbox refresh-token residual (§5) are accepted as the price of subscription billing.
- **WON'T (v1)** — Production database connection strings, signing keys, JWT secrets. Production app secrets live in the production environment (Vercel/Cloudflare env vars), not on the VPS. The agent triggers deploys via cloud-platform creds; the platform mounts secrets at runtime.
- **WON'T (v1)** — Financial / payment APIs (Stripe etc.). Same logic: live in prod environment, not on VPS.
- **WON'T (v1)** — GitHub PAT / `gh` CLI / GitHub API access from the sandbox. PR creation, issue management, CI status, and other GitHub API operations happen from the laptop. The agent on the VPS uses `git` push/pull via SSH only.

### Agent capabilities

- **MUST** — Agent can read, edit, commit, push code for any project I'm working on.
- **MUST** — Agent can trigger production deploys via cloud-platform deploy keys.
- **MUST** — Agent runs in YOLO mode with no per-action approval prompts.

## 5. Security requirements

### Sandbox boundary

- **MUST** — Agent runs inside an OS-level sandbox (container or equivalent) on the VPS.
- **MUST** — Sandbox runs under rootless Docker (or equivalent: Docker with user-namespace remapping, Podman rootless). Default rootful Docker is disallowed — it maps container-root to host-root and negates the "separate user / namespace" boundary.
- **MUST** — Raw credential files at rest live in the creds zone (`/var/lib/agent-vps/creds/`, mode 0600, owned by the `creds` user) — the sandbox cannot read them directly.
- **MUST** — SSH credentials use the ssh-agent socket as a signing oracle — the SSH private key never enters the sandbox process space.
- **Acknowledged** — Non-SSH credentials (gcloud SA key JSON, `CLOUDFLARE_API_TOKEN` / `HCLOUD_TOKEN` env vars, npm `_authToken`) are delivered into the sandbox at use-time and are readable by the sandbox process. The creds zone protects them *at rest*, not *at use-time inside the sandbox*. Only SSH is a true signing oracle.
- **MUST** — The Infisical Universal Auth bootstrap secret is stored in a path readable only by the cred-daemon's user (e.g. `/etc/agent-vps/infisical-uauth`, mode 0600, owned by the `creds` user). The sandbox container has no mount or read access to this path.
- **Acknowledged** — Claude Code / Codex OAuth refresh tokens live inside the sandbox by necessity (the agent CLI needs them). The agent process can read its own auth state. Impact is bounded to LLM API spend within Anthropic/OpenAI's account, but the "no raw credentials in sandbox" claim has this exception.

### Network policy

> **Ingress** = traffic coming *in* to the VPS (someone connecting to your server).
> **Egress** = traffic going *out* from the VPS (your server connecting out to the internet).
> They are independent and have independent rules.

**Ingress (incoming):**

- **MUST** — VPS firewall blocks all incoming ports from the public internet. Only Tailscale traffic is permitted in. SSH, any agent endpoints, anything else are reachable only via tailnet.
- **MUST** — Tailscale ACL is deny-by-default: only my own tailnet nodes can reach the VPS.
- **MUST** — Firewall layers deny all IPv6 inbound, matching the IPv4 deny-all rules. IPv6 itself stays enabled on the VPS (kernel and interface level) — kernel-level disable was rejected because it causes silent failures for any service that binds to `::` and breaks IPv6-preferring DNS fallback for package mirrors. The security property we care about ("no public ingress") is enforced at the firewall, not at the network stack.
- **MUST** — Tailscale ACL also denies VPS → laptop traffic. The compromised-VPS scenario cannot initiate connections to laptop tailnet services. (Laptop-initiated SSH to the VPS is connection-tracked and unaffected.)

**Egress (outgoing):**

- **WON'T (v1)** — No outbound allowlist on the sandbox. The agent has unrestricted outbound network access, matching the laptop. Tradeoff named in the defense table; non-goals (§8) carries the parity reasoning.

### Wallet / credential lifecycle

- **MUST** — The VPS's access to Infisical uses a credential with bounded TTL (Infisical Universal Auth access tokens), not a permanent token.
- **MUST** — Credential values are stored in Infisical and fetched by the cred-daemon. The cred-daemon does not mint, rotate, or otherwise manage upstream credential lifecycles.
- **SHOULD** — The cred-daemon refreshes its local cache from Infisical daily so user-initiated changes propagate within 24h without a sandbox restart.
- **User responsibility (out of project scope)** — Setting expiration on credentials at each upstream service where supported, manually rotating values in Infisical when they expire or compromise is suspected, and revoking at each upstream during incident response. The project does not automate any upstream credential lifecycle.

### Revocation / killswitch

- **MUST** — I can revoke the VPS's access to Infisical from outside the VPS via Infisical's admin interface.
- **MUST (v1)** — Revoking in Infisical causes the cred-daemon's next refresh to fail; the VPS can no longer fetch new credential values. Plus immediate "kill the VPS from Hetzner panel" as a hard backstop — the Hetzner panel uses a separate admin credential kept on the laptop (per §4), not the sandbox's apps-only `HCLOUD_TOKEN`, so the agent cannot prevent this backstop even if fully compromised.
- **SHOULD** — A documented "scrub local cache" procedure exists for incidents: stop the cred-daemon, remove `/var/lib/agent-vps/creds/*`, stop the sandbox container. Revoking in Infisical alone does NOT invalidate values already cached on the VPS or already loaded into a running shell's env.
- **User responsibility (out of project scope)** — During an incident, revoking each affected credential at its upstream service (GitHub, GCP, Cloudflare, Hetzner, npm, etc.) **and revoking Claude Code / Codex OAuth grants** at the Anthropic and OpenAI account dashboards. The OAuth refresh tokens persist in the sandbox `agent-state` volume and are NOT affected by revoking the VPS's Infisical access. Stolen credentials remain valid until manually revoked upstream or until their TTL expires.

### Blast radius bounds

- **MUST** — A fully compromised sandbox cannot read my laptop's files, SSH keys, browser cookies, or other personal credentials. (This is the entire point — laptop is no longer on the attack surface.)
- **MUST** — A fully compromised sandbox cannot read the VPS's wallet credential (different user / process).

### Two threat classes — and which defenses actually hold

Defenses below are not equally load-bearing. To be honest about scope:

- **Passive supply chain attack** — a poisoned dep / MCP / postinstall script runs inside the sandbox without the agent knowing. Agent is innocent; the attacker is the dep.
- **Active agent compromise** — the agent itself becomes the attacker (prompt injection, jailbroken plugin, malicious MCP that the agent is unaware of installing). Once adversarial, anything inside the sandbox is bypassable: it can edit `.npmrc`, `--ignore-scripts=false`, `apt install` whatever, etc.

| Defense | Passive supply chain | Active agent attack |
|---|---|---|
| Credential isolation (cred-daemon) | Strong | Partial — bounds exfil-and-reuse to upstream TTLs (user-managed); does NOT prevent in-session misuse via ssh-agent / CLIs |
| Sandbox FS isolation from laptop | Strong | **Strong** |
| ~~Network egress restriction~~ *(not enforced in v1 — see Network policy / Egress)* | — | — |
| `min-release-age` for package managers | Strong | Weak (agent can disable) |
| Minimal sandbox image composition | Moderate | Weak (working package manager → agent can install more) |

### Package manager safeguards (passive supply chain)

- **SHOULD** — Minimum release age **≥ 7 days** enforced for every package manager we use. Filters fresh supply-chain compromises before they execute.
  - **pnpm** (Node): `minimumReleaseAge` set to `10080` (7d) in `pnpm-workspace.yaml` or `.npmrc`. pnpm 11+ has this on by default at 1 day; we bump to 7.
  - **uv** (Python): `exclude-newer = "7d"` (cooldown duration) in `pyproject.toml`, applied per-project.
- **SHOULD** — Dependencies are lockfile-pinned. The agent doesn't silently bump lockfiles; lockfile changes are an explicit step.
- **SHOULD** — In-sandbox package-manager config inherits the same policy as the laptop, so the agent gets the protection on every install without per-project setup.
- **Acknowledged** — All of the above are bypassable by an active attacker. They are cost-effective defenses against the *common case*, not against a deliberately adversarial agent.

### Sandbox toolchain composition

Day-1 contents of the sandbox image:

- **Base**: `bash`, `git`, `curl`, `tmux`
- **Agents**: `claude-code`, `codex`
- **Runtimes + package managers**: Node + `pnpm`, Python + `uv`
- **Deploy CLIs**: `wrangler` (Cloudflare), `gcloud` (GCP), `hcloud` (Hetzner)

- **SHOULD** — Agent sessions run inside `tmux` so SSH disconnects and container restarts don't kill in-progress work.
- **SHOULD** — The image build is version-controlled (Dockerfile in a repo). Changes are auditable and reversible.
- **Acknowledged** — A minimal image is NOT a hard command allowlist: anything with a working package manager (or `bash` + `curl`) can install more at runtime. The value is reducing the *default* attack surface, not a per-action gate.
- **COULD (later phase)** — Tighten further with read-only filesystem, non-root user, and seccomp/AppArmor profiles that block writes to system bin dirs. Meaningful against active attackers, but added complexity.

## 6. Operational requirements

### Cost

- **MUST** — Total monthly cost ≤ €10. Current baseline: Hetzner CX23 (~€4.50-5) + Infisical free tier (€0) ≈ **~€5/mo**, well under cap. (CX22 — the original cheapest 4GB option at €4.49 — was retired by Hetzner; CX23 is the same-spec successor.)

### Maintenance

- **MUST (long-term)** — Near-zero ongoing maintenance after initial setup. Fire-and-forget.
- **SHOULD** — Updates to OS / containers can be automated (unattended-upgrades, watchtower, or similar).

### Recovery / state management

- **MUST** — All important state lives in GitHub (or future external DB), not on the VPS.
- **MUST** — VPS rebuilds from scratch via scripts; no precious state on the box itself.
- **MUST** — Agent must be instructed to commit early and often (so VPS loss = at most a few minutes of WIP loss).
- **Accepted** — On rebuild: ~30 seconds of manual bootstrap (paste the Infisical Universal Auth client secret) + interactive Claude/Codex OAuth login. No way around this without keeping secrets in rebuild scripts (which we don't want).
- **WON'T (v1)** — Backups, snapshots, HA / uptime SLAs. If it's down for hours, I can wait.

### Logging / observability

- **SHOULD** — Basic visibility (refresh-daemon logs, sandbox start/stop records) if low cost and low effort. Don't build elaborate logging infra for it.
- **SHOULD** — Minimal alerting on (a) Infisical refresh failures, (b) production deploy events, (c) Anthropic/OpenAI rate-limit hits (proxy for runaway use). Delivery via email or ntfy/Pushover — a ~20-line script, not an observability stack.
- **WON'T (v1)** — Compliance-grade audit logging with full attribution.

## 7. Constraints & preferences

### Stack choices

- **MUST** — Tailscale for private network (already in use; no public ingress to VPS).
- **MUST** — Hetzner for compute (already in use; cost + good track record).
- **MUST** — Wallet vendor: **Infisical (cloud, free tier)**. Universal Auth Machine Identity provides bounded-TTL access tokens (`accessTokenTTL` / `accessTokenMaxTTL`) with remote revoke endpoint. CLI is a single Go binary (not npm). Open-source server available as a self-host escape valve if SaaS posture ever degrades. Free tier covers single-VPS use (5 machine identities cap, 3 projects).
- **SHOULD** — Docker for the agent sandbox (well-understood, broad tooling).
- **SHOULD** — Linux (Ubuntu LTS or NixOS), minimal base, scripted setup.

### Architectural preferences

- **MUST** — One unifying pattern, not three mechanisms per problem. The agent talks to local interfaces; the creds zone holds raw secrets; one daily fetch from Infisical keeps the local cache in sync.
- **MUST** — Prefer off-the-shelf proven components over custom code where they exist; custom code is small glue scripts only.
- **SHOULD** — Simpler is better, even at some cost in theoretical optimum.
- **WON'T (v1)** — GitHub Apps with token brokers, HashiCorp Vault, custom egress proxies. Reachable for if a real need surfaces.

## 8. Explicit non-goals (v1)

- Multi-user / team
- IDE remote integration (VS Code Remote)
- Production database secrets in scope
- Financial / payment API keys in scope
- High availability / uptime SLAs
- Compliance / audit logging
- Network egress allowlist on the sandbox *(usage-restriction; see §1 principle)*
- Project-internal isolation — spawn separate VPS per isolated-project if needed *(usage-restriction)*
- Per-project credential scoping (e.g. GitHub tokens narrowed per-repo) *(usage-restriction)*


