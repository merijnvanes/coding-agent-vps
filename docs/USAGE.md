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

The sandbox container's RAM cap is **adaptive to the host size**:
`scripts/cloud-init-tasks.sh` detects total RAM at provision time and
sets `mem_limit = MemTotal − 1024 MB` (the 1 GB reserved for host
services like tailscaled/dockerd/systemd, which don't scale with RAM).
A single Claude / Codex session typically sits at 300–700 MB resident,
so on a default CX23 (~4 GB host → ~2.9 GB container after firmware
reserve) you'll get 2–3 concurrent agents comfortably; CX33 (~8 GB →
~6.9 GB) handles 6–8; CX43 (~16 GB → ~15 GB) handles a dozen-plus. If the cap is exceeded, the offending process
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

`hcloud`, `wrangler`, `gcloud`, `supabase` and `seo` are wrapped by PATH shims at `/opt/agent-vps-wrappers/`. Each shim fetches only its own token from the `coding-agent-vps-tooling` Infisical project at command-time and injects it into the subprocess environment for that one invocation. The token never persists on disk inside the sandbox.

Only the VPS uses `coding-agent-vps-tooling`, so its tokens can be made for the VPS: narrow scopes, and where the provider allows it, locked to the VPS's IP (SETUP.md Phase 2). Keep your laptop's wider tokens in a separate project that `<vps-name>-agent` is not a member of.

The sandbox reads Infisical as its own machine identity, `<vps-name>-agent`, never as you. Nothing to log in to: the host refreshes a 1-hour access token for that identity every 20 minutes (`agent-token.timer`), and the `infisical` shim hands it to every Infisical call. The identity's client secret stays on the host, so a token copied out of the sandbox stops working within the hour. **Never run `infisical login` in the sandbox.** That would put your own account, with everything it can reach, back in the agent's hands.

Use the CLIs normally:

```bash
hcloud server list                        # HCLOUD_TOKEN fetched per-command, in env for one subprocess
wrangler tail <worker>                    # CLOUDFLARE_API_TOKEN, same pattern (deploy needs Workers Scripts Edit, SETUP.md Phase 2)
supabase db push                          # SUPABASE_ACCESS_TOKEN, same pattern
gcloud auth list                          # GCP SA JSON, written to /dev/shm temp file, deleted on exit
```

**Don't `supabase login` (or any "login" inside these CLIs).** That writes their token to `~/.supabase/access-token` / equivalent paths on disk, persisting across the container lifetime. The shims keep tokens in process memory only. The one exception is `seo auth login`, which night-shift needs: the shim covers only seo's DataForSEO and Bing keys, and the Google login for Search Console is a separate OAuth token that seo stores in the sandbox until the container is recreated. Incident response revokes it (step 2).

The trade is precise: no **cloud-provider** tokens (Hetzner, Cloudflare, GCP, Supabase) at rest inside the sandbox. OAuth logins are another matter: Claude, Codex and Gemini keep refresh tokens in their named volumes, and seo keeps its Google token as above. The **Infisical access token** at `/run/agent-token/token` is readable by the agent, by design: it is what lets the shims work. It reaches only the projects the agent identity is a member of, and it expires within the hour. The agent can still read every secret in those projects with it, because a process the agent starts can print what it is given. The point is a short-lived, narrow credential, not a hidden one.

If a shim fails with "no agent token", check the host side: `sudo systemctl status agent-token.timer agent-token.service` and `sudo journalctl -u agent-token.service -n 20`. The service refuses to hand out a token (and alerts) when the identity's token TTL is above 1 hour, or when the identity can read the `coding-agent-vps` project.

## Using your app's secrets inside the sandbox

For app-specific secrets (database URLs, anon keys, app-scoped API keys), each app gets its own Infisical project (e.g. `dobudex`). Inside the project directory under `/work`, prefix the command with `infisical run --env=dev --`:

```bash
cd /work/<your-project>
infisical run --env=dev -- npm start         # or pnpm / uv run / etc.
```

`infisical run` gets the project from `.infisical.json` in the current directory or a parent (committed in the project repo, points at the right Infisical project), fetches the secrets, sets them in the subprocess env, runs the command. Same trust model as the cloud-CLI shims — secret in process memory for one command, never on disk. (Under a machine identity the CLI itself ignores `.infisical.json`; the `infisical` shim reads it and passes the project on.)

A new app needs two things before this works:

1. **In Infisical (owner):** open the app's project → Access Control → Machine Identities → add `<vps-name>-agent` as **Viewer**. Viewer reads every environment of that project on the free plan, so keep production secrets in the deploy platform (Cloudflare, GitHub Actions) or in a separate project the agent is not a member of.
2. **In the repo:** if it has no `.infisical.json` yet, write one with the project's ID (Infisical → project → Settings). `infisical init` needs a personal login, so it does not work here.

   ```bash
   cd /work/<your-project>
   printf '{"workspaceId":"%s"}\n' <project-id> > .infisical.json
   ```

The agent identity is a member of exactly these projects:

- `coding-agent-vps-tooling` — account-wide cloud-CLI tokens (consumed by PATH shims)
- Per-app projects (`dobudex`, etc.) — app-specific secrets (consumed by `infisical run --` from the project dir)

The third project, `coding-agent-vps`, holds the host-side credentials managed by cred-daemon on the VPS host, including the raw GitHub key. cred-daemon uses its own identity, `<vps-name>-creds`, for it. The agent identity is not a member, Infisical refuses it, and `agent-token.service` checks that on every refresh.

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

**Host-side credentials** (`github-ssh-key`, `ntfy-topic` in `coding-agent-vps`). For `ntfy-topic`:

1. Update the value in the Infisical UI.
2. SSH into the VPS and run:
   ```bash
   sudo systemctl start cred-daemon
   ```
   to pull the new value immediately. Or wait for the daily 04:00 UTC refresh.

**`github-ssh-key`** needs GitHub on both sides of the swap:

1. Make a new key pair and add its public key at GitHub, with SSO
   authorization where needed, as in SETUP.md Phase 4. Keep the old key
   at GitHub for now. Note the new fingerprint:
   `ssh-keygen -lf ~/Downloads/coding-agent-vps-key.pub`.
2. Paste the new private key into Infisical as `github-ssh-key`, then
   shred the local files (Phase 4 cleanup).
3. On the VPS: `sudo systemctl start cred-daemon`. cred-daemon swaps the
   key into ssh-agent; it keeps the old one if the new value is not a
   valid key.
4. Check that the swap happened: `docker exec sandbox ssh-add -l` must
   show one key, with the new fingerprint. Then
   `docker exec sandbox ssh -T git@github.com` must greet you.
5. Delete the old public key at GitHub (Settings → SSH and GPG keys).
   Until you do, anyone with a copy of the old private key can still
   push.

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

Do not try to clean the VPS in place. ssh-agent keeps the GitHub key in
memory after its file is deleted, and the sandbox's named volumes
(`~/.claude` settings and hooks, `~/.codex`, `~/.gemini`) and `/work`
survive a container rebuild, so the agent can leave code there that
runs again.

1. **Kill the VPS immediately.** From your laptop:
   ```bash
   hcloud context use coding-agent-vps-admin
   hcloud server delete coding-agent-vps
   ```
   This is the kill switch. The admin token lives only on your laptop;
   the agent has no path to it and no way to prevent deletion.
2. **Revoke OAuth grants** at https://console.anthropic.com (Claude)
   and https://platform.openai.com (Codex). For the Gemini CLI, and
   for the `seo` CLI if you ran `seo auth login`, go to
   https://myaccount.google.com/connections and remove their access
   to your Google account. The refresh tokens lived
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
   → Machine Identities → for both `<vps-name>-creds` and
   `<vps-name>-agent`, revoke the Universal Auth client secret.
   Belt-and-suspenders — with the VPS deleted there's no client to use
   the secrets, and the agent's tokens die within the hour, but
   revoking ensures a leaked client secret can't be reused. Also treat
   every secret in the projects the agent identity could read (tooling
   and app projects) as exposed: those get fresh values in step 3 and
   step 5.
5. **Reprovision** by running `./scripts/provision.sh` (or by having
   your agent walk you through SETUP.md again — much shorter the
   second time since external services are already configured). Make
   sure to mint fresh credentials at each upstream service before
   pasting them into Infisical for the new instance. A compromised
   agent may have pushed to this repo: `provision.sh` refuses an
   unsigned tip, and you should read those commits (see "Signed
   updates") before you sign anything on top of them.

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

After any `docker-compose.yml` or `daemon/sandbox.slice` change that
touches resource limits, verify the new limits actually applied
(a pulled diff doesn't reconfigure a running container — `up -d`
must recreate it, and slice changes apply only on the next
container recreation or `set-property`):

```bash
# Expected mem_limit = MemTotal − 1024 MB. On a ~4 GB cx23 that's
# roughly 2.9 GB; on ~8 GB cx33 roughly 6.9 GB; on ~16 GB cx43 ~15 GB.
# Read your derived value from /opt/agent-vps/.env first:
cat /opt/agent-vps/.env

# Docker-side: RAM cap and slice placement
docker inspect sandbox --format '{{.HostConfig.Memory}} {{.HostConfig.CgroupParent}}'

# Slice-side: the actual swap-denial enforcement (effective cap on
# all descendants of the slice, including the container's cgroup)
cat /sys/fs/cgroup/user.slice/user-$(id -u dev).slice/user@$(id -u dev).service/sandbox.slice/memory.swap.max
# expect: 0

# Process/thread cap (pids_limit in docker-compose.yml)
docker exec sandbox cat /sys/fs/cgroup/pids.max
# expect: 4096
```

To change only the process cap without recreating the container (which
would kill tmux), apply the compose value in place:
`docker update --pids-limit 4096 sandbox`.

Infisical needs nothing after a rebuild: the host keeps refreshing the
agent token, and the new container mounts it at `/run/agent-token/`.

The rest of the writable layer goes. Redo `seo auth login` (night-shift
README, setup step 2), and set `git config --global user.name` and
`user.email` again, because `~/.gitconfig` is not in the image. Night-shift
workers use a headless Chromium that also lives there. Reinstall it in the
sandbox with `cd /tmp && npm i playwright@<version> && npx playwright install
--only-shell chromium`. Then run `ldd` on the `chrome-headless-shell` binary,
download the Ubuntu noble .debs for the libraries it cannot find, and unpack
them with `dpkg-deb -x <deb> /tmp/libs`. Workers run it with
`LD_LIBRARY_PATH=/tmp/libs/usr/lib/x86_64-linux-gnu` (night-shift
`notes/dobudex-website.md`).

### Host Docker and Tailscale upgrade

```bash
# On the host. Keep docker-ce-rootless-extras at the docker-ce version.
sudo systemd-run --unit=pkg-upgrade --no-block /bin/bash -c \
  'DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold \
   docker-ce=<v> docker-ce-cli=<v> docker-ce-rootless-extras=<v> containerd.io=<v> \
   docker-buildx-plugin=<v> docker-compose-plugin=<v> tailscale=<v> >/var/log/pkg-upgrade.log 2>&1'
systemctl --user restart docker   # as dev, after the log ends: apt does not restart the rootless daemon
```

The tailscale package restarts `tailscaled`, which drops your Tailscale SSH
session, so the apt step runs detached. The rootful `docker.service` stays
disabled. Restarting the rootless daemon restarts the sandbox and kills tmux.
Update the pins in `scripts/cloud-init-tasks.sh` and `cloud-init.yaml` to
match.

### Update an existing VPS from the repo

Pull, then re-run the idempotent setup script. It rebuilds the sandbox
image from cache and installs the current unit files:

```bash
sudo git -C /opt/agent-vps pull
sudo bash /opt/agent-vps/scripts/cloud-init-tasks.sh
```

The pull merges only a tip commit you signed; see "Signed updates"
below if it refuses.

The script builds the new image but leaves the running sandbox alone.
A change to `docker-compose.yml` or `sandbox/` takes effect only when
you recreate it, which ends the tmux session and every agent in it:

```bash
cd /opt/agent-vps && docker compose up -d
```

The script leaves services that already run alone, so a change to
`daemon/ssh-agent-creds.service` or `daemon/ssh-agent-bridge.service`
takes effect only after a restart. The agent loads the cached GitHub
key itself when it starts:

```bash
sudo systemctl restart ssh-agent-creds.service ssh-agent-bridge.service
docker exec sandbox ssh -T git@github.com   # as dev: expect "Hi <github-username>!"
```

If that says "Permission denied (publickey)", the cached key is
missing or stale: `sudo systemctl start cred-daemon.service` fetches
it from Infisical and loads it.

**Moving a VPS from `infisical login` to the agent identity.** VPSes
set up before `agent-token.timer` existed have your personal Infisical
login inside the sandbox. That login reaches every project you can,
the raw GitHub key in `coding-agent-vps` included. To move over:

1. Create `<vps-name>-agent` in Infisical (SETUP.md Phase 2,
   "Identity for the sandbox"). Optionally rename cred-daemon's
   identity to `<vps-name>-creds`; it logs in by client ID, so the
   name does not matter to it.
2. On the VPS, pull and run the setup script as above. It installs and
   starts `agent-token.timer`.
3. `sudo /opt/agent-vps/scripts/agent-identity.sh`: paste the client
   ID and the client secret.
4. Recreate the sandbox so it gets the new shims and the token mount,
   and so the old `~/.infisical/` login is discarded:
   `cd /opt/agent-vps && docker compose up -d --build`.
5. Check from the sandbox: `hcloud server list` works, and
   `infisical export --projectId=<coding-agent-vps project ID>
   --env=dev >/dev/null` fails with "Unable to fetch secrets". The
   redirect keeps the values off your screen if it does not fail.
6. In Infisical, end your old sessions (Personal Settings → General →
   Sessions → Sign out everywhere), so a copy of the old login stops
   working.

### Signed updates

`/opt/agent-vps` merges only a tip commit signed by a key in
`/etc/agent-vps/allowed-signers` (ARCHITECTURE.md "Only signed commits
reach root"). Commits you make in your laptop checkout are signed
automatically (SETUP.md Phase 5 "Sign commits").

**The pull says "does not have a GPG signature" or "untrusted GPG
signature".** The tip of `main` was not signed by you: the agent
pushed from the sandbox, someone edited on github.com, or you pulled
updates from the upstream template, which its author signed. The VPS
keeps the old code, and so does your laptop checkout, which checks
the same way. On your laptop, fetch and read the change before it
touches your files; if you accept it, merge it with a signed merge
commit and push:

```bash
git fetch                                  # for template updates: git fetch upstream, and use upstream/main below
git log --oneline HEAD..origin/main        # which commits came in
git diff HEAD...origin/main                # everything they change, merges included
git merge --no-verify-signatures --no-ff origin/main -m "Approve <what>" && git push
```

`--no-ff` makes the merge commit, which carries your signature, the
new tip. That signature approves everything below it, so review
before you merge. If the merge says "Already up to date" (your
checkout already holds those commits, say a fresh clone), the two
review commands showed nothing. Review against the commit the VPS
runs instead, which only verified pulls can move, and sign only after
that:

```bash
git diff "$(ssh <user>@coding-agent-vps sudo git -C /opt/agent-vps rev-parse HEAD)" HEAD
git commit --allow-empty -m "Approve <what>" && git push
```

**Turn it on for a VPS set up before this existed** (one time). Put
your laptop signing key in the signers file and set the git config
before the first pull, so that pull is checked too:

```bash
# on the laptop, in this checkout: print the line to paste
./scripts/allowed-signers-line.sh
# on the VPS, as dev
sudo install -m 0644 /dev/stdin /etc/agent-vps/allowed-signers <<'EOF'
<the line from above>
EOF
sudo git -C /opt/agent-vps config gpg.ssh.allowedSignersFile /etc/agent-vps/allowed-signers
sudo git -C /opt/agent-vps config merge.verifySignatures true
sudo git -C /opt/agent-vps config pull.rebase false
sudo git -C /opt/agent-vps config pull.ff only
sudo git -C /opt/agent-vps config gpg.openpgp.program false
sudo git -C /opt/agent-vps config gpg.x509.program false
sudo git -C /opt/agent-vps pull
sudo bash /opt/agent-vps/scripts/cloud-init-tasks.sh
```

**New laptop.** Install Tailscale and log in to your tailnet (the
only way into the VPS), log in to GitHub so you can push
(`gh auth login`, which also sets up git's HTTPS credentials), and,
if you will provision from it, install `hcloud` and load the saved
admin token (`hcloud context create coding-agent-vps-admin`). Clone your repo and add the template as `upstream`
(`git remote add upstream https://github.com/merijnvanes/coding-agent-vps.git`).
Then follow SETUP.md Phase 5 "Sign commits" and stop there: its next
part, "Run provisioning", recreates the VPS. Two additions:

- **In its step 1, choose the key.** Keeping the old one is simplest:
  copy both files of the key pair over (for example through your
  password manager), and the VPS already trusts it.
- **Before its step 4, trust the keys the VPS trusts.** The VPS file
  is root-owned, so the agent cannot have changed it:

  ```bash
  ssh <user>@coding-agent-vps cat /etc/agent-vps/allowed-signers >> ~/.ssh/allowed_signers
  ```

**With a new key**, also tell the VPS and the old laptop about it, so
both laptops work while you switch:

```bash
# on the new laptop, in the checkout: print the new key's line
./scripts/allowed-signers-line.sh
# on the VPS, as dev
printf '%s\n' '<the line from above>' | sudo tee -a /etc/agent-vps/allowed-signers >/dev/null
# on the old laptop, if it will still pull
printf '%s\n' '<the line from above>' >> ~/.ssh/allowed_signers
```

**Retire a key** (old laptop no longer used, with its own key). If
you copied that key to the new laptop, there is nothing to retire; to
stop trusting it anyway, first make and admit a new key as above.
Before you delete a key, move the VPS to a tip signed by the key you
keep, because `cloud-init-tasks.sh` checks that `HEAD` verifies:

```bash
# on the laptop you keep
git commit --allow-empty -m "Sign with the current key" && git push
# on the VPS
sudo git -C /opt/agent-vps pull
```

Then delete the old key's line from `/etc/agent-vps/allowed-signers`
on the VPS (`sudo nano /etc/agent-vps/allowed-signers`) and from
`~/.ssh/allowed_signers` on your laptops. Commits it signed earlier
stay in the history; a new tip signed by it is refused.

**Lost or stolen laptop.** It can log in to the VPS as you, with
sudo, so cut that first:

1. Sign out its sessions at the identity provider you log in to
   Tailscale with (for example Google: Security, Your devices), so it
   cannot rejoin. A Tailscale admin console session in its browser
   lasts up to 30 days on its own and can open an SSH console, so
   expect that route too: remove the device and any machine you do
   not recognise from your tailnet (Tailscale admin console,
   Machines), check that list again over the next days, and revoke the
   Hetzner admin token and its GitHub sessions. If you think the thief
   already got in, treat the VPS as compromised and follow "Incident
   response"; its `hcloud` steps need a new admin token in the
   `coding-agent-vps` project (`hcloud context create
   coding-agent-vps-admin`), or delete the server in the Hetzner web
   console.
2. Delete its key's line from `/etc/agent-vps/allowed-signers` on the
   VPS **and** from `~/.ssh/allowed_signers` on every laptop you still
   use, so nothing pulls a commit signed with the stolen key. Any
   device still on your tailnet can log in for this, a phone too.
3. Get a trusted baseline: the commit the VPS runs, which only
   verified pulls can move:
   `ssh <user>@coding-agent-vps sudo git -C /opt/agent-vps rev-parse HEAD`.
4. On a laptop whose signing key was **never** on the lost laptop (a
   copied key is just as stolen): `git fetch`, then read
   `git diff <that hash> origin/main`, everything pushed since (on
   "bad object", the commit is gone from GitHub; diff on the VPS:
   `sudo git -C /opt/agent-vps fetch && sudo git -C /opt/agent-vps diff HEAD origin/main`). If you
   have no such key, set up a new key first ("New laptop", then "With
   a new key", which adds it to the VPS); its SETUP step 4 does this
   review.
5. If you accept it, sign on top with the approve flow above and push.
   On the VPS, `sudo git -C /opt/agent-vps pull`. If that says it
   cannot fast-forward (the history was rewritten), use the verified
   reset from "`cloud-init status` shows error" below instead.

Until that pull, `cloud-init-tasks.sh` stops at its signature check
(`HEAD` carries the removed key); the pull itself still works, since
it checks only the incoming tip.

### Full VPS rebuild

For OS-level issues or just to test the flow end-to-end:

```bash
./scripts/provision.sh
```

The script detects an existing server with the same name and asks
before deleting it, after it has checked that the tip of `main` is
signed by you (see "Signed updates"). All local disk and Docker volumes are lost —
OAuth logins must be redone. Total time: ~10 min cloud-init + ~5 min
bootstrap + OAuth.

The new server gets a new public IP. Change the Cloudflare token's
Client IP Address Filtering to the address `hcloud server ip
coding-agent-vps` prints (SETUP.md Phase 5 "Verify"); until then,
`wrangler` in the sandbox gets "Authentication error".

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
hard-capped at `<host RAM − 1 GB>` total (RAM via `mem_limit` in
`docker-compose.yml`, derived from `/opt/agent-vps/.env` written at
provision time by `scripts/cloud-init-tasks.sh`; swap denied via
`cgroup_parent: sandbox.slice` enforcing `memory.swap.max=0`), and
the host has a 2 GB swapfile with `vm.swappiness=10` (all configured
by `scripts/cloud-init-tasks.sh`). Together these ensure an
over-allocating in-container process fails at the cgroup boundary
(`ENOMEM` → language-level OOM error → process exit, with cgroup
OOM kill as backstop) before the host ever sees pressure; and even
if the host *does* see pressure, swap (untouched by the container)
gives the kernel somewhere to push cold pages instead of evicting
file cache. If you find yourself hitting the host-level failure
mode anyway, the offender is probably *outside* the sandbox: check
`dockerd`, `cred-daemon`, or your own SSH sessions.

### VPS never appears in `tailscale status` after ~5 min

Cloud-init's `tailscale up` was rejected. Two common causes:

1. **`tagOwners` missing** for `tag:coding-agent-vps` in your
   Tailscale policy (see [SETUP.md Phase 3](./SETUP.md#phase-3-tailscale-5-min)).
2. **Auth-key generated without the tag** ticked.

To confirm: open https://login.tailscale.com/admin/machines. If the
VPS isn't listed at all, the join was rejected (silent failure — no
"pending approval" entry). Fix the policy, regenerate a tagged auth-key,
`hcloud server delete coding-agent-vps`, re-run `provision.sh`.

### Locked out: Tailscale SSH does not answer

Host OpenSSH is masked and root has no password (see
[ARCHITECTURE.md "Firewall & IPv6"](./ARCHITECTURE.md#firewall--ipv6)),
so Tailscale is the only network login. When it is down, use the
Hetzner web console. It is out-of-band and opens no port.

1. Check the tailnet side first: is the VPS online at
   https://login.tailscale.com/admin/machines, and does the policy
   still allow your login in its `ssh` rules?
2. Set a root password and log in on the console:
   ```bash
   hcloud context use coding-agent-vps-admin       # the VPS's own project; the hcloud steps below need it
   hcloud server reset-password coding-agent-vps   # prints a new root password
   ```
   Open the server in the Hetzner Cloud Console and click **Console**.
   Log in as `root` and repair tailscaled
   (`systemctl status tailscaled`, `journalctl -u tailscaled`).
   `reset-password` goes through qemu-guest-agent, which Hetzner's
   Ubuntu image runs.
3. Lock the password again before you log out: `passwd -l root`.
4. If `reset-password` fails, boot the rescue system:
   `hcloud server enable-rescue coding-agent-vps` (prints a rescue
   root password), then `hcloud server reboot coding-agent-vps`. Log
   in on the web console, because the deny-all firewall blocks SSH to
   the rescue system too. Mount the disk (`mount /dev/sda1 /mnt`),
   repair, and reboot. Rescue mode lasts for one boot only.
5. If none of this is worth it, rebuild with `./scripts/provision.sh`.

Do not unmask `ssh.socket` as a workaround. The sandbox reaches host
port 22 over loopback, past both firewalls.

A VPS provisioned before OpenSSH was masked gets the change through
[Update an existing VPS from the repo](#update-an-existing-vps-from-the-repo).

### `bootstrap.sh` fails with HTTP 422 from Infisical

Almost always: **Client ID was pasted incorrectly** — typically the
identity's *name* (e.g. `coding-agent-vps-creds`) instead of the
Universal Auth Client ID UUID (e.g. `d40df785-1383-...`).

Confirm:

```bash
sudo journalctl -u cred-daemon.service -n 20 --no-pager
sudo journalctl -u agent-token.service -n 20 --no-pager
```

Look for `curl: (22) ... error: 422`. Re-run `bootstrap.sh` (or only
`scripts/agent-identity.sh` for the sandbox identity) and use the UUID
from Access Control → Machine Identities → the identity → Universal
Auth → Client ID.

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
wrong (and pushing a signed commit, if the fix is upstream), the
safest recovery is:

```bash
sudo git -C /opt/agent-vps fetch
sudo git -C /opt/agent-vps verify-commit origin/main \
  && sudo git -C /opt/agent-vps reset -q --hard origin/main \
  && sudo bash /opt/agent-vps/scripts/cloud-init-tasks.sh   # idempotent
```

`verify-commit` runs before any repo file does, so this recovery never
runs a tip you did not sign.

**The VPS joined the tailnet, but `ssh <user>@coding-agent-vps` says
the user does not exist.** Most likely cloud-init stopped at the
signature check: the tip of `main` was not signed when the VPS cloned
it (someone pushed after `provision.sh` checked). Nothing was set up,
so there is no user to log in as and nothing on disk to run. Sign the
tip (see "Signed updates") and run `provision.sh` again.

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
