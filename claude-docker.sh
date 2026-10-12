#!/usr/bin/env bash
# Builds the Claude Code image and starts a new container with host paths
# mounted read-only or read-write.
#
# Usage: ./claude-docker.sh [options] [-- claude args...]
#
#   -r, --ro PATH[:DEST]   Mount PATH read-only (repeatable)
#   -w, --rw PATH[:DEST]   Mount PATH read-write (repeatable)
#   -m, --mounts FILE      Read mounts from FILE (repeatable). If no -r/-w/-m
#                          is given, mounts.conf next to this script is used.
#   -C, --workdir DIR      Working directory in the container (default: /workspace)
#   -e, --env VAR[=VALUE]  Set an environment variable in the container (repeatable)
#   -n, --name NAME        Container name (default: claude-<timestamp>)
#       --shell            Start bash instead of claude
#       --no-build         Don't rebuild the image first
#       --no-cache         Rebuild from scratch (picks up new claude/MCP releases)
#   -h, --help             Show this help
#
# DEST defaults to /workspace/<basename of PATH>; a relative DEST is placed
# under /workspace. Directories mounted outside the working directory are passed
# to claude with --add-dir. Arguments after `--` go to claude, e.g.
#   ./claude-docker.sh -w ~/code/app -r ~/Documents/specs:specs -- --model opus
#
# Mounts file: one "<ro|rw> PATH[:DEST]" per line; blank lines and lines
# starting with # are ignored; relative paths resolve against the file's
# directory. See mounts.conf.example.
#
# Auth: ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`)
# and other ANTHROPIC_* settings are passed through when set, as is a .env file
# next to this script. Otherwise run /login once inside the container. Auth,
# settings and MCP state persist in the "claude-docker-config" volume.
#
# Environment: CLAUDE_DOCKER_IMAGE (default: claude-docker),
#              CLAUDE_DOCKER_VOLUME (default: claude-docker-config)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
image="${CLAUDE_DOCKER_IMAGE:-claude-docker}"
volume="${CLAUDE_DOCKER_VOLUME:-claude-docker-config}"
passthrough_env="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "claude-docker: $*" >&2; exit 1; }
need_arg() { [ $# -ge 2 ] || die "$1 requires an argument"; }

mount_args=()
mount_dests=()
mount_dirs=()
mount_summary=()
mounts_files=()
env_args=()
claude_args=()
workdir=/workspace
name="claude-$(date +%Y%m%d-%H%M%S)"
build=true
no_cache=false
shell=false

# add_mount MODE PATH[:DEST] [BASE_DIR]
# Relative PATHs resolve against BASE_DIR (default: the current directory).
add_mount() {
  local mode="$1" spec="$2" base="${3:-$PWD}" src dest d
  case "$mode" in ro|rw) ;; *) die "invalid mode '$mode' (expected ro or rw)" ;; esac

  src="${spec%%:*}"
  dest=""
  [ "$src" = "$spec" ] || dest="${spec#*:}"
  case "$src" in
    "~") src="$HOME" ;;
    "~/"*) src="$HOME/${src#"~/"}" ;;
    /*) ;;
    *) src="$base/$src" ;;
  esac
  [ -e "$src" ] || die "path does not exist: $src"
  if [ -d "$src" ]; then
    src="$(cd "$src" && pwd -P)"
  else
    src="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")"
  fi

  [ -n "$dest" ] || dest="$(basename "$src")"
  case "$dest" in /*) ;; *) dest="/workspace/$dest" ;; esac
  [ "$dest" = "/" ] || dest="${dest%/}"
  case "$dest" in *:*) die "container path may not contain ':': $dest" ;; esac
  for d in ${mount_dests[@]+"${mount_dests[@]}"}; do
    [ "$d" != "$dest" ] || die "two mounts map to $dest; give one an explicit DEST (PATH:DEST)"
  done

  mount_args+=(-v "$src:$dest:$mode")
  mount_dests+=("$dest")
  if [ -d "$src" ]; then mount_dirs+=("$dest"); fi
  mount_summary+=("  $mode  $src -> $dest")
}

read_mounts_file() {
  local file="$1" base mode spec line_no=0
  [ -f "$file" ] || die "mounts file not found: $file"
  base="$(cd "$(dirname "$file")" && pwd -P)"
  while read -r mode spec || [ -n "$mode" ]; do
    line_no=$((line_no + 1))
    case "$mode" in ""|"#"*) continue ;; esac
    [ -n "$spec" ] || die "$file:$line_no: expected '<ro|rw> PATH[:DEST]'"
    add_mount "$mode" "$spec" "$base"
  done < "$file"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--ro) need_arg "$@"; add_mount ro "$2"; shift 2 ;;
    -w|--rw) need_arg "$@"; add_mount rw "$2"; shift 2 ;;
    -m|--mounts) need_arg "$@"; mounts_files+=("$2"); shift 2 ;;
    -C|--workdir) need_arg "$@"; workdir="$2"; shift 2 ;;
    -e|--env) need_arg "$@"; env_args+=(-e "$2"); shift 2 ;;
    -n|--name) need_arg "$@"; name="$2"; shift 2 ;;
    --shell) shell=true; shift ;;
    --no-build) build=false; shift ;;
    --no-cache) no_cache=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; claude_args+=("$@"); break ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if [ ${#mount_args[@]} -eq 0 ] && [ ${#mounts_files[@]} -eq 0 ] && [ -f "$script_dir/mounts.conf" ]; then
  mounts_files=("$script_dir/mounts.conf")
fi
for f in ${mounts_files[@]+"${mounts_files[@]}"}; do
  read_mounts_file "$f"
done

case "$workdir" in /*) ;; *) workdir="/workspace/$workdir" ;; esac
[ "$workdir" = "/" ] || workdir="${workdir%/}"

if $shell; then
  [ ${#claude_args[@]} -eq 0 ] || die "arguments after -- are for claude and can't be combined with --shell"
  cmd=(bash)
else
  cmd=(claude)
  for d in ${mount_dirs[@]+"${mount_dirs[@]}"}; do
    case "$d/" in "${workdir%/}/"*) ;; *) cmd+=(--add-dir "$d") ;; esac
  done
  cmd+=(${claude_args[@]+"${claude_args[@]}"})
fi

if $build; then
  build_args=(-t "$image")
  # Match the host user so bind-mount writes are owned correctly on Linux.
  if [ "$(uname -s)" = Linux ] && [ "$(id -u)" != 0 ]; then
    build_args+=(--build-arg "USER_UID=$(id -u)" --build-arg "USER_GID=$(id -g)")
  fi
  if $no_cache; then
    build_args+=(--no-cache --pull)
  elif docker image inspect "$image" >/dev/null 2>&1; then
    build_args+=(--quiet)
  fi
  echo "claude-docker: building image '$image'..." >&2
  docker build "${build_args[@]}" "$script_dir" >/dev/null
fi

run_args=(--rm --init --name "$name" -w "$workdir" -v "$volume:/home/node/.claude")
if [ -t 0 ] && [ -t 1 ]; then run_args+=(-it); else run_args+=(-i); fi
for var in $passthrough_env; do
  if [ -n "${!var:-}" ]; then run_args+=(-e "$var"); fi
done
if [ -f "$script_dir/.env" ]; then run_args+=(--env-file "$script_dir/.env"); fi

if [ ${#mount_summary[@]} -gt 0 ]; then
  echo "claude-docker: starting container '$name' with mounts:" >&2
  printf '%s\n' "${mount_summary[@]}" >&2
else
  echo "claude-docker: starting container '$name' with no host mounts (see --help)" >&2
fi

exec docker run "${run_args[@]}" \
  ${mount_args[@]+"${mount_args[@]}"} \
  ${env_args[@]+"${env_args[@]}"} \
  "$image" "${cmd[@]}"
