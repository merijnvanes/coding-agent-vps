# Operational reference

Day-to-day usage, credential rotation, incident response, rebuild, and
troubleshooting for an already-provisioned coding-agent-vps.

If you haven't provisioned yet, see [SETUP.md](./SETUP.md).

## Daily use

```bash
ssh <user>@coding-agent-vps                       # Tailscale SSH, no keys to manage
docker exec -it sandbox tmux attach -t main       # attach to your running session
```

Inside the sandbox, just run `claude` or `codex`. Your workspace is
`/work` (bind-mounted from `/srv/dev/projects/` on the host). tmux
persists across SSH disconnects.

Detach tmux with `Ctrl-b d`. Mouse-wheel scrollback works (mouse mode
is on by default).

## Rotating credentials

Per [REQUIREMENTS.md §5](./REQUIREMENTS.md#5-security-requirements),
credential rotation is the **user's** responsibility — the daemon only
fetches the current value from Infisical.

To rotate:

1. Update the value in Infisical (web UI).
2. SSH into the VPS and run:
   ```bash
   sudo systemctl start cred-daemon
   ```
   to pull the new value immediately. Or wait for the daily 04:00 UTC
   refresh.
3. For env-var credentials (`CLOUDFLARE_API_TOKEN`, `HCLOUD_TOKEN`,
   etc.): existing tmux windows keep the stale value until you open a
   new tmux window or run `exec $SHELL`.

## Adding push alerts later

If you skipped ntfy during setup but want push notifications now:

1. Install the [ntfy](https://ntfy.sh) app on your phone.
2. Generate a random topic name: `openssl rand -hex 8`.
3. Subscribe to that topic in the ntfy app.
4. In Infisical, add a new secret `ntfy-topic` with that value (in the
   same environment you populated other secrets).
5. SSH into the VPS and force a refresh:
   ```bash
   sudo systemctl start cred-daemon
   ```

From that point on, cred-daemon failures (Infisical unreachable,
invalid SSH key uploaded, etc.) will buzz your phone. The alerts that
fired in the meantime are in `journalctl -u cred-daemon.service` on
the VPS.

## Killing the VPS

The kill switch is the Hetzner admin token, which lives only on your
laptop's password manager + `hcloud` context. From your laptop:

```bash
hcloud context use coding-agent-vps-admin
hcloud server delete coding-agent-vps
```

The agent inside the VPS has no path to this token and no way to
prevent deletion — Hetzner's control plane operates upstream of any
in-VM state.

## Incident response

If you suspect the VPS is compromised:

1. **Revoke the VPS's Infisical access.** Infisical → Access Control
   → Identities → `agent-vps` → revoke the Universal Auth client
   secret. The cred-daemon's next refresh will fail.
2. **Revoke each upstream credential** at the issuing service: GitHub
   SSH key (Settings → SSH and GPG keys → Delete), Cloudflare token,
   GCP SA key, Hetzner apps token. Manual UI clicks per service.
3. **Revoke OAuth grants** at https://console.anthropic.com (Claude)
   and https://platform.openai.com (Codex). The refresh tokens in the
   sandbox volume are NOT affected by Infisical revocation, so they
   must be revoked at the OAuth issuer directly.
4. **Kill the VPS:**
   ```bash
   hcloud context use coding-agent-vps-admin
   hcloud server delete coding-agent-vps
   ```
5. **Reprovision** by running `./scripts/provision.sh` (or by having
   your agent walk you through SETUP.md again — much shorter the
   second time since external services are already configured).

## Rebuild

Two flavors of rebuild, in order of disruption:

### Container rebuild (most common)

For Dockerfile changes or a fresh image pull:

```bash
ssh <user>@coding-agent-vps
cd /opt/agent-vps && docker compose up -d --build
```

Named volumes (`sandbox-state-claude`, `sandbox-state-codex`) persist —
no OAuth re-login. Your tmux session is killed on container recreation
(it's a process inside the container); reattach afterward.

### Full VPS rebuild

For OS-level issues or just to test the flow end-to-end:

```bash
./scripts/provision.sh
```

The script detects an existing server with the same name and asks
before deleting it. All local disk and Docker volumes are lost —
OAuth logins must be redone. Total time: ~10 min cloud-init + ~5 min
bootstrap + OAuth.

To survive a full VPS rebuild without redoing OAuth, you'd need a
separately-attached Hetzner Cloud volume — not in v1 scope (see
[REQUIREMENTS.md §6](./REQUIREMENTS.md): backups are WON'T-v1).

## Troubleshooting

### VPS never appears in `tailscale status` after ~5 min

Cloud-init's `tailscale up` was rejected. Two common causes:

1. **`tagOwners` missing** for `tag:coding-agent-vps` in your
   Tailscale ACL (see [SETUP.md Phase 3](./SETUP.md#phase-3-tailscale-5-min)).
2. **Auth-key generated without the tag** ticked.

To confirm: open https://login.tailscale.com/admin/machines. If the
VPS isn't listed at all, the join was rejected (silent failure — no
"pending approval" entry). Fix the ACL, regenerate a tagged auth-key,
`hcloud server delete coding-agent-vps`, re-run `provision.sh`.

### `bootstrap.sh` fails with HTTP 422 from Infisical

Almost always: **Client ID was pasted incorrectly** — typically the
identity's *name* (e.g. `agent-vps`) instead of the Universal Auth
Client ID UUID (e.g. `d40df785-1383-...`).

Confirm:

```bash
sudo journalctl -u cred-daemon.service -n 20 --no-pager
```

Look for `curl: (22) ... error: 422`. Re-run `bootstrap.sh` and use
the UUID from Access Control → Identities → `agent-vps` →
Authentication Methods → Universal Auth → Client ID.

### Cloud-init seems stuck (no progress for 15+ min)

SSH in (the user is created early in cloud-init-tasks.sh) and check:

```bash
sudo cloud-init status                           # done | running | error
sudo tail -80 /var/log/cloud-init-output.log     # see where it stopped
pgrep -af cloud-init-tasks.sh                    # is host-setup still running?
pgrep -af "docker.*build"                        # is image build the slow step?
```

The slowest legitimate step is `docker build` of the sandbox image
(~5–8 min on a CX23). If it failed, the log shows the exact Dockerfile
step.

### `cloud-init status` shows `error`

Cloud-init aborted at some script step. After fixing whatever went
wrong, the safest recovery is:

```bash
sudo git -C /opt/agent-vps pull                          # if the fix is upstream
sudo bash /opt/agent-vps/scripts/cloud-init-tasks.sh     # idempotent
```

You don't need to destroy and reprovision unless the failure was in
`cloud-init.yaml` itself (Tailscale join, git clone) — `cloud-init-tasks.sh`
is fully idempotent.

### Inside the sandbox: `ssh -T git@github.com` says "Permission denied"

The cred-daemon hasn't loaded the GitHub SSH key into the agent (or
the bridge service isn't running). Check both:

```bash
ssh <user>@coding-agent-vps '
  sudo systemctl status ssh-agent-creds.service ssh-agent-bridge.service --no-pager | head -20
  sudo systemctl start cred-daemon                                        # force a refresh
'
```

Common cause: the `github-ssh-key` secret in Infisical is empty or
malformed (e.g., missing the `-----BEGIN ...-----` header). Open
Infisical and re-paste the full PEM block.

### Inside the sandbox: `claude` or `codex` says "native binary not installed"

The sandbox image was built before commit `1dbc5a3` (the `--allow-build`
fix for pnpm 10+'s default-deny on install scripts). Rebuild:

```bash
ssh <user>@coding-agent-vps
cd /opt/agent-vps && git pull && docker compose up -d --build
```
