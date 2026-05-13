# Security policy

## Reporting a vulnerability

If you find a security issue in this repository:

- **Don't** open a public GitHub issue or PR with the details.
- **Do** email a description to **merijn.vanes@mulletiq.com**, ideally
  with reproduction steps and the affected commit/path.

This is a single-developer hobby template. There is no SLA and no
bounty program. I'll respond when I can — typically within a week.

## Status

This template is **experimental and unaudited**. It has not been
reviewed by a third party. The design is documented honestly in
[docs/REQUIREMENTS.md](./docs/REQUIREMENTS.md) and
[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md), including the
explicit residuals and non-goals. Use at your own risk.

## Threat model summary

See [docs/REQUIREMENTS.md §2 Threat model](./docs/REQUIREMENTS.md)
and [docs/ARCHITECTURE.md "Trust zones"](./docs/ARCHITECTURE.md) for
the canonical version. Briefly:

**In scope** (the design aims to defend against):
- A compromised AI agent inside the sandbox cannot read raw key
  material from the credential daemon's files (they live in a
  separate trust zone the sandbox doesn't mount).
- A compromised agent cannot reach the laptop or other devices on
  the user's tailnet (Tailscale ACL: VPS→laptop is denied).
- A compromised agent cannot access or destroy its own VPS (the
  Hetzner admin token lives only on the laptop; the agent's apps-
  scope token is scoped to a different Hetzner project).
- An attacker on the public internet cannot reach the VPS over any
  port (deny-all Hetzner Cloud firewall + UFW; only Tailscale's
  outbound-initiated tunnel is open).

**Out of scope / explicit residuals**:
- A compromised agent **can** exfiltrate any credential the cred-
  daemon has fetched into the sandbox during its lifetime (env-
  export tokens, gcloud SA key JSON, OAuth refresh tokens). The
  ssh-agent abstraction limits this for the GitHub key (signing
  only, key bytes never reach the sandbox), but other credentials
  are read as files. Mitigations: rotate at the issuer after any
  suspected compromise (see [docs/USAGE.md "Incident response"](./docs/USAGE.md)).
- A compromised agent **can** push to any GitHub repo the user has
  write access to (the SSH key acts as the user). The architecture
  doesn't currently distinguish "agent-managed repos" from "user's
  personal repos" — the SSH key is one identity. Mitigation: review
  diffs before pushing, especially to the coding-agent-vps repo
  itself.
- Hetzner Cloud, Infisical, Tailscale, GitHub, and the Anthropic /
  OpenAI OAuth providers are **trusted dependencies**. A compromise
  at any of these vendors is out of the threat model.
- This template has **not** been audited. The author is a single
  developer using it for personal projects.

## Reporting non-security bugs

For functional bugs, doc issues, or feature suggestions, please open
a GitHub issue normally. Reserve email + private disclosure for
issues with a security dimension (e.g., an exploit path, credential
exfiltration vector, sandbox escape).
