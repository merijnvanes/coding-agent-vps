# coding-agent-vps

Run AI coding CLIs (Claude Code, Codex) on a sandboxed Hetzner VPS
instead of on your laptop. Credentials live in Infisical and are
fetched at runtime — never in your repo or shell environment.

Single-developer setup. ~€5/month.

> ⚠️ **Experimental, unaudited, single-developer template.** This is
> a personal-use template that one developer iterates on. It has not
> been third-party-reviewed and the security claims are best-effort,
> not guarantees. See [SECURITY.md](./SECURITY.md) for the
> disclosure policy and threat-model residuals.

## Why

Running an AI coding agent on your laptop gives it access to anything
your shell can reach: SSH keys, every file you can read, browser
cookies, your local environment. Running it on a remote, disposable
VPS gives a few specific properties you can't get locally:

- The agent runs in a rootless Docker sandbox on the VPS. It can't
  read the credential daemon's files directly and can't break out to
  the host filesystem.
- A compromised agent can't reach your laptop and can't access its own
  VPS. The Hetzner admin token (the kill switch) lives only on your
  laptop, never on the VPS. `hcloud server delete coding-agent-vps`
  always works.
- Credentials (GitHub SSH key, GCP service account, Hetzner apps
  token, etc.) come from Infisical at runtime. They aren't baked into
  the Docker image and they aren't in your shell's environment except
  briefly inside the running sandbox.

### Tradeoffs

- ~€5/mo for the VPS, free tier for Infisical and Tailscale.
- ~30 min of one-time external-service setup across Hetzner Cloud,
  Infisical, Tailscale, and GitHub.
- Latency on every keystroke (round-trip to Frankfurt or whichever
  Hetzner location you provision).
- A new operating model: SSH + tmux + docker exec instead of native
  local execution.

### When this is worth it

You'd otherwise run an AI agent on the same laptop you browse the web
on, *and* the agent will touch production systems, sensitive repos,
or credentials whose blast radius you care about bounding. If you'd
just run the agent in a throwaway local VM anyway, this is probably
over-engineering for you.

### Template — providers are swappable

This repo is a working template. The defaults are concrete choices:

- **Hetzner Cloud** for the VPS
- **Infisical** for the credential store
- **Tailscale** for network access + SSH
- **GitHub** for source control
- **ntfy** for alerts

The *architecture* is provider-agnostic — only the wire-up is specific.
If you want different providers (Vault instead of Infisical,
DigitalOcean instead of Hetzner, etc.), tell your agent in the setup
prompt and it'll adapt the code before provisioning. It's a real
refactor, not a config flag — but it's the kind of refactor agents
handle well, since the existing Infisical/Hetzner code is the working
reference for the equivalent calls in any other provider.

## Setup

This repo is designed to be deployed **by an AI agent on your behalf**.
The setup involves several web UIs (Hetzner, Infisical, Tailscale,
GitHub) — having the agent walk you through that flow is materially
faster than reading through it yourself.

Open a fresh AI coding agent session (Claude Code, Codex, or similar)
and paste:

> Please deploy coding-agent-vps for me. Clone
> https://github.com/merijnvanes/coding-agent-vps into a working
> directory and follow `docs/SETUP.md` step by step. Ask me for
> anything you need.

If you want non-default providers, name them in the prompt:

> Please deploy coding-agent-vps for me, but using HashiCorp Vault
> instead of Infisical and DigitalOcean instead of Hetzner. Clone
> https://github.com/merijnvanes/coding-agent-vps, follow
> `docs/SETUP.md`, and adapt the provider-specific code first.

The agent walks you through manual steps, runs automated ones, and
verifies as it goes. Total elapsed time on a clean setup: ~30 min,
mostly waiting for cloud-init and the sandbox image build.

## After setup, day-to-day

```bash
ssh <your-user>@coding-agent-vps              # via Tailscale SSH
docker exec -it sandbox tmux attach -t main   # attach to your running session
```

Then run `claude` or `codex` inside the sandbox. Your workspace is
`/work`. tmux persists across SSH disconnects.

## Docs

- [docs/SETUP.md](./docs/SETUP.md) — the agent-facing setup flow
- [docs/USAGE.md](./docs/USAGE.md) — day-to-day, credential rotation,
  incident response, rebuild, troubleshooting
- [docs/REQUIREMENTS.md](./docs/REQUIREMENTS.md) — what's in scope and
  why
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — concrete component
  layout

## License

[Unlicense](./LICENSE) — public domain dedication. Do whatever you want.
