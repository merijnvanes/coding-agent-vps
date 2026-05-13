# coding-agent-vps

A Hetzner VPS for running AI coding CLIs (Claude Code, Codex) inside a
sandboxed Docker container with credentials held in a separate trust zone
and fetched from Infisical. Single-developer setup, ~€5/month.

The design — what we're building and why — lives in [REQUIREMENTS.md](./REQUIREMENTS.md)
and [ARCHITECTURE.md](./ARCHITECTURE.md). This README is the operational
walkthrough: pre-setup, provision, bootstrap, and rebuild.

---

## Pre-implementation checklist (one-time, ~30 min)

Before you can run `scripts/provision.sh`, these external services need to
be set up. None of this can be automated from inside the VPS — these are
the irreducible manual touchpoints.

### Hetzner Cloud

In **a new dedicated project named `coding-agent-vps`**:

- [ ] **Admin API token** — Security → API Tokens → Generate (Read & Write).
      Save to laptop's password manager.
      Description suggestion: `Laptop admin — provision, destroy, killswitch`
- [ ] **Firewall** named `agent-vps-deny-all` — Firewalls → Create. Leave
      inbound rules empty (deny-all default). Don't attach to anything yet.

In **your existing apps Hetzner project** (where deploys go):

- [ ] **Apps-scope API token** — Read & Write. Description: `coding-agent-vps agent — apps deploy (stored in Infisical)`.
      Copy → paste into Infisical as `hcloud-token`, then clear clipboard.

### Infisical

- [ ] Sign up at https://infisical.com (free tier, no card needed). Note
      whether your account lands on `us.infisical.com` or `eu.infisical.com`
      — that's your **URL** for the bootstrap prompt later (look at your
      browser address bar; `app.infisical.com` also works as an alias).
- [ ] Create a project named `coding-agent-vps`.
- [ ] **Note four things**, because `bootstrap.sh` will ask for all of them:
      | What `bootstrap.sh` asks for | Where to find it in Infisical |
      |---|---|
      | **Project ID** | Project URL slug (the UUID part), or Project → Settings → General |
      | **Environment slug** | Project Settings → Environments → "Slug" column. `Development` → `dev`, `Production` → `prod`, etc. The slug is what the daemon uses, NOT the display name. Pick whichever env you'll populate secrets into. |
      | **Universal Auth Client ID** | Access Control → Identities → `agent-vps` → click into the row → Authentication Methods → Universal Auth → **Client ID** field (UUID format like `d40df785-1383-...`). **Not** the identity's name. **Not** the identity's own ID. |
      | **Universal Auth Client Secret** | On the same Universal Auth page → Create Client Secret → TTL `0`, Max uses `0`. Shown **only once at creation** — copy to password manager immediately. |
- [ ] Access Control → Identities → Create Identity `agent-vps` with role
      **Viewer**. Add **Universal Auth** authentication method. Generate
      a Client Secret with TTL=0, MaxUses=0. Save both **Client ID** and
      **Client Secret** to laptop password manager **before navigating
      away** (the secret is unrecoverable after).

### Secrets to populate in Infisical

Add the following secrets to your chosen environment (matching the slug
you noted above):

| Name | Value | Required? |
|---|---|---|
| `github-ssh-key`     | Private key (full PEM block) generated for the agent | Yes |
| `hcloud-token`       | The apps-scope token from above | Yes |
| `cloudflare-token`   | Cloudflare API token with the scopes you need | Yes if you use Cloudflare |
| `gcp-sa-key`         | GCP service-account key JSON (entire file content) | Yes if you use GCP |
| `npm-token`          | npm Automation token | Optional |
| `pypi-token`         | PyPI API token | Optional |
| `ntfy-topic`         | Unguessable string, e.g. `agent-vps-<openssl rand -hex 8>` | Yes (otherwise no alerts) |

For each cloud provider you don't use, just skip its secret. The daemon
silently skips missing secrets; adding one later and restarting the daemon
turns that integration on.

### GitHub SSH key

```bash
ssh-keygen -t ed25519 -f ~/Downloads/coding-agent-vps-key -C "coding-agent-vps@$(date +%Y-%m-%d)" -N ""
```

- [ ] Public key (`.pub`) → GitHub → Settings → SSH and GPG keys → New SSH
      key. Title: `coding-agent-vps`.
- [ ] Private key → Infisical as `github-ssh-key` (paste full PEM block,
      including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END`
      lines).
- [ ] Securely delete the local files:
      `shred -u ~/Downloads/coding-agent-vps-key{,.pub}`

### Tailscale

You already have a Tailscale account on your laptop (otherwise see
https://tailscale.com).

**This part has the most common first-time stumbles.** Tailscale gates the
agent-vps in three independent places — *all three* must be set, or the
VPS won't join the tailnet (and you'll only find out by watching
`/var/log/cloud-init-output.log` because `tailscale up` exits non-zero
silently and cloud-init keeps going).

#### 1. ACL — `tagOwners` must include `tag:coding-agent-vps`

Open https://login.tailscale.com/admin/acls/file. Your ACL file *must*
declare an owner for the tag, or `tailscale up --advertise-tags=tag:coding-agent-vps`
is rejected at join time:

```jsonc
{
  "tagOwners": {
    "tag:coding-agent-vps": ["autogroup:admin"]   // or autogroup:member
  }
}
```

Merge this with any existing `tagOwners` block (don't overwrite). If you
already have e.g. `tag:server` declared, add this as a sibling key.

#### 2. ACL — `ssh` rule for the tag

Same ACL file — Tailscale SSH is gated independently of the network ACL:

```jsonc
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:coding-agent-vps"],
      "users":  ["merijn", "autogroup:nonroot"]
    }
  ]
}
```

(Merge with any existing `ssh` block — you can list multiple `dst` tags
in one rule.)

#### 3. Auth-key — generate WITH the tag checked

When you generate the auth-key at https://login.tailscale.com/admin/settings/keys
(per-provision, generate fresh each time):

- Reusable: **NO**
- Ephemeral: **NO**
- Expiration: **≤24h**
- **Tags: tick `tag:coding-agent-vps`** ← this is the single most-missed step

> Belt-and-suspenders: even though step 1 (tagOwners) alone is enough to
> let `--advertise-tags` succeed, pre-applying the tag on the auth-key
> means the device is tagged from the moment it joins, rather than
> joined-then-self-tagged. Cleaner audit trail.

### Laptop

- [ ] `brew install hcloud` (if not already)
- [ ] `hcloud context create coding-agent-vps-admin` → paste the Hetzner
      admin token when prompted.
- [ ] `brew install gh` and `gh auth login` with `repo` scope. `provision.sh`
      uses it to register a read-only deploy key on the private repo
      (auto-generated at `~/.ssh/coding-agent-vps-deploy`, idempotent — the
      same key is reused across reprovisions). No manual GitHub UI step.

### Phone

- [ ] Install the **ntfy** app. Subscribe to the topic you chose for
      `ntfy-topic`. Save the topic name in your password manager.

---

## First provision

After the checklist above is complete, from the repo root on your laptop:

```bash
./scripts/provision.sh
```

This:
1. Asks for a freshly-generated Tailscale auth-key (single-use, ≤24h TTL)
2. Substitutes it into `cloud-init.yaml`
3. Calls `hcloud server create` to launch a CX22 with the deny-all firewall
   attached at server creation
4. Cloud-init takes 5–10 min: install packages → Tailscale → clone repo
   → run `scripts/cloud-init-tasks.sh` → users + groups + rootless Docker
   + build sandbox image + install systemd units

When it's done, the server appears in your tailnet. SSH in:

```bash
ssh merijn@coding-agent-vps
```

(Uses Tailscale SSH — no keys to manage.)

Then paste the Infisical bootstrap secret:

```bash
sudo bash /opt/agent-vps/scripts/bootstrap.sh
```

It prompts for project ID, environment, URL, client ID, client secret. On
success, it triggers an immediate credential fetch and tells you what to
run next.

Final step (as the `merijn` user):

```bash
sudo -u merijn -H bash -lc 'cd /opt/agent-vps && docker compose up -d'
```

The container starts detached. The container's entrypoint runs
`tmux new -A -s main` on its own internal TTY; you attach to that session
explicitly:

```bash
sudo -u merijn -H bash -lc 'docker exec -it sandbox tmux attach -t main'
```

You're now inside the tmux session in the sandbox. Log in to your AI
subscriptions interactively:

```bash
claude login   # interactive OAuth, browser flow on your laptop
codex login    # same
```

Detach from tmux (`Ctrl-b d`) and you're done.

---

## Day-to-day use

- **Enter the sandbox**: `ssh merijn@coding-agent-vps`, then
  `sudo -u merijn -H bash -lc 'docker exec -it sandbox tmux attach -t main'`.
- **Run an agent**: from inside the sandbox, just run `claude` or `codex`.
- **Persistent sessions**: tmux is the default entrypoint, so sessions
  survive SSH disconnects.
- **Project workspace**: `/work` inside the sandbox is bind-mounted from
  `/srv/dev/projects/` on the host.

---

## Rotating credentials

Per [REQUIREMENTS.md §5](./REQUIREMENTS.md#5-security-requirements),
**credential rotation is the user's responsibility**, not the daemon's.
The daemon only fetches the current value from Infisical.

To rotate a credential:
1. Update the value in Infisical (web UI).
2. SSH into the VPS and run `sudo systemctl start cred-daemon` to pull the
   new value immediately, OR wait for the daily 04:00 UTC refresh.
3. For env-var credentials (`CLOUDFLARE_API_TOKEN`, `HCLOUD_TOKEN`, etc.):
   running tmux windows keep the stale value until you open a new window or
   `exec $SHELL`.

---

## Incident response

If you suspect the VPS is compromised:

1. **Revoke the VPS's Infisical access**: Infisical web UI → Access Control
   → Identities → `agent-vps` → revoke the Universal Auth client secret.
   The cred-daemon's next refresh will fail.
2. **Revoke each upstream credential**: GitHub SSH key, Cloudflare token,
   GCP SA key, Hetzner apps token. Manual UI clicks per service.
3. **Revoke OAuth grants** at https://console.anthropic.com (Claude) and
   https://platform.openai.com (Codex). The refresh tokens in the sandbox
   volume are NOT affected by Infisical revocation.
4. **Kill the VPS** from the Hetzner Cloud Console (uses your laptop's
   admin token, not the agent's). Delete the server entirely.
5. **Provision a fresh one** with `scripts/provision.sh`.

---

## Rebuild from scratch

To replace the VPS (e.g., after an OS-level issue or just to test the
flow):

```bash
./scripts/provision.sh
```

The script detects an existing server with the same name and asks before
deleting it.

**Two flavors of rebuild:**

- **Container rebuild** (most common — Dockerfile change, image refresh):
  Docker volumes (`sandbox-state-claude`, `sandbox-state-codex`) persist
  on the VPS's local disk. `claude login` / `codex login` not needed
  again. Run: `sudo -u merijn -H bash -lc 'cd /opt/agent-vps && docker compose up -d --build'`
- **Full VPS rebuild** (running `scripts/provision.sh`): the existing
  server is deleted, including all local disk and Docker volumes. You
  redo the OAuth logins. Adds ~2 min. To survive a full VPS rebuild you'd
  need a separately-attached Hetzner Cloud volume, which is not in v1
  scope (REQUIREMENTS.md §6: backups are WON'T-v1).

---

## Troubleshooting

A small catalogue of failure modes seen during real provisioning, with
the diagnostic that pinpoints each.

### VPS never appears in `tailscale status` after ~5 min

Cloud-init's `tailscale up` was rejected. Two common causes:

1. **`tagOwners` missing** for `tag:coding-agent-vps` in your Tailscale
   ACL (see [Tailscale §1](#1-acl--tagowners-must-include-tagcoding-agent-vps)).
2. **Auth-key generated without the tag** ticked (see [§3](#3-auth-key--generate-with-the-tag-checked)).

To confirm before destroying anything: https://login.tailscale.com/admin/machines
— if the VPS isn't listed at all, the join was rejected (no entry, not
even a pending one). Recovery: fix the ACL, regenerate a tagged auth-key,
`hcloud server delete coding-agent-vps`, re-run `provision.sh`.

### `bootstrap.sh` fails with HTTP 422 from Infisical

The cred-daemon got an HTTP 422 "Unprocessable Entity" from the auth
endpoint. Almost always: **Client ID was pasted incorrectly** — typically
the identity's *name* (e.g. `agent-vps`) instead of the Universal Auth
**Client ID UUID** (e.g. `d40df785-1383-45df-be19-38cd847bef35`).

Diagnostic:

```bash
sudo journalctl -u cred-daemon.service -n 20 --no-pager
```

Look for `curl: (22) ... error: 422`. Re-run `bootstrap.sh` and use the
UUID from Access Control → Identities → `agent-vps` → Universal Auth.

### Cloud-init seems stuck (no progress for 15+ min)

SSH in (the merijn user is created early in cloud-init-tasks.sh) and
check status:

```bash
sudo cloud-init status                                    # done | running | error
sudo tail -80 /var/log/cloud-init-output.log              # see where it stopped
pgrep -af cloud-init-tasks.sh                             # is the host-setup still running?
pgrep -af "docker.*build"                                 # is the image build the slow step?
```

The slowest legitimate step is `docker build` of the sandbox image (~5–8
min on a CX23). If it failed, the log shows the exact Dockerfile step.

### `cloud-init status` shows `error`

Cloud-init aborted at some `runcmd`/script step. After fixing whatever
went wrong, the safest recovery is:

```bash
sudo git -C /opt/agent-vps pull                           # if the fix is upstream
sudo bash /opt/agent-vps/scripts/cloud-init-tasks.sh      # idempotent, re-runs cleanly
```

You don't need to destroy and reprovision unless the failure was in
cloud-init.yaml itself (Tailscale join, git clone) — `cloud-init-tasks.sh`
is fully idempotent.

---

## File layout

```
.
├── REQUIREMENTS.md            design decisions
├── ARCHITECTURE.md            concrete component layout
├── README.md                  this file
│
├── cloud-init.yaml            minimal cloud-init template (Tailscale + clone repo + run cloud-init-tasks.sh)
├── docker-compose.yml         sandbox container spec
│
├── scripts/
│   ├── provision.sh           laptop-side: hcloud server create wrapper
│   ├── cloud-init-tasks.sh    runs at first boot: users, groups, rootless Docker, build image, systemd
│   └── bootstrap.sh           post-SSH: paste Infisical bootstrap secret, start daemon
│
├── sandbox/
│   ├── Dockerfile             sandbox image
│   ├── entrypoint.sh          container entrypoint (sets SSH_AUTH_SOCK, exec tmux)
│   └── profile.d-agent-env.sh sourced by interactive shells inside the container
│
├── daemon/
│   ├── cred-daemon.sh           main fetch loop (Infisical → local cache + ssh-agent)
│   ├── cred-daemon.service      systemd unit (User=creds, oneshot)
│   ├── cred-daemon.timer        daily 04:00 UTC refresh
│   ├── ssh-agent-creds.service  long-running ssh-agent for the creds user
│   └── ssh-agent-bridge.service socat relay so the sandbox (mapped UID) can use the agent
│
└── alerts/
    └── ntfy.sh                publishes to ntfy.sh + logs to stderr
```
