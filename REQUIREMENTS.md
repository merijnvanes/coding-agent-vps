# Secure Agent VPS — Goals & Requirements

> Working document. Captures **what** we want and **why**. Decisions about **how** to build it live elsewhere.

## 1. Background & motivation

I run AI coding CLIs (Claude Code, Codex) routinely in `--dangerously-skip-permissions` / `--yolo` mode on my laptop because per-action approval prompts ruin the workflow. The 2025–2026 npm supply chain wave (Shai-Hulud 1.0/2.0, mini Shai-Hulud, Bitwarden CLI compromise) demonstrated that this posture means a single poisoned dependency can harvest GitHub/npm/AWS/SSH credentials from a developer's machine and propagate through their published packages.

The goal: **move the agent off my laptop and into a tightly-scoped sandbox on a VPS**, so a worst-case agent compromise is bounded — without giving up the YOLO ergonomics that make agents useful.

Key design principle: **security boundary is the sandbox, not per-action approval.** Inside the box: agent runs freely, no prompts. Outside the box: hard limits the agent cannot bypass.

## 2. Threat model

### What we're defending against (all weighted equally)

- **MUST** — Credential cascade (worm): agent reads creds from my environment, exfils them, attacker mass-publishes poisoned packages from my GitHub/npm accounts.
- **MUST** — Code / IP / data leakage: agent reads files it shouldn't (private repos, `.env`, client code) and exfils them. *(Acknowledged residual: under active agent compromise, whatever is currently mounted into the sandbox is reachable. Mitigated by keeping mounted scope minimal and recoverable from GitHub, not by trying to make the sandbox unreadable.)*
- **MUST** — Identity hijack: stolen GitHub/npm creds used to push malicious commits as me, damaging reputation and downstream users.
- **MUST** — Runaway LLM / cloud bill: stolen API key racks up large charges before I notice.

### Attacker capability we're modeling

- Malicious package in the dependency graph (npm/pip/cargo postinstall scripts).
- Malicious MCP server installed by the agent.
- Compromised Claude Code / Codex update or plugin.
- The agent itself making a catastrophic mistake under YOLO (e.g. `rm -rf`, force-push).

### Out of scope (explicitly)

- Nation-state attackers with physical access to my devices.
- Compromise of Tailscale, Hetzner, or whichever wallet vendor we choose at the infrastructure level (treated as trusted dependencies — see §7).
- Side-channel attacks (timing, electromagnetic, etc.).

## 3. Usage patterns

- **MUST** — Mixed interactive + occasional longer runs.
- **MUST** — Single laptop, primary driver. Multi-laptop / device-portability is not in scope.
- **MUST** — Multiple projects in parallel on the same VPS, no internal walls between them. If a project needs stronger isolation, spin up a separate VPS for it (do not retrofit internal walls into v1).
- **SHOULD** — Replicate the laptop development experience reasonably closely, just relocated to the VPS.
- **WON'T** — Multi-user / team collaboration. This is a personal setup.
- **WON'T** — IDE / VS Code Remote / IDE-over-SSH integration. I don't use an IDE; terminal-only.

## 4. Functional requirements

### Workloads supported

- **MUST** — Personal projects (hobby, learning, experimentation).
- **MUST** — Production code for my own company's apps (development, deploys, hotfix capability).

### Credential categories the system needs to handle

- **MUST** — Source control + publishing: GitHub push/API, npm/PyPI/Docker Hub publish tokens.
- **MUST** — Cloud infra & app platforms: Cloudflare, GCP, Hetzner — the platforms I actually deploy to. Corresponding CLIs (`wrangler`, `gcloud`, `hcloud`) baked into the sandbox image.
- **MUST** — LLM auth: Claude Pro/Max subscription via interactive OAuth (no long-lived API key needed).
- **WON'T (v1)** — Production database connection strings, signing keys, JWT secrets. Production app secrets live in the production environment (Vercel/Cloudflare env vars), not on the VPS. The agent triggers deploys via cloud-platform creds; the platform mounts secrets at runtime.
- **WON'T (v1)** — Financial / payment APIs (Stripe etc.). Same logic: live in prod environment, not on VPS.

### Agent capabilities

- **MUST** — Agent can read, edit, commit, push code for any project I'm working on.
- **MUST** — Agent can trigger production deploys via cloud-platform deploy keys.
- **MUST** — Agent runs in YOLO mode with no per-action approval prompts.

## 5. Security requirements

### Sandbox boundary

- **MUST** — Agent runs inside an OS-level sandbox (container or equivalent) on the VPS.
- **MUST** — Sandbox cannot read raw credential files. Keys live in a separate user / namespace.
- **MUST** — Sandbox accesses credentials via narrow local interfaces (ssh-agent socket, credential helper) — never as raw key material.

### Network policy

> **Ingress** = traffic coming *in* to the VPS (someone connecting to your server).
> **Egress** = traffic going *out* from the VPS (your server connecting out to the internet).
> They are independent and have independent rules.

**Ingress (incoming):**

- **MUST** — VPS firewall blocks all incoming ports from the public internet. Only Tailscale traffic is permitted in. SSH, any agent endpoints, anything else are reachable only via tailnet.
- **MUST** — Tailscale ACL is deny-by-default: only my own tailnet nodes can reach the VPS.

**Egress (outgoing):**

- **WON'T (v1)** — No outbound allowlist on the sandbox. The agent has unrestricted outbound network access, matching the laptop. Tradeoff named in the defense table; non-goals (§8) carries the parity reasoning.

### Wallet / credential lifecycle

- **MUST** — The VPS's access to the upstream wallet (vendor TBD — see §7) uses a credential with bounded TTL (refreshed periodically), not a permanent token.
- **MUST** — All derived secrets (SSH keys, GitHub tokens, cloud platform tokens) are refreshed daily.
- **SHOULD** — Default daily refresh interval = 24h. Can be tuned.
- **COULD** — Sub-day rotation for the highest-value tokens if cheap to implement.

### Revocation / killswitch

- **MUST** — I can revoke the VPS's wallet access from outside the VPS via the wallet's admin interface.
- **MUST (v1)** — Worst-case revocation latency ≤ 24h via the daily rotation locking out a revoked SA token. Plus immediate "kill the VPS from Hetzner panel" as a hard backstop.

### Blast radius bounds

- **MUST** — A fully compromised sandbox cannot read my laptop's files, SSH keys, browser cookies, or other personal credentials. (This is the entire point — laptop is no longer on the attack surface.)
- **MUST** — A fully compromised sandbox cannot read the VPS's wallet credential (different user / process).
- **SHOULD** — A fully compromised sandbox loses access to fresh secrets within 24h even without active revocation.

### Two threat classes — and which defenses actually hold

Defenses below are not equally load-bearing. To be honest about scope:

- **Passive supply chain attack** — a poisoned dep / MCP / postinstall script runs inside the sandbox without the agent knowing. Agent is innocent; the attacker is the dep.
- **Active agent compromise** — the agent itself becomes the attacker (prompt injection, jailbroken plugin, malicious MCP that the agent is unaware of installing). Once adversarial, anything inside the sandbox is bypassable: it can edit `.npmrc`, `--ignore-scripts=false`, `apt install` whatever, etc.

| Defense | Passive supply chain | Active agent attack |
|---|---|---|
| Credential isolation (cred-daemon + daily refresh) | Strong | **Strong** |
| Sandbox FS isolation from laptop | Strong | **Strong** |
| Network egress restriction | Strong | **Strong** *(intentionally not used in v1 — see Network policy / Egress)* |
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

- **Base**: `bash`, `git`, `curl`, `gh`
- **Agents**: `claude-code`, `codex`
- **Runtimes + package managers**: Node + `pnpm`, Python + `uv`
- **Deploy CLIs**: `wrangler` (Cloudflare), `gcloud` (GCP), `hcloud` (Hetzner)

- **SHOULD** — The image build is version-controlled (Dockerfile in a repo). Changes are auditable and reversible.
- **Acknowledged** — A minimal image is NOT a hard command allowlist: anything with a working package manager (or `bash` + `curl`) can install more at runtime. The value is reducing the *default* attack surface, not a per-action gate.
- **COULD (later phase)** — Tighten further with read-only filesystem, non-root user, and seccomp/AppArmor profiles that block writes to system bin dirs. Meaningful against active attackers, but added complexity.

## 6. Operational requirements

### Cost

- **MUST** — Total monthly cost ≤ €10. Current baseline: Hetzner CX22 (~€4.49) + Infisical free tier (€0) ≈ **€4.49/mo**, well under cap.

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
- **WON'T (v1)** — Compliance-grade audit logging with full attribution.

## 7. Constraints & preferences

### Stack choices

- **MUST** — Tailscale for private network (already in use; no public ingress to VPS).
- **MUST** — Hetzner for compute (already in use; cost + good track record).
- **MUST** — Wallet vendor: **Infisical (cloud, free tier)**. Universal Auth Machine Identity provides bounded-TTL access tokens (`accessTokenTTL` / `accessTokenMaxTTL`) with remote revoke endpoint. CLI is a single Go binary (not npm). SOC 2 / HIPAA / FIPS 140-3 compliant as of 2026. Open-source server available as a self-host escape valve if SaaS posture ever degrades. Free tier covers single-VPS use (5 machine identities cap, 3 projects).
- **SHOULD** — Docker for the agent sandbox (well-understood, broad tooling).
- **SHOULD** — Linux (Ubuntu LTS or NixOS), minimal base, scripted setup.

### Architectural preferences

- **MUST** — One unifying pattern, not three mechanisms per problem. The agent talks to local interfaces; the wallet zone holds raw secrets; one daily refresh cron handles all rotation.
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
- Network egress allowlist on the sandbox — matches the unrestricted-egress baseline on the laptop; revisit only if a project's data-sensitivity changes
- Project-internal isolation (one compromised project shielded from siblings) — deferred; spawn separate VPS per isolated-project if/when needed


