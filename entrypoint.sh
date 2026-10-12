#!/usr/bin/env bash
# Registers the MCP servers baked into the image as user-scoped servers, then
# runs the given command. The merge happens on every start so servers added to
# mcp-servers.json show up after a rebuild even though ~/.claude.json lives in a
# persistent volume. Servers added at runtime with `claude mcp add` are kept.
set -euo pipefail

config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
config_file="$config_dir/.claude.json"
mcp_file=/opt/claude/mcp-servers.json

mkdir -p "$config_dir"
[ -s "$config_file" ] || echo '{}' > "$config_file"

# Skip the first-run theme/login screens when credentials come from the env.
skip_onboarding=false
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  skip_onboarding=true
fi

tmp="$(mktemp "$config_file.XXXXXX")"
jq --slurpfile mcp "$mcp_file" --argjson skip "$skip_onboarding" '
  .mcpServers = ((.mcpServers // {}) + ($mcp[0].mcpServers // {}))
  | if $skip then .hasCompletedOnboarding = true else . end
' "$config_file" > "$tmp"
mv "$tmp" "$config_file"

exec "$@"
