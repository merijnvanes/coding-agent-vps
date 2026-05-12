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

# --- non-root agent user ---
RUN useradd --create-home --shell /bin/bash --uid 1000 agent \
    && mkdir -p /work \
    && chown agent:agent /work

# --- entrypoint ---
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER agent
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
