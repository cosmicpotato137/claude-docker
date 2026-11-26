# Claude Docker

This repo allows claude sessions to run in auto mode with lower security risk by running them in a docker contanier with controlled file and folder mounts. It was inspired when I noticed some of my sessions crawling through my disk in search of related files and ending up in directories I didn't want them looking.

## Install

Put a symlink to this script on your PATH, (e.g. `ln -s "$PWD/claude-docker.sh" /usr/local/bin/claude-docker`). The script follows the symlink to find the folder it really lives in, which holds the Dockerfile, .env and mounts.conf. If you copy or hard-link the script instead, it looks for those files next to the copy and won't find them: set `CLAUDE_DOCKER_DIR` to the folder that holds them.

## Safety

Only directories and regular files can be mounted. A read-write mount may not include this script's directory or any mounts.conf in use. This is because containers should not be able to modify their own permissions orentrypoints. Similarly, no mount may access a symlink inside a read-write mount, since an earlier session could have planted it.

## Container Lifecycle

Each container is tied to the folder in which this script is run. The first run build the image and creates that folder's container with the options given. The container runs in the background until you remove it with: `docker rm -f <name>`

Every subsequent run in the same folder accesses the same docker container with `docker exec`, using the options it was created with. Any other options passed then are ignored, with a warning. Updating the container requires it be removed and run again. Exiting a session leaves the container and anything installed in it intact.

Using `--rm`, a new container is always created from the options given, whether or not the folder already has one, and it is removed when the session ends.

## Mounts

DEST defaults to `/workspace/<basename of PATH>`; a relative DEST is placed under /workspace. DEST must be `/workspace` or a path under `/workspace` or `/home/node`. Directories mounted outside the working directory are passedto claude with `--add-dir`. Arguments after `--` go to claude, e.g.
  claude-docker -w ~/code/app -r ~/Documents/specs:specs -- --model opus

A mounts.conf may be passed with -m, but defaults to the mounts.conf defined in this directory. The file can contain one `<ro|rw> PATH[:DEST]` per line. Blank lines and lines starting with `#` are ignored. Relative paths resolve against the file's directory. See mounts.conf.example.

## Auth

ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) and other `ANTHROPIC_*` settings are passed to each session when set, as is a .env file next to this script. Auth, settings and MCP state persist in a config volume per mount (`claude-docker-config-<hash>`), so a session can't leave hooks or MCP serversbehind for a later session with different access.

## Environment

- `CLAUDE_DOCKER_DIR` (directory with the Dockerfile; default: the directory of 
this script, symlinks followed)
- `CLAUDE_DOCKER_IMAGE` (default: `claude-docker`)
- `CLAUDE_DOCKER_VOLUME` (records auth and mounts between sessions)