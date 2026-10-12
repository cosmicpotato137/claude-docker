#!/usr/bin/env bash
# Builds the Claude Code image and runs claude in a persistent container with
# host paths mounted read-only or read-write.
#
# Usage: ./claude-docker.sh [options] [-- claude args...]
#
#   -r, --ro PATH[:DEST]   Mount PATH read-only (repeatable)
#   -w, --rw PATH[:DEST]   Mount PATH read-write (repeatable)
#   -m, --mounts FILE      Read mounts from FILE (repeatable). If no -r/-w/-m
#                          is given, mounts.conf next to this script is used.
#   -C, --workdir DIR      Working directory in the container (default: /workspace)
#   -e, --env VAR[=VALUE]  Set an environment variable for this session (repeatable)
#   -n, --name NAME        Container name (default: claude-<mount set hash>)
#       --shell            Start bash instead of claude
#       --recreate         Remove the existing container and create a new one
#                          (needed to pick up a rebuilt image)
#       --rm               One-off container, removed when the session exits
#       --no-build         Don't rebuild the image first
#       --no-cache         Rebuild from scratch (picks up new claude/MCP releases)
#   -h, --help             Show this help
#
# Container lifecycle: the first run creates a container that keeps running in
# the background (and restarts with Docker) until you remove it with
#   docker rm -f <name>
# Each run of this script opens a new claude (or bash) session in it with
# `docker exec`, so exiting the session leaves the container and anything
# installed in it intact. Several sessions can run in it at once. The default
# name is derived from the mount set, so running again with the same mounts
# reuses the same container; mounts are fixed when the container is created,
# so a different mount set gets a different container.
#
# DEST defaults to /workspace/<basename of PATH>; a relative DEST is placed
# under /workspace. DEST must be /workspace or a path under /workspace or
# /home/node. Directories mounted outside the working directory are passed
# to claude with --add-dir. Arguments after `--` go to claude, e.g.
#   ./claude-docker.sh -w ~/code/app -r ~/Documents/specs:specs -- --model opus
#
# Mounts file: one "<ro|rw> PATH[:DEST]" per line; blank lines and lines
# starting with # are ignored; relative paths resolve against the file's
# directory. See mounts.conf.example.
#
# Safety checks: only directories and regular files can be mounted. A
# read-write mount may not overlap this script's directory or a mounts file in
# use, since the host runs or reads those. No mount may pass through a symlink
# inside a read-write mount, since an earlier session could have planted it.
#
# Auth: ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`)
# and other ANTHROPIC_* settings are passed to each session when set, as is a
# .env file next to this script. Otherwise run /login inside the container. Auth, settings and MCP state persist in a
# config volume per mount set (claude-docker-config-<hash>), so a session can't
# leave hooks or MCP servers behind for a later session with different access.
#
# Environment: CLAUDE_DOCKER_IMAGE (default: claude-docker),
#              CLAUDE_DOCKER_VOLUME (one config volume for every mount set;
#              shares state between them)
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "claude-docker: $*" >&2; exit 1; }
need_arg() { [ $# -ge 2 ] || die "$1 requires an argument"; }

# resolve PATH: print PATH as an absolute path with all symlinks resolved.
resolve() {
  local p="$1" target
  while [ -L "$p" ]; do
    target="$(readlink "$p")"
    case "$target" in /*) p="$target" ;; *) p="$(dirname "$p")/$target" ;; esac
  done
  if [ -d "$p" ]; then
    (cd "$p" && pwd -P)
  else
    echo "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  fi
}

# is_within PATH DIR: true if PATH is DIR or inside it.
is_within() {
  [ "$2" = / ] || [ "$1" = "$2" ] || case "$1" in "$2"/*) true ;; *) false ;; esac
}

# no_symlinks_below DIR REL: die if any component of DIR/REL below DIR is a
# symlink.
no_symlinks_below() {
  local path="$1" part parts
  IFS=/ read -r -a parts <<< "$2"
  for part in "${parts[@]}"; do
    path="$path/$part"
    [ ! -L "$path" ] || die "$path is a symlink inside a read-write mount; refusing to mount through it"
  done
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
script_dir="$(dirname "$(resolve "$script")")"
image="${CLAUDE_DOCKER_IMAGE:-claude-docker}"
passthrough_env="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL"

mount_args=()
mount_srcs=()   # host paths, symlinks resolved
mount_given=()  # host paths as given (absolute, symlinks not resolved)
mount_dests=()
mount_modes=()
mount_dirs=()
mount_summary=()
mounts_files=()
# Host paths a container must not be able to write: this script (and the path
# it was invoked by) and its directory, plus the mounts files in use.
protected_paths=("$script_dir" "$script")
env_args=()
claude_args=()
workdir=/workspace
name=""
build=true
no_cache=false
shell=false
recreate=false
ephemeral=false

# add_mount MODE PATH[:DEST] [BASE_DIR]
# Relative PATHs resolve against BASE_DIR (default: the current directory).
add_mount() {
  local mode="$1" spec="$2" base="${3:-$PWD}" src given dest d
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
  given="$src"
  src="$(resolve "$src")"
  # No sockets (e.g. docker.sock) or devices.
  [ -d "$src" ] || [ -f "$src" ] || die "only directories and regular files can be mounted: $src"

  [ -n "$dest" ] || dest="$(basename "$src")"
  case "$dest" in /*) ;; *) dest="/workspace/$dest" ;; esac
  dest="$(printf '%s' "$dest" | tr -s /)"
  [ "$dest" = "/" ] || dest="${dest%/}"
  case "$dest" in *:*) die "container path may not contain ':': $dest" ;; esac
  case "$dest/" in */./*|*/../*) die "container path may not contain . or ..: $dest" ;; esac
  # Keep image paths (e.g. /etc/claude-code/managed-settings.json) intact.
  case "$dest" in
    /workspace|/workspace/*|/home/node/?*) ;;
    *) die "container path must be /workspace or under /workspace or /home/node: $dest" ;;
  esac
  [ "$dest" != /home/node/.claude ] || die "$dest is reserved for the config volume"
  for d in ${mount_dests[@]+"${mount_dests[@]}"}; do
    [ "$d" != "$dest" ] || die "two mounts map to $dest; give one an explicit DEST (PATH:DEST)"
  done

  mount_args+=(-v "$src:$dest:$mode")
  mount_srcs+=("$src")
  mount_given+=("$given")
  mount_dests+=("$dest")
  mount_modes+=("$mode")
  if [ -d "$src" ]; then mount_dirs+=("$dest"); fi
  mount_summary+=("  $mode  $src -> $dest")
}

read_mounts_file() {
  local file="$1" base mode spec line_no=0
  [ -f "$file" ] || die "mounts file not found: $file"
  base="$(cd "$(dirname "$file")" && pwd -P)"
  protected_paths+=("$base/$(basename "$file")" "$(resolve "$file")")
  while read -r mode spec || [ -n "$mode" ]; do
    line_no=$((line_no + 1))
    case "$mode" in ""|"#"*) continue ;; esac
    [ -n "$spec" ] || die "$file:$line_no: expected '<ro|rw> PATH[:DEST]'"
    add_mount "$mode" "$spec" "$base"
  done < "$file"
}

# Hash of the mount set, used to name its config volume and container.
mount_set_hash() {
  local i
  for ((i = 0; i < ${#mount_srcs[@]}; i++)); do
    echo "${mount_modes[i]} ${mount_srcs[i]} ${mount_dests[i]}"
  done | LC_ALL=C sort | sha256 | cut -c1-12
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
    --recreate) recreate=true; shift ;;
    --rm) ephemeral=true; shift ;;
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

# Refuse to mount this script or the parent directory
for ((i = 0; i < ${#mount_srcs[@]}; i++)); do
  [ "${mount_modes[i]}" = rw ] || continue
  for p in "${protected_paths[@]}"; do
    if is_within "$p" "${mount_srcs[i]}" || is_within "${mount_srcs[i]}" "$p"; then
      die "refusing to mount ${mount_srcs[i]} read-write: it overlaps $p, which the host uses to start containers (mount it read-only instead)"
    fi
  done
done

# An earlier session may have planted symlinks in a read-write mount, so don't
# follow any on the way to a nested mount: neither on the host source path nor
# on the mount point, which Docker creates inside the parent mount.
for ((i = 0; i < ${#mount_srcs[@]}; i++)); do
  for ((j = 0; j < ${#mount_srcs[@]}; j++)); do
    [ "$i" != "$j" ] && [ "${mount_modes[j]}" = rw ] || continue
    if is_within "${mount_dests[i]}" "${mount_dests[j]}"; then
      no_symlinks_below "${mount_srcs[j]}" "${mount_dests[i]#"${mount_dests[j]}"/}"
    fi
    for p in "${mount_srcs[j]}" "${mount_given[j]}"; do
      if [ "${mount_given[i]}" != "$p" ] && is_within "${mount_given[i]}" "$p"; then
        no_symlinks_below "$p" "${mount_given[i]#"$p"/}"
      fi
    done
  done
done

mounts_hash="$(mount_set_hash)"

# One config volume per mount set: hooks, settings or MCP servers a session
# writes there only reach later sessions with the same access.
volume="${CLAUDE_DOCKER_VOLUME:-claude-docker-config-$mounts_hash}"

if [ -z "$name" ]; then
  if $ephemeral; then name="claude-$(date +%Y%m%d-%H%M%S)"; else name="claude-$mounts_hash"; fi
fi

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

# The container needs no capabilities or setuid binaries; the PID limit stops
# runaway process trees from starving the Docker VM.
container_args=(--init --name "$name" -w "$workdir" -v "$volume:/home/node/.claude"
  --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=1024
  --label "claude-docker.mounts=$mounts_hash")

# Per-session settings: terminal, working directory and environment.
session_args=()
if [ -t 0 ] && [ -t 1 ]; then session_args+=(-it); else session_args+=(-i); fi
for var in $passthrough_env; do
  if [ -n "${!var:-}" ]; then session_args+=(-e "$var"); fi
done
if [ -f "$script_dir/.env" ]; then session_args+=(--env-file "$script_dir/.env"); fi
session_args+=(${env_args[@]+"${env_args[@]}"})

print_mounts() {
  if [ ${#mount_summary[@]} -gt 0 ]; then
    echo "claude-docker: $1 '$name' with mounts:" >&2
    printf '%s\n' "${mount_summary[@]}" >&2
  else
    echo "claude-docker: $1 '$name' with no host mounts (see --help)" >&2
  fi
  echo "claude-docker: config volume '$volume'" >&2
}

# One-off container, removed on exit
if $ephemeral; then
  print_mounts "starting one-off container"
  exec docker run --rm "${container_args[@]}" "${session_args[@]}" \
    ${mount_args[@]+"${mount_args[@]}"} "$image" "${cmd[@]}"
fi

container_exists() { docker container inspect "$name" >/dev/null 2>&1; }

if container_exists && $recreate; then
  echo "claude-docker: removing container '$name'..." >&2
  docker rm -f "$name" >/dev/null
fi

if container_exists; then
  # Mounts are fixed at creation, so only reuse a container with the same set.
  existing="$(docker container inspect -f '{{index .Config.Labels "claude-docker.mounts"}}' "$name")"
  [ "$existing" = "$mounts_hash" ] ||
    die "container '$name' exists with a different mount set; pass --recreate to replace it or -n to use another name"
  if [ "$(docker container inspect -f '{{.Image}}' "$name")" != "$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null)" ]; then
    echo "claude-docker: note: '$name' uses an older '$image' image; pass --recreate to switch to the new one" >&2
  fi
  echo "claude-docker: using existing container '$name'" >&2
else
  print_mounts "creating container"
  # A placeholder main process keeps the container running between sessions.
  docker create --restart unless-stopped "${container_args[@]}" \
    ${mount_args[@]+"${mount_args[@]}"} "$image" sleep infinity >/dev/null
fi

if [ "$(docker container inspect -f '{{.State.Running}}' "$name")" != true ]; then
  docker start "$name" >/dev/null
fi

exec docker exec -w "$workdir" "${session_args[@]}" "$name" "${cmd[@]}"