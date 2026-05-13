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

A local AI agent can reach anything your shell can: SSH keys, every
file you can read, browser cookies, your environment. Running it on
a remote, disposable VPS bounds the blast radius:

- Rootless Docker sandbox — bind mounts expose only the credential
  helpers and the workspace, not raw key material. (Kernel escape is
  a residual; see [SECURITY.md](./SECURITY.md).)
- A compromised agent can't reach your laptop or delete its own VPS.
  The Hetzner kill switch lives only on your laptop:
  `hcloud server delete coding-agent-vps` always works.
- Credentials come from Infisical at runtime — not in the image, not
  in your shell environment.

**Tradeoffs:** ~€5/mo, ~30 min one-time setup, keystroke latency to
Frankfurt, and a new operating model (SSH + tmux + docker exec).

**Worth it if** your agent will touch production, sensitive repos, or
credentials you care about — and you'd otherwise run it on the same
laptop you browse on. A throwaway local VM may suffice otherwise.

**Providers are swappable.** Defaults are Hetzner, Infisical, Tailscale,
GitHub, and ntfy. The architecture is provider-agnostic — name
alternatives in the setup prompt and the agent adapts the code first.

## Setup

> [!WARNING]
> Always audit third-party code before installing.

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
