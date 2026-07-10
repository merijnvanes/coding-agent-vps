# sandbox/Dockerfile — agent runtime image
#
# Built on the VPS at cloud-init time (`docker build`). No registry pull.
# Image contains the toolchain pinned in docs/REQUIREMENTS.md §5.

FROM ubuntu:24.04

# === Pinned third-party tool versions ===
# Each install line below references one of these ARGs. Refresh them at setup
# time per docs/SETUP.md "Refresh pinned versions" — the rule is: pick the
# latest stable release that is at least 7 days old (supply-chain cooldown),
# for every entry. The agent running the setup MUST do this before any
# `docker build` / cloud-init triggers a fresh install.
#
# APT pins for NodeSource, gcloud, and Infisical require the repo metadata
# to be queryable (curl the Packages file or apt-cache madison after adding
# the repo). The refresh procedure documents the lookup mechanics per tool.
ARG NODEJS_VERSION=22.22.0-1nodesource1
# npm bundled with Node 22 is 10.x, which does NOT support `min-release-age`.
# Bump to npm 11+ so the /etc/npmrc cooldown actually applies to `npm install`.
ARG NPM_VERSION=11.13.0
ARG PNPM_VERSION=11.0.7
ARG UV_VERSION=0.11.11
ARG UV_SHA256=a767848254391855c96df271e9ca8b7f72dd172d310460447853d25d907b9ae0
ARG GCLOUD_VERSION=458.0.0-0
ARG WRANGLER_VERSION=4.88.0
ARG CLAUDE_CODE_VERSION=2.1.200
ARG CODEX_VERSION=0.142.5
ARG GEMINI_CLI_VERSION=0.41.2
ARG INFISICAL_VERSION=0.39.0
ARG HCLOUD_VERSION=1.64.1
# SHA256 of hcloud-linux-amd64.tar.gz at HCLOUD_VERSION. Source:
# https://github.com/hetznercloud/cli/releases/download/v$HCLOUD_VERSION/checksums.txt
ARG HCLOUD_SHA256=f6f60a929776ac300dffd42d8a8df6ac0d43d0d05e17bf6ecf6aa5b53fa364c2
ARG SUPABASE_CLI_VERSION=2.98.2
# SHA256 of supabase_linux_amd64.tar.gz at SUPABASE_CLI_VERSION. Source:
# https://github.com/supabase/cli/releases/download/v$SUPABASE_CLI_VERSION/supabase_${SUPABASE_CLI_VERSION}_checksums.txt
# (note: the checksums file name embeds the version — NOT a generic
# checksums.txt — different from hcloud's pattern above.)
ARG SUPABASE_CLI_SHA256=0f59df9e6837e876f309e0b4f47005133c51296e85a02727b2927f33ed9adb2d

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Claude Code auto-updates at runtime by default, which would silently bypass
# the pinned CLAUDE_CODE_VERSION above. Disable so the pin is load-bearing.
ENV DISABLE_AUTOUPDATER=1

# npm's "global" config is $PREFIX/etc/npmrc by default (where $PREFIX is
# `npm config get prefix` — typically /usr for apt-installed Node, NOT /etc).
# Without this override, /etc/npmrc below is silently ignored. Setting
# NPM_CONFIG_GLOBALCONFIG explicitly points npm at the file we actually write.
ENV NPM_CONFIG_GLOBALCONFIG=/etc/npmrc

# --- base system packages ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      openssh-client \
      python3 \
      python3-venv \
      sudo \
      tmux \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# Auto-rewrite https://github.com/ URLs to git@github.com: so every git
# operation inside the sandbox uses SSH (and therefore the bridged
# ssh-agent loaded with the GitHub key). Agents can `git clone` HTTPS
# URLs as usual; auth Just Works without per-session setup.
RUN git config --system url."git@github.com:".insteadOf "https://github.com/"

# Pin GitHub's published ed25519 host key system-wide so SSH never falls
# back to TOFU (`ssh-keyscan`). Same string as cloud-init.yaml — sourced
# once from https://api.github.com/meta. /etc/ssh/ssh_known_hosts is read
# by every user in the container.
RUN mkdir -p /etc/ssh && \
    printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' \
      >> /etc/ssh/ssh_known_hosts

# --- Node.js LTS (22) + pnpm via corepack ---
# Manual NodeSource APT setup — inlines what `deb.nodesource.com/setup_22.x`
# does (fetch GPG key, write keyring + sources.list, apt install). Trade-off
# vs piping the upstream shell script: no remote code executes during build,
# but if NodeSource changes their repo URI / codename ("nodistro") we'll have
# to update this block. Subsequent `apt-get update`s are GPG-verified via
# the keyring, so a CDN swap can't substitute packages signed by a different
# key. Key URL/path/codename mirrors setup_22.x verbatim.
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && chmod 0644 /usr/share/keyrings/nodesource.gpg \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://deb.nodesource.com/node_22.x' \
        'Suites: nodistro' \
        'Components: main' \
        'Architectures: amd64' \
        'Signed-By: /usr/share/keyrings/nodesource.gpg' \
        > /etc/apt/sources.list.d/nodesource.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends "nodejs=${NODEJS_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "npm@${NPM_VERSION}" \
    && corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate

# pnpm global bin dir on PATH so `pnpm add -g X` produces invokable commands.
# pnpm 9+ installs global binaries to $PNPM_HOME/bin and errors out at
# install time if that exact path isn't on PATH (it used to be a warning).
ENV PNPM_HOME=/usr/local/pnpm
ENV PATH="${PNPM_HOME}/bin:${PATH}"
RUN mkdir -p "${PNPM_HOME}/bin"

# --- PATH shims for sandbox-side cloud CLIs ---
# Each shim wraps the real binary in `infisical run -- <real-binary>`, so the
# matching cloud-CLI token is fetched from the coding-agent-vps-tooling
# Infisical project at command-invocation time, lands in the subprocess env
# for one command, and is gone when the command exits. See
# docs/ARCHITECTURE.md "Per-CLI integration".
#
# /opt/agent-vps-wrappers is FIRST in $PATH so unqualified invocations
# (`hcloud server list`, `wrangler deploy`, etc.) resolve to the shim
# rather than the real binary. Subprocess calls (the agent's own
# `subprocess.Popen("hcloud", ...)`), non-interactive bash (`bash -c '...'`),
# cron — all hit the shim. PATH shims, not shell functions, so every caller
# is wrapped regardless of how it was invoked.
COPY wrappers/ /opt/agent-vps-wrappers/
RUN chmod 0755 /opt/agent-vps-wrappers/* \
    && chown root:root /opt/agent-vps-wrappers/*
ENV PATH="/opt/agent-vps-wrappers:${PATH}"

# /etc/npmrc — read by the npm CLI only. ENV NPM_CONFIG_GLOBALCONFIG above
# points npm at this path explicitly (otherwise npm would look at
# $PREFIX/etc/npmrc which is NOT /etc/npmrc on apt-installed Node).
# pnpm 10+ ONLY reads auth/registry settings from .npmrc files; everything
# else (minimumReleaseAge, blockExoticSubdeps, etc.) must live in pnpm's own
# YAML config. pnpm-specific supply-chain settings are therefore set below
# in /home/agent/.config/pnpm/config.yaml.
# This file gives `npm install` (if anyone runs it directly) the same 7-day
# release-age guard pnpm gets via its YAML config. Requires npm 11+ (the
# NPM_VERSION ARG pins to a 11.x build) — npm 10 silently ignores
# min-release-age.
RUN cat >/etc/npmrc <<'EOF'
min-release-age=7
EOF

# --- uv (Python package manager — single Go binary) ---
# Pinned via UV_VERSION + UV_SHA256 at the top of this file. SHA256 is from
# `https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz.sha256`
# Bumping uv requires updating BOTH ARGs in lockstep.
RUN curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
        -o /tmp/uv.tar.gz \
    && echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/uv.tar.gz -C /usr/local/bin --strip-components=1 \
        uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx \
    && rm /tmp/uv.tar.gz

# --- gcloud SDK ---
# Manual APT setup (no `sdk.cloud.google.com | bash`). Binaries land in
# /usr/bin/{gcloud,gsutil} from the apt package — no /opt symlinks needed.
# Package renamed `google-cloud-sdk` → `google-cloud-cli` at 371.0.0+.
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && chmod 0644 /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends "google-cloud-cli=${GCLOUD_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# --- pnpm config for build-time installs (root) ---
# The `pnpm add -g` calls below run as root, BEFORE the agent user is created
# and BEFORE its pnpm config is written. Without this, root's installs of
# wrangler / claude-code / codex would skip the supply-chain hardening that
# the agent-user config applies to everything inside /work. Same keys, same
# values as ~agent/.config/pnpm/config.yaml — see USER agent block for the
# detailed reasoning behind each setting.
RUN mkdir -p /root/.config/pnpm \
    && printf 'minimumReleaseAge: 10080\nblockExoticSubdeps: true\n' \
        > /root/.config/pnpm/config.yaml

# --- wrangler (Cloudflare) — global install via pnpm ---
# pnpm 10+ blocks postinstall scripts by default (supply-chain hardening).
# wrangler/claude-code/codex all need their postinstall to run to download
# native binaries. --allow-build whitelists them explicitly.
RUN pnpm add -g --allow-build=wrangler "wrangler@${WRANGLER_VERSION}"

# --- hcloud CLI (Hetzner) ---
# SHA256-verified, parallel to the uv install above. Hetzner publishes
# checksums.txt alongside each release. Refreshing HCLOUD_VERSION at setup
# also requires updating HCLOUD_SHA256 from the matching checksums.txt.
RUN curl -fsSL "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz" \
        -o /tmp/hcloud.tar.gz \
    && echo "${HCLOUD_SHA256}  /tmp/hcloud.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/hcloud.tar.gz -C /usr/local/bin hcloud \
    && rm /tmp/hcloud.tar.gz

# --- Supabase CLI ---
# SHA256-verified, parallel to uv/hcloud. Used by per-app projects under /work
# that talk to Supabase. The agent should NEVER run `supabase login` inside
# the sandbox (that writes the access token to ~/.supabase/access-token on
# disk). Instead, store SUPABASE_ACCESS_TOKEN in the per-app Infisical project
# and invoke via `infisical run -- supabase <cmd>` so the token lives only in
# process memory for the command's duration. See docs/USAGE.md.
RUN curl -fsSL "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_linux_amd64.tar.gz" \
        -o /tmp/supabase.tar.gz \
    && echo "${SUPABASE_CLI_SHA256}  /tmp/supabase.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/supabase.tar.gz -C /usr/local/bin supabase \
    && rm /tmp/supabase.tar.gz

# --- Infisical CLI (single Go binary) ---
# For use by app projects under /work that have their own Infisical workspace
# (`infisical login` + `infisical run -- <cmd>`). Distinct from the host
# cred-daemon, which fetches *operational* secrets for the agent-vps wallet
# and routes them to bind-mounted files. The two workspaces / identities
# don't see each other. Login state is intentionally NOT persisted across
# container rebuilds — see docs/USAGE.md.
#
# Manual APT setup (no `setup.deb.sh | bash`). Inlines exactly what the
# upstream Cloudsmith setup script does — fetch the GPG key file, dearmor
# to a keyring, write sources.list. Subsequent apt installs are GPG-verified.
RUN curl -1sLf https://artifacts-cli.infisical.com/infisical.gpg \
        | gpg --dearmor -o /usr/share/keyrings/infisical-archive-keyring.gpg \
    && chmod 0644 /usr/share/keyrings/infisical-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/infisical-archive-keyring.gpg] https://artifacts-cli.infisical.com/deb stable main" \
        > /etc/apt/sources.list.d/infisical.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends "infisical=${INFISICAL_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# --- AI coding CLIs — global install via pnpm ---
# See --allow-build rationale above (wrangler block).
RUN pnpm add -g \
      --allow-build=@anthropic-ai/claude-code \
      --allow-build=@openai/codex \
      --allow-build=@google/gemini-cli \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
      "@google/gemini-cli@${GEMINI_CLI_VERSION}"

# `claude-yolo` — short alias for `claude --dangerously-skip-permissions`.
# Mirrors the laptop convenience; running YOLO mode is the intended posture
# for this sandbox per docs/REQUIREMENTS.md §1 (the whole VPS architecture
# exists to make it safe). A PATH script rather than a shell alias so it
# also works in non-interactive `bash -c` and `docker exec` invocations.
RUN cat >/usr/local/bin/claude-yolo <<'EOF' && chmod 0755 /usr/local/bin/claude-yolo
#!/usr/bin/env bash
exec claude --dangerously-skip-permissions "$@"
EOF

# --- non-root agent user ---
# Pre-create the volume mount paths so named volumes inherit agent:agent
# ownership on first attach (Docker copies the existing dir's mode/ownership
# into an empty named volume). Without this, first `claude login` etc. would
# write to a root-owned volume and fail.
#
# Also drops two supply-chain hardening configs under ~agent/.config (neither
# tool reads from a system-wide /etc/ path; the sandbox is single-user, so
# per-user IS as global as it gets):
#   - pnpm:  minimumReleaseAge=10080  (7 days, in minutes) — refuses package
#            versions published in the last week so the community has time to
#            spot and yank a malicious release before we pull it.
#            blockExoticSubdeps=true — transitive deps must resolve from the
#            registry; git URLs / tarball URLs as TRANSITIVE deps are refused
#            (your own package.json can still declare exotic direct deps).
#            MUST be YAML camelCase here — pnpm 10+ ignores these from .npmrc.
#   - uv:    exclude-newer="7 days" — rolling window relative to install time,
#            mirrors the pnpm minimumReleaseAge guard. uv has no equivalent of
#            blockExoticSubdeps; Python-side transitive deps from git/URL
#            sources are NOT blocked. Known gap, revisit if astral ships it.
#
# Ubuntu 24.04 base ships a default `ubuntu` user at UID 1000 (new in noble);
# remove it first so our `agent` user can claim 1000.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd --create-home --shell /bin/bash --uid 1000 agent \
    && mkdir -p /work \
                /home/agent/.claude \
                /home/agent/.codex \
                /home/agent/.gemini \
                /home/agent/.config/pnpm \
                /home/agent/.config/uv \
                /home/agent/.local/state/agent-state \
    && printf 'minimumReleaseAge: 10080\nblockExoticSubdeps: true\n' \
        > /home/agent/.config/pnpm/config.yaml \
    && printf 'exclude-newer = "7 days"\n' > /home/agent/.config/uv/uv.toml \
    && chown -R agent:agent /work /home/agent

# --- entrypoint + env-export sourcing for ALL shell flavors ---
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY profile.d-agent-env.sh /etc/profile.d/agent-env.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /etc/profile.d/agent-env.sh

# Cover the three shell flavors so rotated env vars reach every entry point:
#   - login interactive (e.g. tmux new window): /etc/profile + profile.d
#   - non-login interactive (`docker exec -it sandbox bash`): /etc/bash.bashrc
#   - non-interactive bash (`docker exec sandbox bash -c '...'`): BASH_ENV
RUN printf '\n[ -r /etc/profile.d/agent-env.sh ] && . /etc/profile.d/agent-env.sh\n' \
      >> /etc/bash.bashrc
ENV BASH_ENV=/etc/profile.d/agent-env.sh

# tmux:
#  - new windows use a bash login shell so /etc/profile.d/agent-env.sh
#    is re-sourced, picking up rotated env values without container restart
#  - mouse on: scroll wheel scrolls the scrollback buffer directly
#    (hold Option/Shift to make selections bypass tmux for terminal-native copy)
#  - remain-on-exit failed: when a pane's *direct command* (i.e. the bash
#    login shell set by default-command above) dies abnormally — SIGKILL
#    from cgroup OOM, segfault, non-zero exit — keep the pane around
#    showing "[exited]" instead of closing it. Note: a Claude/Codex
#    process killed inside an interactive bash does NOT trigger this;
#    bash absorbs the SIGCHLD and stays alive, so the pane stays via
#    normal bash behavior. The cascade this PREVENTS is the heavier one:
#    OOM kills the *bash shell itself* (or its env is corrupted) → pane
#    closes → if last window in session, session ends → if last session,
#    tmux server exits → all your other sessions die with it. With this
#    setting, the dead pane is preserved, session and server live on.
#    Normal pane closes (user typing `exit`, exit code 0) still close.
RUN printf '%s\n' \
      'set-option -g default-command "/bin/bash -l"' \
      'set -g mouse on' \
      'set -g remain-on-exit failed' \
      >> /etc/tmux.conf

# Known limitation, documented for the user: `docker exec sandbox <binary>`
# (running a binary directly, no shell) bypasses all of the above. The
# command runs with the container's frozen entrypoint env. Use
# `docker exec -it sandbox bash -lc '<cmd>'` to pick up fresh env-export
# values, or attach to the tmux session.

USER agent
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
