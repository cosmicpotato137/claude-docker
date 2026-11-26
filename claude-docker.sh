#!/usr/bin/env bash
# Run Claude Code in a persistent Docker container tied specific folders
# or files, mounted as read-only or read-write.
#
# Usage: claude-docker [options] [-- claude args...]
#
#   -r, --ro PATH[:DEST]   Mount PATH read-only (repeatable)
#   -w, --rw PATH[:DEST]   Mount PATH read-write (repeatable)
#   -m, --mounts FILE      Read mounts from FILE (repeatable). If no -r/-w/-m
#                          is given, mounts.conf next to this script is used.
#   -C, --workdir DIR      Working directory in the container (default: /workspace)
#   -e, --env VAR[=VALUE]  Set an environment variable in the container (repeatable)
#   -n, --name NAME        Container name (default: claude-<folder>-<hash>)
#       --shell            Start bash instead of claude
#       --rm               Start a new one-off container, removed on exit
#       --build            Rebuild the image first
#       --no-cache         Start claude from scratch (picks up new claude/MCP releases)
#   -h, --help             Show this help
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "claude-docker: $*" >&2; exit 1; }
warn() { echo "claude-docker: $*" >&2; }
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

# label CONTAINER KEY: print a label of an existing container.
label() { docker container inspect -f "{{index .Config.Labels \"$2\"}}" "$1"; }

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
script_dir="$(dirname "$(resolve "$script")")"
if [ -n "${CLAUDE_DOCKER_DIR:-}" ]; then
  [ -d "$CLAUDE_DOCKER_DIR" ] || die "CLAUDE_DOCKER_DIR is not a directory: $CLAUDE_DOCKER_DIR"
  script_dir="$(cd "$CLAUDE_DOCKER_DIR" && pwd -P)"
fi
image="${CLAUDE_DOCKER_IMAGE:-claude-docker}"
passthrough_env="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL"
folder="$(pwd -P)"

# ---------------------------------------------------------------------------
# Parse options. Mounts are only collected here and validated later, because
# they are ignored when the folder's container already exists.
mount_specs=()     # "mode spec" pairs from -r/-w, in order
mounts_files=()
env_args=()
claude_args=()
ignored_args=()    # every argument except --shell, for the "ignored" warning
workdir=/workspace
name=""
build=false
no_cache=false
shell=false
ephemeral=false

while [ $# -gt 0 ]; do
  case "$1" in
    --shell) shell=true; shift; continue ;;
    --) ignored_args+=("$@") ;;
    -r|--ro|-w|--rw|-m|--mounts|-C|--workdir|-e|--env|-n|--name)
      need_arg "$@"; ignored_args+=("$1" "$2") ;;
    *) ignored_args+=("$1") ;;
  esac
  case "$1" in
    -r|--ro) mount_specs+=(ro "$2"); shift 2 ;;
    -w|--rw) mount_specs+=(rw "$2"); shift 2 ;;
    -m|--mounts) mounts_files+=("$2"); shift 2 ;;
    -C|--workdir) workdir="$2"; shift 2 ;;
    -e|--env) env_args+=(-e "$2"); shift 2 ;;
    -n|--name) name="$2"; shift 2 ;;
    --rm) ephemeral=true; shift ;;
    --build) build=true; shift ;;
    --no-cache) no_cache=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; claude_args+=("$@"); break ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# Per-session settings: terminal and auth/environment from the host.
session_args=()
if [ -t 0 ] && [ -t 1 ]; then session_args+=(-it); else session_args+=(-i); fi
for var in $passthrough_env; do
  if [ -n "${!var:-}" ]; then session_args+=(-e "$var"); fi
done
if [ -f "$script_dir/.env" ]; then session_args+=(--env-file "$script_dir/.env"); fi

# ---------------------------------------------------------------------------
# Reuse the folder's container if it has one (unless --rm).
if ! $ephemeral; then
  existing="$(docker ps -a --filter "label=claude-docker.folder=$folder" --format '{{.Names}}' | head -n 1)"
  if [ -n "$existing" ]; then
    if [ ${#ignored_args[@]} -gt 0 ]; then
      warn "this folder already has container '$existing'; ignoring: ${ignored_args[*]}"
      warn "to apply them, remove it first (docker rm -f $existing) or use --rm for a one-off container"
    fi
    if [ "$(docker container inspect -f '{{.Image}}' "$existing")" != \
         "$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)" ]; then
      warn "note: '$existing' uses an older '$image' image; remove it (docker rm -f $existing) to switch"
    fi
    if $shell; then
      cmd=(bash)
    else
      cmd=(claude)
      while IFS= read -r arg; do
        [ -z "$arg" ] || cmd+=("$arg")
      done <<< "$(label "$existing" claude-docker.claude-args)"
    fi
    if [ "$(docker container inspect -f '{{.State.Running}}' "$existing")" != true ]; then
      docker start "$existing" >/dev/null
    fi
    warn "using container '$existing'"
    exec docker exec -w "$(label "$existing" claude-docker.workdir)" \
      "${session_args[@]}" "$existing" "${cmd[@]}"
  fi
fi

# ---------------------------------------------------------------------------
# Create a new container from the options given.
mount_args=()
mount_srcs=()   # host paths, symlinks resolved
mount_given=()  # host paths as given (absolute, symlinks not resolved)
mount_dests=()
mount_modes=()
mount_dirs=()
mount_summary=()
# Host paths a container must not be able to write: this script (and the path
# it was invoked by) and its directory, plus the mounts files in use.
protected_paths=("$script_dir" "$script")

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

# Hash of the mount set, used to name its config volume.
mount_set_hash() {
  local i
  for ((i = 0; i < ${#mount_srcs[@]}; i++)); do
    echo "${mount_modes[i]} ${mount_srcs[i]} ${mount_dests[i]}"
  done | LC_ALL=C sort | sha256 | cut -c1-12
}

for ((i = 0; i < ${#mount_specs[@]}; i += 2)); do
  add_mount "${mount_specs[i]}" "${mount_specs[i + 1]}"
done
if [ ${#mount_specs[@]} -eq 0 ] && [ ${#mounts_files[@]} -eq 0 ] && [ -f "$script_dir/mounts.conf" ]; then
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

# One config volume per mount set: hooks, settings or MCP servers a session
# writes there only reach later sessions with the same access.
volume="${CLAUDE_DOCKER_VOLUME:-claude-docker-config-$(mount_set_hash)}"

case "$workdir" in /*) ;; *) workdir="/workspace/$workdir" ;; esac
[ "$workdir" = "/" ] || workdir="${workdir%/}"

# claude's arguments: --add-dir for mounts outside the working directory, then
# anything after `--`. Stored on the container so later sessions reuse them.
claude_cmd_args=()
for d in ${mount_dirs[@]+"${mount_dirs[@]}"}; do
  case "$d/" in "${workdir%/}/"*) ;; *) claude_cmd_args+=(--add-dir "$d") ;; esac
done
claude_cmd_args+=(${claude_args[@]+"${claude_args[@]}"})

if $shell; then
  [ ${#claude_args[@]} -eq 0 ] || die "arguments after -- are for claude and can't be combined with --shell"
  cmd=(bash)
else
  cmd=(claude ${claude_cmd_args[@]+"${claude_cmd_args[@]}"})
fi

if [ -z "$name" ]; then
  if $ephemeral; then
    name="claude-$(date +%Y%m%d-%H%M%S)"
  else
    base_name="$(basename "$folder" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/-*$//')"
    name="claude-${base_name:-root}-$(printf '%s' "$folder" | sha256 | cut -c1-8)"
  fi
fi

if $build; then
  [ -f "$script_dir/Dockerfile" ] || die "no Dockerfile in $script_dir. If $script is a copy, replace it with a symlink to claude-docker.sh or set CLAUDE_DOCKER_DIR to the directory that holds the Dockerfile"
  build_args=(-t "$image" -f "$script_dir/Dockerfile")
  # Match the host user so bind-mount writes are owned correctly on Linux.
  if [ "$(uname -s)" = Linux ] && [ "$(id -u)" != 0 ]; then
    build_args+=(--build-arg "USER_UID=$(id -u)" --build-arg "USER_GID=$(id -g)")
  fi
  if $no_cache; then
    build_args+=(--no-cache --pull)
  elif docker image inspect "$image" >/dev/null 2>&1; then
    build_args+=(--quiet)
  fi
  warn "building image '$image'..."
  docker build "${build_args[@]}" "$script_dir" >/dev/null
fi

# The container needs no capabilities or setuid binaries; the PID limit stops
# runaway process trees from starving the Docker VM.
container_args=(--init --name "$name" -w "$workdir" -v "$volume:/home/node/.claude"
  --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=1024
  ${env_args[@]+"${env_args[@]}"} ${mount_args[@]+"${mount_args[@]}"})

if $ephemeral; then
  what="starting one-off container"
else
  what="creating container"
fi
if [ ${#mount_summary[@]} -gt 0 ]; then
  warn "$what '$name' with mounts:"
  printf '%s\n' "${mount_summary[@]}" >&2
else
  warn "$what '$name' with no host mounts (see --help)"
fi
warn "config volume '$volume'"

if $ephemeral; then
  exec docker run --rm "${container_args[@]}" "${session_args[@]}" "$image" "${cmd[@]}"
fi

# A placeholder main process keeps the container running between sessions.
# The labels let later runs in this folder find it and start claude the same way.
docker create --restart unless-stopped "${container_args[@]}" \
  --label "claude-docker.folder=$folder" \
  --label "claude-docker.workdir=$workdir" \
  --label "claude-docker.claude-args=$(printf '%s\n' ${claude_cmd_args[@]+"${claude_cmd_args[@]}"})" \
  "$image" sleep infinity >/dev/null
docker start "$name" >/dev/null
exec docker exec -w "$workdir" "${session_args[@]}" "$name" "${cmd[@]}"