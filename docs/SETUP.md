# Setup guide

> **This document is written for an AI coding agent to follow on behalf
> of the user setting up coding-agent-vps.** It is not a tutorial for a
> human to read top-to-bottom — the human's view of the flow is the
> agent walking them through it.

## How to use this document

**If you are the AI agent:** Walk through each phase in order. Drive
autonomously — ask the user for input only when you genuinely cannot
proceed without it (web-UI clicks, OAuth flows, etc.). After each
phase, briefly tell the user what just happened. If you hit a
verification failure, refer the user to `docs/USAGE.md` Troubleshooting
and surface the specific symptom.

> **You never need to see any secret value.** The user holds all
> secrets in their password manager. They get typed directly into
> interactive prompts (`provision.sh`, `bootstrap.sh`, OAuth flows)
> or pasted into web UIs (Infisical, Tailscale) — never into the
> chat with you. **Never ask the user to paste a secret here**, even
> as an option. If you need to *know that something is done*, ask
> "done?" not "what was the value?". This is the entire architectural
> point of the chat-orchestration / secret-locality split.

> **Keep messages lean — don't preempt errors.** Most runs succeed
> first try. Don't enumerate possible failure modes / error codes /
> recovery steps in advance of an actual failure — it bloats the UX
> and makes the happy path feel risky. If something does fail, refer
> the user to [docs/USAGE.md → Troubleshooting](./USAGE.md#troubleshooting)
> for the specific symptom — that doc has the failure modes catalogued.

**If you are the human:** paste the prompt from the README into your
agent and let it drive. Stay near the keyboard — you'll be asked to
click through browser tabs.

## Phase 0: Provider choices

This repo is a template. The default implementation uses:

| Role | Default | Provider-specific code |
|---|---|---|
| Cloud VPS | Hetzner Cloud | `scripts/provision.sh`, parts of `cloud-init.yaml` |
| Secret store | Infisical | `daemon/cred-daemon.sh` (auth + fetch), `scripts/bootstrap.sh` (prompts) |
| Network + SSH | Tailscale | `cloud-init.yaml` (install + `tailscale up`), Tailscale policy file |
| Git host | GitHub | `scripts/provision.sh` (deploy key API), `cloud-init.yaml` (clone URL), GitHub SSH host-key pinning |
| Alerts | ntfy | `alerts/ntfy.sh` |

**Ask the user which providers they want before continuing.** Example:

> "The default setup uses Hetzner + Infisical + Tailscale + GitHub +
> ntfy. Are those fine, or do you want to swap any of them out?"

### If the user picks all defaults

Skip the rest of this phase and continue with the Prerequisites
section below. The remaining phases assume the defaults.

### If the user picks one or more alternatives

You need to refactor the code BEFORE running `provision.sh`. This is
**not a config-flag swap** — it's modifying the provider-specific code
in the files listed above. Rough effort, per swap:

- **Cloud provider**: 30–60 min. Mostly mechanical — replace `hcloud`
  CLI calls with `doctl` / `linode-cli` / etc.
- **Secret store**: 1–2 hours. The largest swap. `daemon/cred-daemon.sh`
  (~245 lines) couples auth + fetch + per-secret routing into one
  script. You'll rewrite the auth flow (different login endpoint,
  different bootstrap credential shape — Vault AppRole, AWS IAM, etc.)
  and the secrets-fetch endpoint while preserving the per-secret
  routing logic.
- **Network access** (Tailscale alternative): 30 min. Replace the
  install + `tailscale up` block in `cloud-init.yaml` and rewrite
  Phase 3 of this guide.
- **Git host**: 15–30 min. Mostly clone URL + host-key pin + deploy-
  key API.
- **Alerts**: 10 min. Single file, single function.

The high-level shape of each integration is the same; only the
concrete API calls / CLIs / config syntax differ.

Walk through the refactor in this order, with the user's confirmation
on each block:

1. **Cloud provider** — pick the equivalent of Hetzner Cloud (e.g.
   DigitalOcean `doctl`, Linode `linode-cli`, AWS Lightsail, GCP).
   The required capabilities are: per-project API tokens (so the
   agent VPS lives in its own project, isolated from the user's
   workloads), a network firewall attached at creation, and
   cloud-init user-data support. Replace `hcloud` CLI calls in
   `scripts/provision.sh` with the equivalent. Update the firewall
   pattern in `scripts/provision.sh` and any `cloud-init.yaml`
   references.

2. **Secret store** — pick the equivalent of Infisical (HashiCorp
   Vault with AppRole, AWS Secrets Manager, GCP Secret Manager,
   Doppler, 1Password Secrets Automation). The required shape is:
   a "bootstrap" credential held only by the VPS's `creds` user that
   lets it fetch the real secrets from the store. Refactor the auth
   + fetch loop in `daemon/cred-daemon.sh` and the prompts in
   `scripts/bootstrap.sh`. Keep the same secret names (`github-ssh-key`,
   `HCLOUD_TOKEN`, etc.) so the rest of the wire-up is unchanged.

3. **Network access** — pick the equivalent of Tailscale (WireGuard
   self-hosted, Cloudflare Zero Trust, Twingate). The required shape
   is: deny-all inbound at the firewall, and an authenticated overlay
   network the user's laptop joins. The current Tailscale-specific
   parts: `cloud-init.yaml` (install + `tailscale up --ssh`), policy
   instructions in this guide (Phase 3 below). Tailscale SSH is the
   login path: `scripts/cloud-init-tasks.sh` step 2b masks host
   OpenSSH, because the sandbox reaches host ports over loopback past
   the firewalls. With another overlay, drop that mask and keep its
   `sshd_config.d` drop-in (keys only, no root). The sandbox can
   still reach that sshd over loopback on any address it binds, so
   key-only login is then the control that holds.

4. **Git host** — only relevant if the user's repos are on something
   other than GitHub (e.g. GitLab, Codeberg, Forgejo, Bitbucket).
   Update the SSH host-key pin in `cloud-init.yaml`, the deploy-key
   registration in `scripts/provision.sh` (replace `gh api` with the
   host's API), and the clone URL.

5. **Alerts** — `alerts/ntfy.sh` is the only file to swap. Common
   alternatives: Slack webhook, Discord webhook, Telegram bot, plain
   SMTP.

After the refactor, have the user review the diff
(`git diff main`), commit it, then continue with the Prerequisites
section and the remaining phases. The phase structure below stays the
same — only the specific values asked-for in each phase change to
match the chosen providers.

## Prerequisites — confirm with the user first

Before starting, confirm the user has (or direct them to create):

- A Hetzner Cloud account (€5 minimum top-up needed before first VPS;
  no card needed for sign-up). https://www.hetzner.com/cloud
- An Infisical account (free tier, no card). https://infisical.com
- A Tailscale account (free tier). https://tailscale.com
- A GitHub account.
- ~30 min of time to complete the flow.
- Local CLI tools on the laptop running this setup: `curl`, `jq`, `git`,
  `gh`, `hcloud`, and Tailscale (installed and logged in to the
  user's tailnet: Phase 3 reads the laptop's tailnet IP, and every
  login to the VPS goes over it). The "Refresh pinned versions" section below leans on
  `curl + jq` for registry/release lookups; install via `brew install jq`
  on macOS or `apt-get install -y jq` on Debian/Ubuntu if missing.

**Optional:** push notifications when credentials fail to refresh.
If the user wants this, have them install the [ntfy](https://ntfy.sh)
app on their phone now — they'll subscribe to a topic in Phase 2.
Without it, the same alerts still land in `journalctl -u cred-daemon`
on the VPS; the user just won't get a phone buzz.

If anything is missing, pause and have them sign up first.

## Make the repo the user's own

The VPS clones this repo from the user's GitHub account and runs it as
root, and the setup commits and pushes along the way. So `origin` must
be a repo the user owns, with the template kept as `upstream` for
later updates (USAGE.md "Signed updates"). In the clone, first make
sure `gh` is logged in and git has an identity (setup commits need
it, and the commit signing in Phase 5 uses the email):

```bash
gh auth status || gh auth login
git config user.name  || git config user.name  "<their name>"
git config user.email || git config user.email "<their GitHub email>"
```

If `origin` already is a repo the user owns (they started from their
own copy), keep it and only add the template:
`git remote add upstream https://github.com/merijnvanes/coding-agent-vps.git`.
Otherwise, from a clone of the template:

```bash
gh repo fork --remote          # public fork: origin = the user's fork, upstream = the template
```

For a private copy instead (`provision.sh` then sets up a read-only
deploy key):

```bash
git remote rename origin upstream
gh repo create <name> --private --source=. --remote=origin --push
```

Then make `main` track the user's repo, so a plain `git push` goes
there (`gh repo fork --remote` leaves it tracking the template):

```bash
git push -u origin main
```

Check: `git remote -v` shows `origin` at the user's account and
`upstream` at the template.

A copy made with GitHub's "Use this template" button starts with one
commit and no shared history, so the update flow in USAGE.md "Signed
updates" cannot merge template changes into it. If `origin` is such a
copy and the user has not changed it, start over from a clone of the
template with the fork step above (the copy holds only that one
commit, so nothing is lost). Otherwise template updates have to be
ported by hand.

## Choose the user's shell username

Default username on the VPS is `dev` (the human who SSHes in — distinct
from `creds`, the credential daemon, and `agent`, the user inside the
container). It's cosmetic and trivially renamed.

Ask the user: "What username do you want for SSH login to the VPS?
(default: `dev`)"

If anything other than `dev`, do a repo-wide replace before running
provision.sh:

```bash
NEW_USER="<their-choice>"
# Rename the username, BUT skip occurrences inside paths like /dev/null
# (kernel device tree) or words like "develop" / "device". The lookarounds
# require non-word, non-slash on both sides so `dev` only matches when it
# appears as a complete shell token.
git grep -l '\bdev\b' \
  | grep -v -e '^docs/' -e '^README.md$' -e '^SECURITY.md$' \
  | xargs perl -i -pe 's{(?<![/\w])dev(?![/\w])}{$ENV{NEW_USER}}g'

# IMPORTANT: review the diff before committing — the pattern is careful
# but not infallible. Look for any unintended /dev/ paths or "develop*"
# strings that got rewritten and revert them.
NEW_USER="$NEW_USER" git diff
```

Confirm with the user that the diff looks right (only username-shaped
occurrences changed) before continuing. The change isn't committed yet.

## Refresh pinned versions (~5 min, agent does this)

**Goal.** Every third-party tool we install is version-pinned. Before
running `provision.sh` (or any rebuild that triggers a fresh install),
update each pin to the latest stable release that is **at least 7 days
old**. This is the supply-chain cooldown rule: a compromised version
typically gets spotted and yanked within days, so refusing too-new
releases avoids the patient-zero window.

### Where the pins live

| File | Pins |
|---|---|
| `sandbox/Dockerfile` (ARG block at top) | `NODEJS_VERSION`, `NPM_VERSION`, `PNPM_VERSION`, `UV_VERSION` + `UV_SHA256`, `GCLOUD_VERSION`, `WRANGLER_VERSION`, `CLAUDE_CODE_VERSION`, `CODEX_VERSION`, `GEMINI_CLI_VERSION`, `INFISICAL_VERSION`, `HCLOUD_VERSION` + `HCLOUD_SHA256`, `SUPABASE_CLI_VERSION` + `SUPABASE_CLI_SHA256` |
| `cloud-init.yaml` (Tailscale install in `runcmd`) | inline `tailscale=X.Y.Z` |
| `scripts/cloud-init-tasks.sh` (Docker install block) | `DOCKER_CE_VERSION`, `CONTAINERD_VERSION`, `DOCKER_BUILDX_VERSION`, `DOCKER_COMPOSE_VERSION` |

`UV_SHA256`, `HCLOUD_SHA256`, and `SUPABASE_CLI_SHA256` MUST be refreshed in
lockstep with the matching `_VERSION` ARG — they verify the downloaded
tarball at build time, so a mismatch fails the build.

### Lookup procedure

For each pin, find the latest published version dated ≥7 days ago and
that is still available in the upstream repo (older versions are
sometimes garbage-collected).

Compute the cutoff timestamp portably (works on both Linux GNU `date`
and macOS BSD `date`):

```bash
T=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)
```

**npm packages** (`npm`, `pnpm`, `wrangler`, `@anthropic-ai/claude-code`,
`@openai/codex`, `@google/gemini-cli`):

```bash
curl -s "https://registry.npmjs.org/<pkg>" | jq -r --arg t "$T" '
  .time
  | to_entries
  | map(select((.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.value < $t)))
  | sort_by(.value) | last | .key'
```

**GitHub releases** (`uv`, `hcloud`, `supabase`):

```bash
curl -s "https://api.github.com/repos/<owner>/<repo>/releases" \
  | jq -r --arg t "$T" '
      map(select(.prerelease == false
                 and .draft == false
                 and .published_at < $t))
      | .[0].tag_name'
```

⚠️ For **hcloud** and **supabase**, GitHub tags are prefixed with `v`
(e.g. `v1.64.1`, `v2.98.2`) but the Dockerfile's `HCLOUD_VERSION` /
`SUPABASE_CLI_VERSION` ARGs are the version *without* the prefix (the
URL adds it back: `releases/download/v${HCLOUD_VERSION}/...`). Strip
the `v` before pasting: pipe the snippet above through
`sed 's/^v//'`.

For `uv` also fetch the matching SHA256 (update `UV_SHA256` alongside
`UV_VERSION`):

```bash
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz.sha256"
```

For `hcloud` also fetch the matching SHA256 (update `HCLOUD_SHA256`
alongside `HCLOUD_VERSION`). Hetzner publishes a single `checksums.txt`
covering every release asset; grep the linux-amd64 line:

```bash
curl -fsSL "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/checksums.txt" \
  | awk '$2 == "hcloud-linux-amd64.tar.gz" {print $1}'
```

For `supabase` also fetch the matching SHA256 (update
`SUPABASE_CLI_SHA256` alongside `SUPABASE_CLI_VERSION`). ⚠️ Supabase now
publishes a generic `checksums.txt`; the older version-embedded name
(`supabase_<VERSION>_checksums.txt`) 404s. The rows inside name the
**versioned** asset, while the Dockerfile downloads the unversioned
alias. Both names serve identical bytes, so grep the versioned row:

```bash
curl -fsSL "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/checksums.txt" \
  | awk -v f="supabase_${SUPABASE_CLI_VERSION}_linux_amd64.tar.gz" '$2 == f {print $1}'
```

**APT-installed** (`nodejs`, `tailscale`, `google-cloud-cli`,
`docker-*`, `infisical`): release dates aren't in the APT Packages
metadata. Get the list of available versions from the repo, then
cross-reference each vendor's changelog for the date.

Each recipe below prints the available versions in the upstream repo;
pick the latest one whose changelog entry is dated ≥7 days ago.

Where a vendor's changelog is awkward to machine-read (Docker,
Infisical), date the package from the repo itself instead. Every Debian
`Packages` entry carries a `Filename:` pointing into the pool; the
upload date is the pool file's HTTP `Last-Modified`:

```bash
# usage: pkgdate <packages-url> <repo-base-url> <pkg> <version>
pkgdate() {
  fn=$(curl -fsSL "$1" | awk -v p="$3" -v v="$4" \
    'BEGIN{re="^Package: "p"$"} $0~re{f=1;pv="";next} /^Package: /{f=0}
     f&&/^Version: /{pv=$2} f&&/^Filename: /{if(pv==v){print $2; exit}}')
  curl -sI "$2/$fn" | awk -F': ' 'tolower($1)=="last-modified"{print $2}'
}
```

**nodejs** — changelog: <https://nodejs.org/en/about/previous-releases>

```bash
curl -fsSL https://deb.nodesource.com/node_22.x/dists/nodistro/main/binary-amd64/Packages.gz \
  | gunzip \
  | awk '/^Package: nodejs$/{p=1} p && /^Version:/{print; p=0}'
```

**tailscale** — changelog: <https://tailscale.com/changelog>

```bash
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/dists/noble/main/binary-amd64/Packages \
  | awk '/^Package: tailscale$/{p=1} p && /^Version:/{print; p=0}'
```

**google-cloud-cli** — changelog: <https://cloud.google.com/sdk/docs/release-notes>

```bash
curl -fsSL https://packages.cloud.google.com/apt/dists/cloud-sdk/main/binary-amd64/Packages \
  | awk '/^Package: google-cloud-cli$/{p=1} p && /^Version:/{print; p=0}'
```

**docker-ce / docker-ce-cli / docker-ce-rootless-extras / containerd.io / docker-buildx-plugin / docker-compose-plugin** — changelog: <https://docs.docker.com/engine/release-notes/>. The three `docker-ce*` packages share a version string; the others are independent.

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-amd64/Packages \
  | awk -v pkg="docker-ce|containerd.io|docker-buildx-plugin|docker-compose-plugin" \
        'BEGIN{re="^Package: ("pkg")$"}
         $0~re{p=1; name=$2; next}
         /^Package:/{p=0}
         p && /^Version:/{print name, $2}'
```

**infisical** — changelog: <https://github.com/Infisical/infisical/releases>

```bash
curl -fsSL https://artifacts-cli.infisical.com/deb/dists/stable/main/binary-amd64/Packages \
  | awk '/^Package: infisical$/{p=1} p && /^Version:/{print; p=0}'
```

### After updating

**Commit AND push** the version bumps before running `provision.sh` —
that script clones from `origin`, so unpushed changes will not reach the
VPS. If a build step later fails with `version X.Y.Z not found`, the
chosen version was likely garbage-collected from the upstream repo;
pick the next-oldest qualifying version and retry.

## Phase 1: Hetzner Cloud (~5 min)

**Goal.** Two Hetzner projects (one for the agent VPS, one for their
real workloads), an admin token for the agent project, an apps token
for the workload project, a deny-all firewall in the agent project.

### Manual steps (have the user do these)

Open https://console.hetzner.cloud:

1. Create a new project, name it **`coding-agent-vps`**.
2. In that project → Security → API Tokens → Generate (Read & Write).
   Title: `Laptop admin — provision/destroy`. **Copy the token
   immediately** into their password manager — it's shown only once.
3. In that same project → Firewalls → Create. Name:
   `agent-vps-deny-all`. Leave all inbound rules empty (deny-all
   default). Don't attach it to anything yet.

Switch to (or create) a SECOND project for their actual workloads
(e.g., `apps`, or whatever they call it):

4. In the workloads project → API Tokens → Generate (Read & Write).
   Title: `coding-agent-vps agent — apps deploy`. Save this token —
   they'll paste it into Infisical in Phase 2.

> Why two projects: Hetzner tokens are project-scoped. The agent on
> the VPS gets only the apps-project token, so it can never see or
> delete its own VPS. The admin token lives only on the laptop.

### Automated steps (you, the agent)

On the user's laptop, install hcloud and set up the admin context:

```bash
brew install hcloud || sudo apt-get install -y hcloud-cli
hcloud context create coding-agent-vps-admin
```

When `hcloud context create` prompts for the token, have the user
paste from their password manager.

### Verify

```bash
hcloud context list      # `coding-agent-vps-admin` should be active (*)
hcloud firewall list     # `agent-vps-deny-all` should appear, 0 rules
```

If verification fails: most likely they're in the wrong Hetzner
project — confirm they ran step 3 inside `coding-agent-vps`, not the
workloads project.

## Phase 2: Infisical (~15 min)

**Goal.** Two Infisical projects (one host-side, one sandbox-side), required secrets populated in each. The split serves trust-zone isolation: host-side secrets are fetched by cred-daemon and live on the VPS at rest; sandbox-side cloud-CLI tokens are fetched per-command and never persist on the VPS.

### Manual steps (have the user do these)

1. Sign in at https://infisical.com. Note the URL they land on
   (typically `app.infisical.com`, but EU-region accounts land on
   `eu.infisical.com` directly — that's the URL to use for bootstrap).

2. **Create project A: `coding-agent-vps`** — host-side, holds the credentials cred-daemon manages.
   - Note the **Project ID** (Project → Settings → General, or the UUID in the project URL). This is `INFISICAL_PROJECT_ID` later.
   - Decide which environment to use. Ask the user: "Which Infisical environment do you want to populate? (default: `dev` — the slug, not the display name `Development`)". Note the slug. Same slug applies to BOTH projects.
   - Access Control → Identities → Create Identity:
     - Name: `coding-agent-vps-creds` (`<vps-name>-creds`: cred-daemon on that VPS)
     - Role: **Viewer** (read-only on secrets)
   - On the new identity, Add Authentication → Universal Auth.
   - Note the **Client ID** (UUID format like `d40df785-1383-...`). This is NOT the identity name.
   - Click "Create Client Secret":
     - TTL: `0` (no expiry)
     - Max uses: `0` (unlimited)
     - **Copy the secret immediately** to their password manager — shown once.

3. **Create project B: `coding-agent-vps-tooling`** — sandbox-side, holds account-wide cloud-CLI tokens.
   - Note the **Project ID**. This is `INFISICAL_TOOLING_PROJECT_ID` later.
   - Same environment slug as project A.

4. **Identity for the sandbox: `coding-agent-vps-agent`.** The sandbox reads Infisical as this machine identity, never as the user. The user's own account is an organization Admin and can read every project, the raw GitHub key in project A included, so it must never be logged in inside the sandbox.
   - Organization → Access Control → Machine Identities → Create:
     - Name: `coding-agent-vps-agent` (`<vps-name>-agent`: the sandbox on that VPS)
     - Organization role: **No Access**
   - On the new identity, add **Universal Auth**. Set Access Token TTL and Access Token Max TTL both to `3600`. The VPS refuses a longer-lived token (`daemon/agent-token.sh`). Leave the Trusted IPs fields alone: they need a paid plan.
   - Note the **Client ID**. Create a client secret (description `<vps-name> host`, no TTL, no max uses) and copy it to the password manager.
   - Add to Project → project B as **Viewer**, and later each app project the agent should use (USAGE.md "Using your app's secrets"). **Never** project A: the VPS checks this on every token refresh and cuts the sandbox off if it can read project A.

Now populate secrets, in their respective projects, environment `<slug>`:

**`coding-agent-vps` (project A):**

| Name | Required? | Value source |
|---|---|---|
| `github-ssh-key` | Yes (filled in Phase 4) | Generated in Phase 4 |
| `ntfy-topic` | Optional | `openssl rand -hex 8` — needed only if the user wants push notifications for credential-daemon failures (and installed the ntfy app earlier) |

**`coding-agent-vps-tooling` (project B):**

Secret names use the **env-var form** (uppercase, underscores) — each shim exports its secret under its own name, so naming them as env vars makes the CLIs read them directly.

| Name | Required? | Value source |
|---|---|---|
| `HCLOUD_TOKEN` | Yes | The apps-project token from Phase 1 step 4 |
| `CLOUDFLARE_API_TOKEN` | If they use Cloudflare | Cloudflare → My Profile → API Tokens |
| `GCP_SA_KEY_JSON` | If they use GCP | Existing service-account key JSON, entire content (single multi-line value) |
| `SUPABASE_ACCESS_TOKEN` | If they use Supabase | Supabase dashboard → Account → Access Tokens |

Tell the user: skip secrets they don't need. The PATH shims silently fall through to "command not found" if a token isn't populated; they can add more later by populating the secret in Infisical — no daemon restart needed (sandbox-side secrets are fetched per-command).

For per-app secrets (database URLs, anon keys, app-specific API keys), the user creates a **separate** Infisical project per app (e.g. `dobudex`). Those aren't part of v1 setup — see USAGE.md "Using your app's secrets".

### What you (the agent) need to know

The **user** keeps the following values in their password manager —
you do NOT need to see them. They'll type each value directly into
`bootstrap.sh`'s interactive prompts in Phase 6. Confirm with them
that they have each item recorded:

- `coding-agent-vps` Infisical project ID (project A)
- `coding-agent-vps-tooling` Infisical project ID (project B)
- Environment slug (lowercase, e.g. `dev`) — same for both
- Infisical URL (the URL their browser is on — `app.infisical.com` by default, `eu.infisical.com` for EU-region accounts)
- Universal Auth Client ID for project A's `coding-agent-vps-creds` identity (UUID)
- Universal Auth Client Secret for project A's `coding-agent-vps-creds` identity (shown once)
- Universal Auth Client ID for the `coding-agent-vps-agent` identity (UUID)
- Universal Auth Client Secret for the `coding-agent-vps-agent` identity (shown once)

**Do not ask the user to paste any of these into the chat.** Ask
"have you saved all eight values to your password manager?" and proceed
when they say yes.

### Verify

Nothing to verify here; `bootstrap.sh` tests the values in Phase 6:
cred-daemon logs in as `coding-agent-vps-creds`, and `agent-token.service`
logs in as `coding-agent-vps-agent` and checks it cannot read project A.

## Phase 3: Tailscale (~5 min)

**Goal.** Set the user's Tailscale policy so the VPS can join the
tailnet under `tag:coding-agent-vps`, the user's own devices can SSH
into it as the chosen user, and the VPS cannot open a connection to
the laptop or any other tailnet device. Then generate an auth-key
with the tag ticked.

The asymmetric reachability bounds the agent's blast radius — a
compromised sandbox cannot pivot to the user's laptop or other
tailnet devices.

### Background: how the Tailscale policy enforces the asymmetry

The policy file has separate sections, and Tailscale SSH needs two of
them:

- **`grants`** (or the older **`acls`**) allow network traffic between
  devices. Tailscale SSH is traffic to port 22, so the user's devices
  need a grant to the VPS.
- **`ssh`** says which source may log in as which user over Tailscale
  SSH. The VPS runs `tailscale up --ssh` and host OpenSSH is masked,
  so this is the only login path.
- **`tests`** (network) and **`sshTests`** (SSH logins) are
  assertions that Tailscale checks on every save. It rejects a save
  that breaks one.

A policy with **no `grants` and no `acls` section allows all
traffic** between all devices: Tailscale applies its default
allow-all policy. So a policy with only `ssh` rules lets the VPS
reach the laptop on every port. The first grant switches the whole
tailnet to deny-by-default, and from then on only granted traffic
flows. That applies to every device, so the grant below must also
cover what the user's other devices need from each other.

Connections are stateful. A grant from the laptop to the VPS lets the
replies come back, but it does not let the VPS start a connection to
the laptop.

The template names the user's **login** (the email shown at
https://login.tailscale.com/admin/users), not an autogroup:

- A login matches all of that person's devices: laptop, phone,
  tablet. A tagged device has no user, so the login never matches the
  VPS.
- `autogroup:member` matches every user in the tailnet, including
  anyone invited later.
- `autogroup:admin` matches users whose role is Admin. The tailnet
  Owner has the Owner role (`autogroup:owner`), so on a one-person
  tailnet `autogroup:admin` can match nobody.

### Manual steps (have the user do these)

Open https://login.tailscale.com/admin/acls/file. Look for the parts
that would let the VPS reach other devices:

1. **Default policy** of a new tailnet: an allow-all rule, either
   `"grants": [{"src": ["*"], "dst": ["*"], "ip": ["*"]}]` or
   `"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]`.
   Remove it. The grant below replaces it.
2. **No `grants` and no `acls` section**, for example only `ssh`
   rules: this is allow-all too. Add the grant below.
3. **Custom `grants` or `acls`**: remove or narrow every rule whose
   `src` can match the VPS: `*`, `tag:coding-agent-vps`,
   `autogroup:tagged` (every tagged device), or an IP range that
   covers the VPS. Keep the rest.

Have the user MERGE the following blocks into their existing policy.
**Add to the existing `tagOwners`/`grants`/`ssh`/`tests`/`sshTests`
sections; do not overwrite** entries that govern their other devices:

```jsonc
{
  // Required: declare the agent VPS tag.
  "tagOwners": {
    "tag:coding-agent-vps": ["autogroup:admin"]
  },

  // Required: the user's own devices may reach every device, the VPS
  // included (Tailscale SSH needs port 22). No grant has the VPS tag
  // as src, so the VPS cannot start a connection to anything.
  "grants": [
    {"src": ["<OWNER-LOGIN>"], "dst": ["*"], "ip": ["*"]}
  ],

  // Required: Tailscale SSH, only from the user's devices and only as
  // the chosen username. No `autogroup:nonroot`: with a tagged dst it
  // allows SSH as ANY non-root user.
  "ssh": [
    {
      "action": "accept",
      "src":    ["<OWNER-LOGIN>"],
      "dst":    ["tag:coding-agent-vps"],
      "users":  ["<USER>"]
    }
  ],

  // Required: network tests, checked on every save. An edit that lets
  // the VPS reach the laptop, or cuts the user's network path to VPS
  // port 22, is rejected.
  "tests": [
    {"src": "tag:coding-agent-vps", "deny": ["<LAPTOP-TAILNET-IP>:22", "<LAPTOP-TAILNET-IP>:443"]},
    {"src": "<OWNER-LOGIN>", "accept": ["tag:coding-agent-vps:22"]}
  ],

  // Required: SSH tests, also checked on every save. `tests` cannot
  // see the `ssh` rules, so this one catches an edit that removes the
  // user's login or opens root.
  "sshTests": [
    {"src": "<OWNER-LOGIN>", "dst": ["tag:coding-agent-vps"], "accept": ["<USER>"], "deny": ["root"]}
  ]
}
```

Substitute:

- `<OWNER-LOGIN>`: the user's Tailscale login email.
- `<USER>`: the username chosen earlier.
- `<LAPTOP-TAILNET-IP>`: the laptop's address, from `tailscale ip -4`
  on the laptop. Add deny entries for ports the laptop serves (local
  dev servers, databases).

If other people share the tailnet, give each person their own grant
for what they need. Never give the VPS tag a grant.

> **Critical — this is the single most-missed step:** when generating
> the auth-key in the next step, the user MUST tick
> `tag:coding-agent-vps` in the Tags field. Without it, the VPS join
> is silently rejected, cloud-init keeps running without it, and the
> VPS never appears in their tailnet. Emphasize this loudly.

8. Open https://login.tailscale.com/admin/settings/keys → Generate
   auth key with:
   - Reusable: **NO**
   - Ephemeral: **NO**
   - Expiration: ≤24h
   - Tags: **`tag:coding-agent-vps`** ← double-check the box is ticked
9. Copy the auth-key. They'll paste it when `provision.sh` prompts in
   Phase 5.

### Verify

Confirm with the user that the policy saved. Tailscale checks the
syntax and the `tests` block on save. Then have them open **Preview
rules** on the same page and pick `tag:coding-agent-vps`: it must say
the tag cannot access any ports. The join is verified in Phase 5, and
the reachability check runs in Phase 7, once the sandbox exists.

## Phase 4: GitHub SSH key (~3 min)

**Goal.** An ed25519 keypair: public half on the user's GitHub
account, private half pasted into Infisical as `github-ssh-key`.

### Automated steps (you, the agent)

Generate the keypair on the user's laptop:

```bash
ssh-keygen -t ed25519 -f ~/Downloads/coding-agent-vps-key \
  -C "coding-agent-vps@$(date +%Y-%m-%d)" -N ""
```

Print the public key so they can copy it:

```bash
cat ~/Downloads/coding-agent-vps-key.pub
```

### Manual steps (have the user do these)

1. Open https://github.com/settings/keys → New SSH key.
   - Title: `coding-agent-vps`
   - Type: Authentication Key
   - Paste the public key from above.
2. If the user has GitHub orgs with SAML SSO enforced: on that same
   page, click "Configure SSO" on the row of the new key and authorize
   each org they want private-repo access for. Without this, clones of
   org-private repos fail with a misleading "Repository not found".
3. Have the user open `~/Downloads/coding-agent-vps-key` (no .pub) and
   copy the **full PEM block** including the `-----BEGIN ...-----` and
   `-----END ...-----` lines.
4. Paste that into Infisical as secret name `github-ssh-key`.

### Automated steps (you, the agent — cleanup)

Securely delete the local keypair files:

```bash
shred -u ~/Downloads/coding-agent-vps-key{,.pub} || rm -f ~/Downloads/coding-agent-vps-key{,.pub}
```

### Verify

No verification yet — the key is exercised in Phase 7 inside the
sandbox.

## Phase 5: Provision the VPS (~10 min, mostly waiting)

**Goal.** A Hetzner VPS that cloud-init'd successfully, joined the
tailnet, built the sandbox image, and installed systemd units.

### Automated steps (you, the agent)

`provision.sh` auto-detects whether the repo is public or private:

- **Public repo**: cloud-init clones via HTTPS, no auth needed.
  No `gh` CLI required.
- **Private repo (i.e., a private fork)**: cloud-init clones via SSH
  using a read-only deploy key the script registers automatically.
  Requires `gh` installed and authed with `repo` scope:
  ```bash
  brew install gh || sudo apt-get install -y gh
  gh auth status || gh auth login
  ```

### Sign commits

The VPS runs this repo as root and pulls only commits signed by the
user's laptop signing key (see ARCHITECTURE.md "Only signed commits
reach root"). The same steps set up a later laptop (USAGE.md "New
laptop"). Git needs `user.email` set ("Make the repo the user's own").
Run no repo script until step 4 has passed.

1. **Key.** Use an SSH key that stays on the laptop. Any existing key
   of the user's works (`ls ~/.ssh/*.pub`), except the
   `coding-agent-vps` key from Phase 4, which lives on the VPS. On a
   later laptop, copy the old laptop's signing key pair over **now**
   if the user wants to keep it. If there is no key, make one; ask
   the user whether they want a passphrase (without one, anything
   running as the user on the laptop can sign):

   ```bash
   install -d -m 0700 ~/.ssh
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_signing -C "commit signing"
   ```

2. **Sign.** Point git at the **private** key file, so signing works
   without an ssh-agent:

   ```bash
   KEY=~/.ssh/id_ed25519_signing      # or the key chosen in step 1
   git config gpg.format ssh
   git config user.signingkey "$KEY"
   git config commit.gpgsign true
   ```

3. **Check incoming commits.** `provision.sh` runs from this checkout,
   so it must hold only commits the user signed or reviewed. Make
   pulls here check signatures too, against a key file outside the
   repo:

   ```bash
   echo "$(git config user.email) namespaces=\"git\" $(cut -d' ' -f1,2 "$(git config --type=path user.signingkey).pub")" >> ~/.ssh/allowed_signers
   git config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
   git config merge.verifySignatures true
   git config pull.rebase false
   git config pull.ff only            # a rebasing pull (even from branch.main.rebase) would skip the check
   git config gpg.openpgp.program false
   git config gpg.x509.program false
   ```

4. **Check the checkout itself.** A fresh clone was not checked. Go
   by the exit status: git prints `Good "git" signature` even for a
   key it does not trust.

   ```bash
   git verify-commit HEAD && echo VERIFIED
   ```

   - `VERIFIED`: done.
   - **A later laptop, and no `VERIFIED`:** someone pushed after the
     last commit the user approved, maybe the agent. The commit the
     VPS runs is a trusted baseline, since only verified pulls move
     it: `ssh <user>@coding-agent-vps sudo git -C /opt/agent-vps rev-parse HEAD`.
     Show the user `git diff <that hash> HEAD` (if git says "bad
     object", that commit is gone from GitHub, say after a force-push;
     diff on the VPS instead: `sudo git -C /opt/agent-vps fetch` then
     `sudo git -C /opt/agent-vps diff HEAD origin/main`; after signing,
     update the VPS with the verified reset in USAGE.md "`cloud-init
     status` shows error", since a plain pull cannot fast-forward) and
     continue only if they accept every change; then sign it:
     `git commit --allow-empty -m "Approve <what>" && git push`.
   - **A later laptop with a new key:** `provision.sh` accepts only a
     tip signed by this laptop's key, even if `VERIFIED` came from the
     old one. Once the VPS trusts the new key (USAGE.md "New laptop"),
     make that tip: `git commit --allow-empty -m "Sign with the new key" && git push`.
   - **A first setup, and it fails:** expected. The tip of a fresh
     copy is unsigned or signed by the template's author, and
     `provision.sh` stops unless it is signed by this key. Adopting
     the template is the user's call; then sign the tip:

     ```bash
     git commit --allow-empty -m "Sign the tip" && git push
     ```

From now on every commit here is signed, and a pull refuses a tip the
user did not sign (USAGE.md "Signed updates" has the review flow). A
pull also refuses when local and remote commits have diverged; then
`git fetch && git merge origin/main` merges a signed remote tip.

### Run provisioning

Run provisioning:

```bash
./scripts/provision.sh
```

The script will:
1. Detect repo visibility (public/private) and pick the clone strategy.
2. Check that origin's tip is signed by the signing key above, and put
   that key into the cloud-init user-data as the VPS's only trusted
   signer.
3. **For private repos only**: generate (if missing) a read-only ed25519
   deploy key at `~/.ssh/coding-agent-vps-deploy` and register it on
   the repo via `gh api` (idempotent).
4. Prompt for the Tailscale auth-key. The **user** pastes it
   directly into the `provision.sh` prompt (input is hidden — the
   key never reaches the chat with you).
5. Warn if the local checkout has unpushed commits or working-tree
   changes (cloud-init clones from origin, so local-only changes
   wouldn't reach the VPS).
6. Create the Hetzner CX23 VPS with the deny-all firewall attached at
   creation time.

After `provision.sh` returns, cloud-init runs in the background for
~5–10 min on the VPS. Poll for readiness:

```bash
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes)
until ssh "${SSH_OPTS[@]}" <USER>@coding-agent-vps \
        'test -f /etc/systemd/system/cred-daemon.service' 2>/dev/null; do
  sleep 30
done
echo "VPS ready."
```

If the poll never succeeds after 20 min, refer to `docs/USAGE.md`
Troubleshooting → "VPS never appears in `tailscale status`".

### Verify

```bash
ssh <USER>@coding-agent-vps \
  'systemctl is-enabled cred-daemon.service ssh-agent-creds.service ssh-agent-bridge.service'
# All three should print `enabled`.
```

## Phase 6: Bootstrap Infisical on the VPS (~3 min, interactive)

**Goal.** The cred-daemon has the Infisical bootstrap credentials and
has fetched all populated secrets at least once.

### Interactive — the user runs this; you stay out of the secret path

`bootstrap.sh` is interactive (it reads from stdin). Have the user SSH
in and run it themselves:

```bash
ssh <USER>@coding-agent-vps
sudo bash /opt/agent-vps/scripts/bootstrap.sh
```

Tell them the script will prompt for eight values in this order. They
paste each value from their password manager directly into the
prompt — **the values do not pass through you**:

| Prompt order | What they paste (from Phase 2) |
|---|---|
| 1. `coding-agent-vps` Infisical project ID | project A's project ID |
| 2. `coding-agent-vps-tooling` Infisical project ID | project B's project ID |
| 3. Infisical environment slug | the slug they chose (`dev` etc.) |
| 4. Infisical URL | their region URL |
| 5. Client ID | `coding-agent-vps-creds` Universal Auth Client ID UUID |
| 6. Client Secret | (hidden input — pasted from password manager) |
| 7. Client ID of the agent identity | `coding-agent-vps-agent` Universal Auth Client ID UUID |
| 8. Client secret | (hidden input — pasted from password manager) |

Prompts 7 and 8 come from `scripts/agent-identity.sh`, which
`bootstrap.sh` runs last. To rotate only the agent identity's client
secret later, run that script alone.

### Verify

The script prints `✓ Credential fetch succeeded.` and ends with
`✓ The sandbox now reads Infisical as the agent identity.` on success —
that's the only signal you need to surface; proceed to Phase 7.

If it errors, see [USAGE.md → Troubleshooting](./USAGE.md#troubleshooting)
for the specific symptom and recovery (don't preempt those with the
user — most runs succeed first try).

## Phase 7: Start sandbox + AI CLI logins (~5 min, interactive)

**Goal.** Sandbox container running; `claude` and `codex` logged in
via OAuth.

### Automated steps (have the user run, still in their SSH session)

```bash
cd /opt/agent-vps && docker compose up -d
docker exec -it sandbox tmux attach -t main
```

The user lands inside the sandbox's tmux session.

### Manual steps (have the user do these inside tmux)

```bash
claude login        # prints a URL; user opens it on their laptop, completes OAuth, pastes the code back
codex login         # same flow
gemini             # first run prompts for OAuth via Google sign-in (browser on the laptop)
```

All three OAuth flows are interactive and require browser access on the
user's laptop. They land tokens in `~/.claude/`, `~/.codex/`,
and `~/.gemini/`, which are mounted on named Docker volumes
(`sandbox-state-claude`, `sandbox-state-codex`, `sandbox-state-gemini`)
— survive container rebuild.

**Do not run `infisical login` in the sandbox.** The sandbox already
reads Infisical as `coding-agent-vps-agent` through the host's
`agent-token.timer`. A personal login would give the agent everything
the user's account can read (USAGE.md "Using the sandbox cloud CLIs").

### Verify (inside the sandbox tmux)

```bash
ssh -T git@github.com         # → "Hi <github-username>!"
claude --version              # prints a version
codex --version               # prints a version
hcloud server list            # via PATH shim — fetches HCLOUD_TOKEN from coding-agent-vps-tooling per-command
```

All four should succeed. If `ssh -T` fails with "Permission denied (publickey)": the cred-daemon may not have loaded the key. Check `sudo systemctl status ssh-agent-creds.service` and `sudo systemctl status cred-daemon.service` on the VPS. If `hcloud server list` fails with "no agent token" or an Infisical auth error: check `sudo systemctl status agent-token.service` and `sudo journalctl -u agent-token.service -n 20` on the VPS, and confirm `coding-agent-vps-agent` is a Viewer in `coding-agent-vps-tooling`.

### Verify the VPS cannot reach the laptop

This proves the Phase 3 policy in practice. First confirm the laptop
accepts incoming tailnet connections at all, or the test passes
whatever the policy says:

```bash
tailscale debug prefs | grep ShieldsUp    # must be "ShieldsUp": false
```

If it is `true`, switch "Allow incoming connections" on in the
Tailscale menu for the test, and off again afterwards. Then have the
user start a listener on the laptop, in a second terminal:

```bash
nc -lk 47777        # listens on every laptop interface, the tailnet one too; prints what it receives
```

Then, from the laptop (substitute `<LAPTOP-TAILNET-IP>` from Phase 3).
Each probe sends a marker line, so the listener shows who got
through:

```bash
# Control: the listener must print "control"
echo control | nc -w 2 <LAPTOP-TAILNET-IP> 47777
# From the VPS host
ssh <USER>@coding-agent-vps \
  'timeout 5 bash -c "exec 3<>/dev/tcp/<LAPTOP-TAILNET-IP>/47777 && echo from-host >&3"; echo "exit $?"'
# From inside the sandbox
ssh <USER>@coding-agent-vps \
  'docker exec sandbox timeout 5 bash -c "exec 3<>/dev/tcp/<LAPTOP-TAILNET-IP>/47777 && echo from-sandbox >&3"; echo "exit $?"'
```

Read the exit codes:

- `exit 124` from both probes is the pass. Tailscale drops the
  packets, so the connect times out, and the listener prints only
  `control`.
- `exit 0` means the VPS reached the laptop, and the listener prints
  `from-host` or `from-sandbox`.
  Some grant or `acls` rule matches the VPS, or the policy has neither
  section and is allow-all: go back to Phase 3.
- Any other exit code is inconclusive, not a pass. `exit 1` is
  usually "connection refused", which means the packet did reach the
  laptop. From the sandbox it can also mean the container is not
  running. Fix the cause and rerun.

The laptop's own firewall in stealth mode also drops packets, so it
can produce a false `exit 124`. Turn it off for the test, or allow
`nc`. Stop the listener with Ctrl-C afterwards.

## Wrap-up

Tell the user:

1. Setup is done. To return:
   ```bash
   ssh <USER>@coding-agent-vps
   docker exec -it sandbox tmux attach -t main
   ```
2. The Hetzner admin token in their password manager is the kill
   switch. From their laptop, any time the VPS misbehaves:
   ```bash
   hcloud context use coding-agent-vps-admin
   hcloud server delete coding-agent-vps
   ```
3. For credential rotation, incident response, rebuild, or
   troubleshooting, see `docs/USAGE.md`.

Confirm with the user that everything works (have them try `claude`
inside the sandbox) before considering setup complete.
