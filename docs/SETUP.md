# Setup guide

> **This document is written for an AI coding agent to follow on behalf
> of the user setting up coding-agent-vps.** It is not a tutorial for a
> human to read top-to-bottom — the human's view of the flow is the
> agent walking them through it.

## How to use this document

**If you are the AI agent:** Walk through each phase in order. Drive
autonomously — ask the user for input only when you genuinely cannot
proceed without it (web-UI clicks, OAuth flows, secret values). After
each phase, briefly tell the user what just happened. If you hit a
verification failure, refer the user to `docs/USAGE.md` Troubleshooting
and surface the specific symptom.

**If you are the human:** paste the prompt from the README into your
agent and let it drive. Stay near the keyboard — you'll be asked to
click through browser tabs.

## Phase 0: Provider choices

This repo is a template. The default implementation uses:

| Role | Default | Provider-specific code |
|---|---|---|
| Cloud VPS | Hetzner Cloud | `scripts/provision.sh`, parts of `cloud-init.yaml` |
| Secret store | Infisical | `daemon/cred-daemon.sh` (auth + fetch), `scripts/bootstrap.sh` (prompts) |
| Network + SSH | Tailscale | `cloud-init.yaml` (install + `tailscale up`), Tailscale ACL config |
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
not a config-flag swap — it's modifying the provider-specific code in
the files listed above. The high-level shape of each integration is
the same; only the concrete API calls / CLIs / config syntax differ.

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
   `hcloud-token`, etc.) so the rest of the wire-up is unchanged.

3. **Network access** — pick the equivalent of Tailscale (WireGuard
   self-hosted, Cloudflare Zero Trust, Twingate). The required shape
   is: deny-all inbound at the firewall, and an authenticated overlay
   network the user's laptop joins. The current Tailscale-specific
   parts: `cloud-init.yaml` (install + `tailscale up --ssh`), ACL
   instructions in this guide (Phase 3 below). Tailscale SSH is
   nice-to-have but not load-bearing — you can fall back to standard
   SSH + Tailscale-only port exposure.

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

**Optional:** push notifications when credentials fail to refresh.
If the user wants this, have them install the [ntfy](https://ntfy.sh)
app on their phone now — they'll subscribe to a topic in Phase 2.
Without it, the same alerts still land in `journalctl -u cred-daemon`
on the VPS; the user just won't get a phone buzz.

If anything is missing, pause and have them sign up first.

## Choose the user's shell username

Default username on the VPS is `merijn` (cosmetic — it's what they SSH
in as). They can pick any other valid Linux username.

Ask the user: "What username do you want for SSH login to the VPS?
(default: `merijn`)"

If anything other than `merijn`, do a repo-wide replace before running
provision.sh:

```bash
NEW_USER="<their-choice>"
# All files that reference the username (excluding docs and git history).
# Uses perl rather than sed because GNU sed's `\b` word-boundary is not
# portable to macOS BSD sed (it would silently match nothing).
git grep -l '\bmerijn\b' | grep -v '^docs/' | xargs perl -i -pe "s/\bmerijn\b/$NEW_USER/g"
git diff --stat            # show them what changed
```

Confirm with the user before continuing. The change isn't committed
yet — they can review.

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

## Phase 2: Infisical (~10 min)

**Goal.** Infisical project, `agent-vps` identity with Universal Auth,
required secrets populated.

### Manual steps (have the user do these)

1. Sign in at https://infisical.com. Note which region URL they land
   on — `us.infisical.com` or `eu.infisical.com` (`app.infisical.com`
   also works as an alias). You need this for the bootstrap step.
2. Create a project named `coding-agent-vps`.
3. Note the **Project ID** from Project → Settings → General (or the
   UUID in the project URL).
4. Decide which environment to use. Ask the user: "Which Infisical
   environment do you want to populate? (default: `dev` — the slug,
   not the display name `Development`)". Note the slug.
5. Access Control → Identities → Create Identity.
   - Name: `agent-vps`
   - Role: **Viewer** (read-only on secrets)
6. On the new identity, Add Authentication → Universal Auth.
7. Note the **Client ID** (UUID format like `d40df785-1383-...`).
   This is NOT the identity name and NOT the identity's own ID.
8. Click "Create Client Secret" on the same page.
   - TTL: `0` (no expiry)
   - Max uses: `0` (unlimited)
   - **Copy the secret immediately** to their password manager — it's
     shown only once.

Now populate secrets in the chosen environment. Direct them to
Secrets → New Secret for each:

| Name | Required? | Value source |
|---|---|---|
| `github-ssh-key` | Yes (filled in Phase 4) | Generated in Phase 4 |
| `hcloud-token` | Yes | The apps-project token from Phase 1 step 4 |
| `cloudflare-token` | If they use Cloudflare | Cloudflare → My Profile → API Tokens |
| `gcp-sa-key` | If they use GCP | Existing service-account key JSON, entire content |
| `npm-token` | Optional | npm → Profile → Access Tokens |
| `pypi-token` | Optional | PyPI → Account Settings → API Tokens |
| `ntfy-topic` | Optional | `openssl rand -hex 8` — only needed if the user wants push notifications for credential failures (and installed the ntfy app earlier) |

Tell the user: skip secrets they don't need. The cred-daemon silently
skips missing secrets; they can add more later by populating the
secret and running `sudo systemctl start cred-daemon` on the VPS.

### Automated steps (you, the agent)

Hold onto these values — `bootstrap.sh` will need them in Phase 6:

- Infisical project ID
- Environment slug
- Infisical URL (matching their region)
- Client ID
- Client Secret

### Verify

Nothing to verify here; the values are tested when the daemon runs in
Phase 6.

## Phase 3: Tailscale (~5 min)

**Goal.** ACL that (a) lets the user's laptop reach the VPS, (b) blocks
the reverse direction (VPS cannot initiate connections back to the
laptop or other tailnet devices), plus a Tailscale SSH policy and an
auth-key generated with the tag ticked.

The reverse-direction block is what bounds the agent's blast radius —
a compromised sandbox cannot port-scan the user's laptop or pivot to
other devices on their tailnet.

### Manual steps (have the user do these)

Open https://login.tailscale.com/admin/acls/file. The user's existing
ACL is one of two shapes:

- **Default Tailscale ACL** for new tailnets: a single rule
  `{"action":"accept","src":["*"],"dst":["*:*"]}` — allow everything.
  This rule MUST go (otherwise the VPS→laptop direction stays open
  and the explicit rule below is shadowed).
- **Customized ACL** with multiple rules: confirm there is no rule
  with `"src": ["tag:coding-agent-vps"]` or `"src": ["*"]` that would
  let traffic flow *from* the VPS.

Have the user MERGE these blocks into their ACL (replacing any
catch-all `*→*` rule):

```jsonc
{
  // Network ACL: laptop can reach the VPS; VPS cannot reach the laptop
  // (no rule with src: tag:coding-agent-vps, on purpose).
  "acls": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:coding-agent-vps:*"]
    }
  ],

  "tagOwners": {
    "tag:coding-agent-vps": ["autogroup:admin"]
  },

  // Tailscale SSH is gated independently of the network ACL above.
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:coding-agent-vps"],
      "users":  ["<USER>", "autogroup:nonroot"]
    }
  ]
}
```

(Substitute `<USER>` with the username chosen earlier. If they already
have `acls`/`tagOwners`/`ssh` blocks for other devices, merge sibling
entries into them rather than overwriting.)

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

Confirm with the user that the ACL is saved (Tailscale validates
syntax on save). Real join verification happens in Phase 5.

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

Ensure `gh` is installed and authed (used to register the read-only
deploy key for the repo clone):

```bash
brew install gh || sudo apt-get install -y gh
gh auth status || gh auth login   # browser flow, needs `repo` scope
```

Run provisioning:

```bash
./scripts/provision.sh
```

The script will:
1. Generate (if missing) a read-only ed25519 deploy key at
   `~/.ssh/coding-agent-vps-deploy` and register it on the repo via
   `gh api` (idempotent).
2. Prompt for the Tailscale auth-key. **Ask the user to paste it** at
   that prompt (input is hidden).
3. Create the Hetzner CX23 VPS with the deny-all firewall attached at
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

### Interactive — have the user do this, you provide the values

`bootstrap.sh` is interactive (it reads from stdin). Have the user SSH
in and run it:

```bash
ssh <USER>@coding-agent-vps
sudo bash /opt/agent-vps/scripts/bootstrap.sh
```

Provide the values one by one as it prompts:

| Prompt | Value (from Phase 2) |
|---|---|
| Infisical project ID | their project ID |
| Infisical environment slug | the slug they chose (`dev` etc.) |
| Infisical URL | their region URL |
| Client ID | the Universal Auth Client ID UUID |
| Client Secret | (hidden input — they paste from password manager) |

### Verify

If bootstrap prints `✓ Credential fetch succeeded.`, proceed.

If it errors and points to `journalctl`:

```bash
sudo journalctl -u cred-daemon.service -n 20 --no-pager
```

- `error: 422`: Client ID was wrong (typically pasted the identity
  *name* instead of the UUID). Re-run bootstrap with the correct value.
- `error: 401`: Client Secret typo. Re-run.

After success, verify credentials landed:

```bash
ssh <USER>@coding-agent-vps 'sudo ls /var/lib/agent-vps/agent-config/env'
```

You should see at minimum `hetzner.sh` (and any other env-export files
matching the secrets they populated).

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
claude login    # prints a URL; user opens it on their laptop, completes OAuth, pastes the code back
codex login     # same flow
```

Both OAuth flows are interactive and require browser access on the
user's laptop. Tokens land in `~/.claude/` and `~/.codex/`, which are
mounted on named Docker volumes (`sandbox-state-claude`,
`sandbox-state-codex`) — survive container rebuild.

### Verify (inside the sandbox tmux)

```bash
ssh -T git@github.com         # → "Hi <github-username>!"
claude --version              # prints a version
codex --version               # prints a version
```

All three should succeed. If `ssh -T` fails with "Permission denied
(publickey)": the cred-daemon may not have loaded the key. Check
`sudo systemctl status ssh-agent-creds.service` and
`sudo systemctl status cred-daemon.service` on the VPS.

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
