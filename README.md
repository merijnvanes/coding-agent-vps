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

- [ ] Sign up at https://infisical.com (free tier, no card needed).
- [ ] Create a project named `coding-agent-vps`.
- [ ] Access Control → Identities → Create Identity `agent-vps` with role
      **Viewer**. Add Universal Auth method. Generate a Client Secret with
      no TTL and no max-uses. Save **client ID + client secret** to laptop's
      password manager.
- [ ] Note the **project ID** from the project URL or settings — you'll need
      it during `bootstrap.sh`.

### Secrets to populate in Infisical

Add the following secrets to the `prod` environment of your Infisical project:

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

- [ ] You already have a Tailscale account on your laptop (otherwise see
      https://tailscale.com).
- [ ] Tailscale **ACL** (network-level): deny by default, with an explicit
      `accept` rule from your laptop to the agent-vps. **NO rule going the
      other direction.** Manage in https://login.tailscale.com/admin/acls.
- [ ] Tailscale **SSH policy** (a separate section in the same ACL file):
      Tailscale SSH is gated independently of the network ACL — you must
      add an `ssh` rule explicitly allowing your tailnet user to log in as
      `merijn` on the agent-vps. Example fragment:

      ```json
      {
        "ssh": [
          {
            "action": "accept",
            "src": ["autogroup:member"],
            "dst": ["tag:coding-agent-vps"],
            "users": ["merijn"]
          }
        ],
        "tagOwners": {
          "tag:coding-agent-vps": ["autogroup:member"]
        }
      }
      ```

      (The tag is applied at provision time via `tailscale up --advertise-tags=tag:coding-agent-vps`,
      or you can tag it manually after first connect.) Without this, the
      first `ssh merijn@coding-agent-vps` will be rejected even though the
      network ACL allows it.

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
│   ├── cred-daemon.sh         main fetch loop (Infisical → local cache + ssh-agent)
│   ├── cred-daemon.service    systemd unit (User=creds, oneshot)
│   ├── cred-daemon.timer      daily 04:00 UTC refresh
│   └── ssh-agent-creds.service long-running ssh-agent for the creds user
│
└── alerts/
    └── ntfy.sh                publishes to ntfy.sh + logs to stderr
```
