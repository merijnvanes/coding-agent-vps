# sandbox/Dockerfile — agent runtime image
#
# Built on the VPS at cloud-init time (`docker build`). No registry pull.
# Image contains the toolchain pinned in REQUIREMENTS.md §5.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

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

# --- Node.js LTS (22) + pnpm via corepack ---
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@latest --activate

# pnpm global bin dir on PATH so `pnpm add -g X` produces invokable commands
ENV PNPM_HOME=/usr/local/pnpm
ENV PATH="${PNPM_HOME}:${PATH}"
RUN mkdir -p "${PNPM_HOME}"

# /etc/npmrc — read by both pnpm and npm. Sets minimum-release-age (REQUIREMENTS.md §5):
#   pnpm 11+ reads `minimum-release-age` in minutes  (10080 = 7d)
#   npm 11+  reads `min-release-age`     in days     (7      = 7d)
# Setting both means any package manager run inside the sandbox enforces the policy.
RUN cat >/etc/npmrc <<'EOF'
minimum-release-age=10080
min-release-age=7
EOF

# --- uv (Python package manager — single Go binary) ---
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# --- gcloud SDK ---
RUN curl -fsSL https://sdk.cloud.google.com -o /tmp/install-gcloud.sh \
    && bash /tmp/install-gcloud.sh --disable-prompts --install-dir=/opt \
    && ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud \
    && ln -sf /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil \
    && rm /tmp/install-gcloud.sh

# --- wrangler (Cloudflare) — global install via pnpm ---
RUN pnpm add -g wrangler

# --- hcloud CLI (Hetzner) ---
RUN curl -fsSL "https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz" \
      | tar -xz -C /usr/local/bin hcloud

# --- AI coding CLIs — global install via pnpm ---
RUN pnpm add -g @anthropic-ai/claude-code @openai/codex

# --- non-root agent user + agent-sockets group (GID matches host via subgid mapping) ---
# The agent-sockets group exists so the sandbox can connect() to the
# ssh-agent socket on the host. Inside the container the group's GID is
# arbitrary (3000); on the host, the rootless Docker user's /etc/subgid
# mapping translates this to the host's agent-sockets GID. Cloud-init
# configures that mapping.
RUN groupadd --gid 3000 agent-sockets \
    && useradd --create-home --shell /bin/bash --uid 1000 \
       --groups agent-sockets agent \
    && mkdir -p /work \
    && chown agent:agent /work

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

# tmux: new windows use a bash login shell so /etc/profile.d/agent-env.sh
# is re-sourced, picking up rotated env values without container restart.
RUN printf 'set-option -g default-command "/bin/bash -l"\n' >> /etc/tmux.conf

# Known limitation, documented for the user: `docker exec sandbox <binary>`
# (running a binary directly, no shell) bypasses all of the above. The
# command runs with the container's frozen entrypoint env. Use
# `docker exec -it sandbox bash -lc '<cmd>'` to pick up fresh env-export
# values, or attach to the tmux session.

USER agent
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
