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

### Running multiple agents in parallel

The sandbox container is capped at 3 GB of RAM (`mem_limit` in
`docker-compose.yml`). A single Claude / Codex session typically
sits at 300–700 MB resident, so 2–3 concurrent agents is comfortable
on the default CX23. If the cap is exceeded, the offending process
hits `ENOMEM` at the cgroup boundary — most language runtimes
(Python, Node.js, etc.) surface this as a visible out-of-memory
error (`MemoryError`, `JavaScript heap out of memory`, …) and exit
with a traceback in the tmux pane. Processes that don't handle
`ENOMEM` gracefully trigger the cgroup OOM killer as a backstop,
which reaps the heaviest in-container leaf (you'll see `Killed`);
worst case it targets the container init, which trips
`restart: unless-stopped` and brings the sandbox back fresh with
all tmux sessions inside it lost. **Either path keeps the host
fully responsive** — SSH, other tmux sessions in the same
container, and host services keep working throughout. See
[Troubleshooting: VPS unresponsive](#vps-unresponsive-cpu-pegged-ssh-hangs)
for the failure mode this prevents.

## Using the sandbox cloud CLIs

`hcloud`, `wrangler`, `gcloud`, and `supabase` are wrapped by PATH shims at `/opt/agent-vps-wrappers/`. Each shim transparently fetches the matching token from the `coding-agent-vps-tooling` Infisical project at command-time and injects it into the subprocess environment for that one invocation. The token never persists on disk inside the sandbox.

Once per container, log in to Infisical:

```bash
infisical login    # device-code OAuth — opens a URL on the laptop, paste the code back
```

Then use the CLIs normally:

```bash
hcloud server list                        # HCLOUD_TOKEN fetched per-command, in env for one subprocess
wrangler deploy                           # CLOUDFLARE_API_TOKEN, same pattern
supabase db push                          # SUPABASE_ACCESS_TOKEN, same pattern
gcloud auth list                          # GCP SA JSON, written to /dev/shm temp file, deleted on exit
```

**Don't `supabase login` (or any "login" inside these CLIs).** That writes their token to `~/.supabase/access-token` / equivalent paths on disk, persisting across the container lifetime. The shims keep tokens in process memory only.

`infisical login` writes a session token to `~/.infisical/` inside the container, which persists for the container's lifetime — so subsequent shim invocations don't re-prompt — but is NOT on a named volume. The whole `~/.infisical/` directory is discarded on `docker compose up -d --build` or a full VPS rebuild. After a rebuild, `infisical login` again.

The trade is precise: no **cloud-provider** tokens (Hetzner, Cloudflare, GCP, Supabase) at rest inside the sandbox. An **Infisical session credential** lives in `~/.infisical/` for the container's lifetime; that's how the shims can authenticate without prompting on every command. The session is scoped to your personal Infisical identity, can be revoked from the Infisical admin UI, and dies on rebuild.

## Using your app's secrets inside the sandbox

For app-specific secrets (database URLs, anon keys, app-scoped API keys), each app gets its own Infisical project (e.g. `dobudex`). Inside the project directory under `/work`, prefix the command with `infisical run --env=dev --`:

```bash
cd /work/<your-project>
infisical run --env=dev -- npm start         # or pnpm / uv run / etc.
```

`infisical run` reads `.infisical.json` in the current directory (committed in the project repo, points at the right Infisical project), fetches the secrets, sets them in the subprocess env, runs the command. Same trust model as the cloud-CLI shims — secret in process memory for one command, never on disk.

If the project doesn't have `.infisical.json` yet:

```bash
cd /work/<your-project>
infisical init                # interactive — pick the Infisical project + env, writes .infisical.json
```

The Infisical projects you log into from this sandbox are scoped per use:

- `coding-agent-vps-tooling` — account-wide cloud-CLI tokens (consumed by PATH shims)
- Per-app projects (`dobudex`, etc.) — app-specific secrets (consumed by `infisical run --` from the project dir)

The third project, `coding-agent-vps`, holds the host-side credentials managed by cred-daemon on the VPS host. cred-daemon uses its own Universal Auth identity for it. No sandbox infrastructure (no shim, no `.infisical.json` in any project dir) is configured to read from `coding-agent-vps` — though your personal Infisical login inside the sandbox technically has Viewer access to all three projects under your account. The split is organizational (rotation cadence, blast radius on revocation), not a hard isolation boundary inside the sandbox.

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
credential rotation is the **user's** responsibility — the system only
fetches the current value from Infisical.

**Sandbox-side credentials** (cloud-CLI tokens in `coding-agent-vps-tooling`, app secrets in per-app projects):

1. Update the value in the Infisical UI.
2. Next CLI invocation picks it up — every `hcloud`/`wrangler`/`gcloud`/`supabase` invocation and every `infisical run --` fetches fresh. No daemon restart, no shell re-source, no running-tmux footgun.

**Host-side credentials** (`github-ssh-key`, `ntfy-topic` in `coding-agent-vps`):

1. Update the value in the Infisical UI.
2. SSH into the VPS and run:
   ```bash
   sudo systemctl start cred-daemon
   ```
   to pull the new value immediately. Or wait for the daily 04:00 UTC refresh.

   For `github-ssh-key`: cred-daemon swaps it into ssh-agent on success; sandbox's next signing request uses the new key.

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

Named volumes (`sandbox-state-claude`, `sandbox-state-codex`,
`sandbox-state-gemini`) persist — no Claude/Codex/Gemini OAuth re-login
needed. Your tmux session is killed on container recreation (it's a
process inside the container); reattach afterward.

After any `docker-compose.yml` change that touches resource limits,
verify the new limits actually applied (a pulled diff doesn't
reconfigure a running container — `up -d` must recreate it):

```bash
docker inspect sandbox --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}'
# expect: 3221225472 3221225472   (3 GiB each)
```

The `infisical login` session does NOT persist across rebuilds (no
named volume — intentional, the sandbox holds no long-lived secret
material at rest). After every container rebuild, run `infisical login`
again inside the new tmux session before any cloud-CLI commands. Until
you do, `hcloud` / `wrangler` / `gcloud` / `supabase` and any
`infisical run --` invocation will fail with "Not logged in."

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

### VPS unresponsive: CPU pegged, SSH hangs

**Symptom**: `ssh dev@coding-agent-vps` hangs without prompt. Hetzner
Cloud Console shows CPU at ~200% (both vCPUs maxed) for an extended
period. If you can still get a shell, `uptime` shows a load average
in double digits and `top` shows everything blocked on iowait.

**What's almost certainly happening**: page-cache thrashing. The
host (or, less commonly, the container) ran out of reclaimable
memory and the kernel is evicting mmap'd executable pages that get
immediately refaulted, pinning CPU on iowait. This shouldn't happen
in normal operation — the cgroup boundary surfaces `ENOMEM` to
in-container processes (which then either self-terminate with a
language-level out-of-memory error or get OOM-killed as a backstop)
*before* the host has to reclaim anything. But it can if a
host-side process (not in the sandbox cgroup) is the offender, or
if a buggy in-container process consumes memory in a way that
bypasses both `ENOMEM` handling and OOM kill.

**Diagnose from your laptop** (no SSH needed):

```bash
# Linux laptop
hcloud server metrics coding-agent-vps --type cpu \
    --start "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# macOS laptop (BSD date)
hcloud server metrics coding-agent-vps --type cpu \
    --start "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
    --end   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

If CPU is at ~200% for >5 min and not dropping, the host is stuck.

**Recover**:

1. Try ACPI reboot first — clean, lets filesystems flush:
   ```bash
   hcloud server reboot coding-agent-vps
   ```
   Wait ~60 s and re-check metrics. CPU should drop to baseline (~2 %).
2. If CPU stays pegged after the ACPI reboot, the kernel was too
   starved to honor the soft signal. Escalate to a hardware reset:
   ```bash
   hcloud server reset coding-agent-vps
   ```
   This is equivalent to pulling the power cord. The container's
   `restart: unless-stopped` policy brings the sandbox back on its
   own; named volumes (`sandbox-state-claude`, `sandbox-state-codex`,
   `sandbox-state-gemini`) and `/work` survive. The tmux session is
   lost (it's a process inside the container), as is any uncommitted
   in-process agent state.
3. After the box is back, postmortem with:
   ```bash
   ssh dev@coding-agent-vps 'sudo journalctl --boot=-1 --no-pager | grep -iE "out of memory|killed process|memory pressure" | tail'
   ```
   `/var/log/journal` is persistent on this image, so the previous
   boot's journal survives the reset.

**Why this is rare on current `main`**: the sandbox container is
capped at 3 GB (`mem_limit`) and the host has a 2 GB swapfile with
`vm.swappiness=10` (configured by `scripts/cloud-init-tasks.sh`).
Together these ensure an over-allocating in-container process
fails at the cgroup boundary (`ENOMEM` → language-level OOM error
→ process exit, with cgroup OOM kill as backstop) before the host
ever sees pressure; and even if the host *does* see pressure,
swap gives the kernel somewhere to push cold pages instead of
evicting file cache. If you find yourself hitting the host-level
failure mode anyway, the offender is probably *outside* the
sandbox: check `dockerd`, `cred-daemon`, or your own SSH sessions.

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
sudo git -C /opt/agent-vps pull && cd /opt/agent-vps && docker compose up -d --build
```

If the error persists after rebuild, check that the Dockerfile in the
cloned tree includes `--allow-build=@anthropic-ai/claude-code` (and
similar for codex/wrangler) on the `pnpm add -g` lines.
