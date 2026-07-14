FROM node:20-bookworm

# ---- Base tooling ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      gnupg \
      iptables \
      ipset \
      dnsutils \
      iproute2 \
      jq \
      less \
      gosu \
      procps \
      openssh-client \
      netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# ---- Claude Code CLI ----
RUN npm install -g @anthropic-ai/claude-code

# The node:20 image ships a "node" user (uid 1000). The entrypoint starts as
# root (to program the firewall), then drops to this user via gosu. We do NOT
# install sudo — combined with --security-opt no-new-privileges that means the
# only path to root is the entrypoint itself, which immediately drops it.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

# Workspace is where the host repo gets mounted.
RUN mkdir -p /workspace && chown node:node /workspace
WORKDIR /workspace

# Persist Claude's config/creds across runs (mounted as a named volume).
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# NOTE: no `USER node` here — entrypoint runs as root then drops privileges.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
