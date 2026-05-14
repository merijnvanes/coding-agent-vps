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

## Using your app's secrets inside the sandbox

When you're iterating on a code project under `/work` that has its own
Infisical workspace, use the `infisical` CLI to fetch that project's env
vars at runtime — no need to ever copy them onto the VPS.

```bash
cd /work/<your-project>
infisical login                              # opens device-code flow
infisical run --env=dev -- npm start         # or pnpm / uv run / etc.
```

The same pattern applies to per-project CLIs that read auth from an env
var. Supabase CLI is the canonical example — store the access token as
`SUPABASE_ACCESS_TOKEN` in the project's Infisical workspace and invoke:

```bash
infisical run --env=dev -- supabase db push
infisical run --env=dev -- supabase functions deploy <name>
```

**Don't `supabase login` inside the sandbox.** That writes the token
to `~/.supabase/access-token` on disk, which persists across the
container lifetime and is readable by anything running as the agent
user. The env-var path keeps the token in process memory only — gone
when the command exits.

`infisical login` state is **not** persisted across container rebuilds
(unlike Claude/Codex OAuth, which use named volumes). After
`docker compose up -d --build` or a full VPS rebuild, log in again.
This is intentional: sandbox state is ephemeral, the CLIs themselves
are reinstalled automatically from the Dockerfile, and the only friction
on rebuild is re-auth — never reinstall.

This uses a different Infisical identity from the `agent-vps`
operational wallet (which the host-side cred-daemon fetches and
bind-mounts as files into `/run/agent-env/`). The two don't see each
other's secrets.

## Exposing a sandbox dev server

To view a dev server running inside the sandbox (Vite, Next.js,
Flutter web, Django, etc.) from your laptop's browser, use SSH port
forwarding:

```bash
# From the laptop
ssh -L 3000:127.0.0.1:3000 dev@coding-agent-vps
# Then open http://localhost:3000 in the laptop browser.
```

`docker-compose.yml` pre-publishes a few port ranges on the VPS host's
loopback so you don't have to edit it per project:

| Range | Typical use |
|---|---|
| 3000-3009 | Next.js, Rails, Express, generic Node |
| 5170-5179 | Vite |
| 8000-8089 | Flutter web, Django, Python, webpack-dev-server |

If you need a port outside these ranges, add it to `docker-compose.yml`
— **keep the `127.0.0.1:` prefix**, or the port becomes reachable on
the tailnet (see comment in `docker-compose.yml`).

### Bind to `0.0.0.0` inside the container

Most dev servers default to listening on `127.0.0.1` *inside the
container* — that's the container's own loopback, which Docker's port
forwarder cannot reach. Override the bind address:

```bash
# Vite
pnpm dev --host 0.0.0.0
# Next.js
pnpm next dev -H 0.0.0.0
# Flutter web
flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8080
# Django
python manage.py runserver 0.0.0.0:8000
```

If your SSH tunnel succeeds but the browser sees "connection refused"
or hangs, the container-side bind is the most common cause.

### Verify the loopback-only binding (one-time, after any compose change)

On the VPS:

```bash
ss -tlnp | grep ':3000'
```

Must show `127.0.0.1:3000`, not `0.0.0.0:3000` or `*:3000`. Anything
other than `127.0.0.1:` means the port is exposed on the tailnet —
stop and check that the `127.0.0.1:` prefix in `docker-compose.yml`
wasn't dropped.

### Browser-trust caveat

A tunneled `localhost:3000` shares cookie space with anything else on
your laptop's `localhost:*`. If you have a sensitive site open in
another tab at `localhost:<port>`, the sandbox dev server can read or
write its cookies. Treat a sandbox dev server like any unaudited
local code — don't run it alongside trusted local dev surfaces.

A compromised in-sandbox agent could serve poisoned JS to the laptop
browser via this path. That's identical to running compromised npm
deps locally — not a new class of risk, covered by
[REQUIREMENTS.md §2](./REQUIREMENTS.md).

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

If you suspect the VPS is **actively compromised**, stop the bleeding
first — kill the VPS — then revoke credentials. Cached env vars and
in-flight API calls keep working until the process is gone, so killing
the host is the highest-leverage action you can take.

1. **Kill the VPS immediately.** From your laptop:
   ```bash
   hcloud context use coding-agent-vps-admin
   hcloud server delete coding-agent-vps
   ```
   This is the kill switch. The admin token lives only on your laptop;
   the agent has no path to it and no way to prevent deletion.
2. **Revoke OAuth grants** at https://console.anthropic.com (Claude)
   and https://platform.openai.com (Codex). The refresh tokens lived
   in the sandbox volume, which is now gone with the VPS — but the
   OAuth grants at the issuer remain valid until you revoke them, so
   if the agent already exfiltrated a token it could still be used
   from elsewhere.
3. **Revoke each upstream credential** at the issuing service: GitHub
   SSH key (Settings → SSH and GPG keys → Delete), Cloudflare token,
   GCP SA key, Hetzner apps token, npm/PyPI tokens. Manual UI clicks
   per service. Assume any credential the daemon had fetched is in
   the attacker's hands.
4. **Revoke the VPS's Infisical access.** Infisical → Access Control
   → Identities → `agent-vps` → revoke the Universal Auth client
   secret. Belt-and-suspenders — with the VPS deleted there's no
   client to use the secret, but revoking ensures the secret can't be
   reused if it leaked.
5. **Reprovision** by running `./scripts/provision.sh` (or by having
   your agent walk you through SETUP.md again — much shorter the
   second time since external services are already configured). Make
   sure to mint fresh credentials at each upstream service before
   pasting them into Infisical for the new instance.

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

The sandbox image was built with a pnpm version that blocked
postinstall scripts (pnpm 10+ default-denies them as supply-chain
hardening). The Dockerfile in current `main` whitelists the native-
binary CLIs explicitly with `pnpm add -g --allow-build=...` — so a
fresh rebuild from the latest source picks up the working install:

```bash
ssh <user>@coding-agent-vps
cd /opt/agent-vps && git pull && docker compose up -d --build
```

If the error persists after rebuild, check that the Dockerfile in the
cloned tree includes `--allow-build=@anthropic-ai/claude-code` (and
similar for codex/wrangler) on the `pnpm add -g` lines.
