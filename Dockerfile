ARG NODE_VERSION=22
ARG UV_VERSION=latest

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM node:${NODE_VERSION}-bookworm-slim

ARG CLAUDE_CODE_VERSION=latest
# npm packages providing stdio MCP servers. Installed globally so they start
# instantly instead of being fetched by `npx` on every container start.
ARG MCP_NPM_PACKAGES="@modelcontextprotocol/server-sequential-thinking @modelcontextprotocol/server-memory"
# Python packages providing stdio MCP servers, installed with `uv tool install`
# (e.g. "mcp-server-fetch mcp-server-time").
ARG MCP_PYTHON_PACKAGES=""
# Match the host user so files written to bind mounts get the right owner on
# Linux hosts. (Docker Desktop on macOS maps ownership automatically.)
ARG USER_UID=1000
ARG USER_GID=1000

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq less openssh-client procps python3 ripgrep \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/
ENV UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_PYTHON_PREFERENCE=only-system

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" ${MCP_NPM_PACKAGES} \
    && npm cache clean --force \
    && for pkg in ${MCP_PYTHON_PACKAGES}; do uv tool install "$pkg"; done

RUN if [ "${USER_GID}" != "1000" ]; then groupmod -o -g "${USER_GID}" node; fi \
    && if [ "${USER_UID}" != "1000" ]; then usermod -o -u "${USER_UID}" node; fi \
    && mkdir -p /home/node/.claude /workspace /etc/claude-code \
    && chown -R node:node /home/node /workspace

# Managed settings take precedence over user/project settings and are owned by
# root, so the container user can't re-enable bypassPermissions mode
# (--dangerously-skip-permissions, --permission-mode bypassPermissions).
COPY --chmod=644 managed-settings.json /etc/claude-code/managed-settings.json
COPY mcp-servers.json /opt/claude/mcp-servers.json
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER node
WORKDIR /workspace

# Keep all Claude state (auth, settings, ~/.claude.json) in one directory so a
# single volume persists it across containers.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude \
    DISABLE_AUTOUPDATER=1 \
    SHELL=/bin/bash

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
