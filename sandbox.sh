#!/usr/bin/env bash
set -euo pipefail

# Print status lines with a leading [tag] in orange, the rest in the default color.
_echo() {
  local msg="$*"
  if [[ "$msg" == \[*\]* ]]; then
    printf '\033[38;5;208m%s\033[0m%s\n' "${msg%%]*}]" "${msg#*]}"
  else
    printf '%s\n' "$msg"
  fi
}

IMAGE="claude-sandbox:latest"
# Resolve the real location of this script even when invoked via a PATH symlink
# (e.g. ~/.local/bin/sandbox-claude -> .../claude-sandbox/sandbox.sh), so the
# Dockerfile and .env are always found next to the real script.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  link="$(readlink "$SELF")"
  case "$link" in
    /*) SELF="$link" ;;
    *)  SELF="$(dirname "$SELF")/$link" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

# Local, gitignored config (proxy host, ports, etc.). Sourced if present. Use
# ${VAR:=default} inside it so a value passed on the command line still wins.
# Copy .env.example to .env to get started.
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/.env"
fi

# Host Claude config to expose (read-only) into the sandbox.
HOST_CLAUDE_DIR="${HOME}/.claude"
# Config dir inside the container (matches CLAUDE_CONFIG_DIR in the Dockerfile).
CTR_CLAUDE_DIR="/home/user/.claude"

# --- Args ---
# --shell (anywhere) -> run bash instead of claude. A single positional arg is
# the folder to map (defaults to the current directory).
SHELL_MODE=0
REPO_PATH=""
for arg in "$@"; do
  case "$arg" in
    --shell) SHELL_MODE=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//; 1d'
      exit 0 ;;
    -*)
      _echo "error: unknown option '$arg'" >&2
      _echo "usage: $0 [--shell] [folder]" >&2
      exit 1 ;;
    *)
      if [ -n "$REPO_PATH" ]; then
        _echo "error: only one folder may be given (got extra '$arg')" >&2
        exit 1
      fi
      REPO_PATH="$arg" ;;
  esac
done

REPO_PATH="${REPO_PATH:-.}"                       # default: current directory
REPO_PATH="$(cd "$REPO_PATH" && pwd)"             # normalize to absolute

# What to run inside the container.
if [ "$SHELL_MODE" -eq 1 ]; then
  set -- bash
else
  set -- claude --dangerously-skip-permissions
fi

# --- Auth ---
# Supports (in precedence order): Amazon Bedrock, then a plain Anthropic API
# key / auth token (optionally against a custom ANTHROPIC_BASE_URL). Whichever
# is set determines which endpoint gets allowlisted below. Only the auth env
# vars that are actually set are forwarded into the container.
AUTH_ENV=()          # -e flags forwarding auth vars into the container
AUTH_DOMAINS=""      # endpoint host(s) to allowlist for the chosen auth
if [ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then
  AWS_REGION="${AWS_REGION:-us-east-2}"
  AUTH_ENV+=( -e CLAUDE_CODE_USE_BEDROCK=1 -e AWS_BEARER_TOKEN_BEDROCK -e AWS_REGION="$AWS_REGION" )
  AUTH_DOMAINS="bedrock-runtime.${AWS_REGION}.amazonaws.com bedrock.${AWS_REGION}.amazonaws.com"
  _echo "[sandbox] auth         : Amazon Bedrock ($AWS_REGION)"
elif [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  [ -n "${ANTHROPIC_API_KEY:-}" ]   && AUTH_ENV+=( -e ANTHROPIC_API_KEY )
  [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && AUTH_ENV+=( -e ANTHROPIC_AUTH_TOKEN )
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    AUTH_ENV+=( -e ANTHROPIC_BASE_URL )
    # Allowlist the custom endpoint's host (strip scheme, path, and port).
    host="${ANTHROPIC_BASE_URL#*://}"; host="${host%%/*}"; host="${host%%:*}"
    AUTH_DOMAINS="$host"
    _echo "[sandbox] auth         : Anthropic API ($ANTHROPIC_BASE_URL)"
  else
    AUTH_DOMAINS="api.anthropic.com"
    _echo "[sandbox] auth         : Anthropic API (api.anthropic.com)"
  fi
else
  _echo "error: no auth configured. Set one of:" >&2
  _echo "       AWS_BEARER_TOKEN_BEDROCK (+ AWS_REGION)   — Amazon Bedrock" >&2
  _echo "       ANTHROPIC_API_KEY                          — Anthropic API" >&2
  _echo "       ANTHROPIC_AUTH_TOKEN (+ ANTHROPIC_BASE_URL) — gateway/proxy" >&2
  exit 1
fi

# Hosts always allowlisted for git-over-ssh: github's ssh endpoints. If your
# ~/.ssh/config routes github through a corporate proxy, add that proxy host
# here (or via ALLOWED_DOMAINS / GIT_SSH_DOMAINS), e.g.:
#   GIT_SSH_DOMAINS="proxy.example.com ssh.github.com github.com" sandbox-claude
GIT_SSH_DOMAINS="${GIT_SSH_DOMAINS:-ssh.github.com github.com}"
# Always-on package registries (pip needs both the index and the file CDN).
DEFAULT_DOMAINS="pypi.org files.pythonhosted.org raw.githubusercontent.com api.anthropic.com"
ALLOWED_DOMAINS="${AUTH_DOMAINS} ${GIT_SSH_DOMAINS} ${DEFAULT_DOMAINS} ${ALLOWED_DOMAINS:-}"

# --- Collect all CLAUDE_CODE_* environment variables ---
CLAUDE_CODE_ENV=()
while IFS='=' read -r name value; do
  if [[ "$name" == CLAUDE_CODE_* ]]; then
    CLAUDE_CODE_ENV+=( -e "$name" )
  fi
done < <(env)

# --- Project memory key: same sanitization Claude Code uses (non-alnum -> '-') ---
PROJECT_KEY="$(printf '%s' "$REPO_PATH" | sed 's/[^a-zA-Z0-9]/-/g')"
HOST_PROJECT_DIR="${HOST_CLAUDE_DIR}/projects/${PROJECT_KEY}"
CTR_PROJECT_DIR="${CTR_CLAUDE_DIR}/projects/${PROJECT_KEY}"

# --- Build image every run (fast, layer-cached) ---
_echo "[sandbox] building image $IMAGE ..."
docker build -t "$IMAGE" "$SCRIPT_DIR"

# --- Assemble ~/.claude mounts (only what exists) ---
CLAUDE_MOUNTS=()
add_ro_mount() {  # $1 = host path, $2 = container path
  if [ -e "$1" ]; then
    CLAUDE_MOUNTS+=( -v "$1:$2:ro" )
    _echo "[sandbox] ro mount   : $1"
  fi
}
add_rw_mount() {  # $1 = host path, $2 = container path
  if [ -e "$1" ]; then
    CLAUDE_MOUNTS+=( -v "$1:$2" )
    _echo "[sandbox] rw mount   : $1"
  fi
}
# Per-project dir, read-WRITE: transcripts (*.jsonl), memory/, MEMORY.md. This
# shares history with the host, so `claude --resume` inside the sandbox lists
# sessions started with the host `claude`, and sandbox sessions persist back to
# the host. WARNING: the sandboxed Claude can now write/delete your real
# transcripts and memory. Created on the host first so the bind target exists.
[ -d "$HOST_PROJECT_DIR" ] || mkdir -p "$HOST_PROJECT_DIR"
CLAUDE_MOUNTS+=( -v "$HOST_PROJECT_DIR:$CTR_PROJECT_DIR" )
_echo "[sandbox] rw mount   : $HOST_PROJECT_DIR"
# Skills, global instructions, global settings. Read-WRITE, so the sandboxed
# Claude can edit skills/settings and add global instructions. WARNING: those
# edits land on the real host files, and settings.json/CLAUDE.md steer every
# later Claude run (sandboxed or not).
add_rw_mount "${HOST_CLAUDE_DIR}/skills"        "${CTR_CLAUDE_DIR}/skills"
add_rw_mount "${HOST_CLAUDE_DIR}/CLAUDE.md"     "${CTR_CLAUDE_DIR}/CLAUDE.md"
add_rw_mount "${HOST_CLAUDE_DIR}/settings.json" "${CTR_CLAUDE_DIR}/settings.json"
# Git identity (so commits carry your name/email). Read-only.
add_ro_mount "${HOME}/.gitconfig"               "/home/user/.gitconfig"
# SSH: mount the whole ~/.ssh read-only so push-over-ssh works (private key,
# config with the corporate ProxyCommand, and known_hosts all come along).
# WARNING: this exposes your real private key to the sandboxed Claude.
add_ro_mount "${HOME}/.ssh"                     "/home/user/.ssh"

_echo "[sandbox] folder       : $REPO_PATH  (mounted at same path)"
_echo "[sandbox] project key  : $PROJECT_KEY"
_echo "[sandbox] model        : $ANTHROPIC_MODEL"
_echo "[sandbox] command      : $*"
_echo "[sandbox] extra domains: ${ALLOWED_DOMAINS:-<none>}"

# --cap-add=NET_ADMIN + NET_RAW: required to program the in-container firewall.
# --security-opt no-new-privileges keeps that from being escalated further.
# Named volume 'claude-sandbox-config' persists Claude's login/settings; the
# read-only binds above overlay memory/skills/config on top of it.
exec docker run --rm -it \
  --hostname claude-sandbox \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --security-opt no-new-privileges \
  -e TERM="${TERM:-xterm-256color}" \
  -e COLORTERM="${COLORTERM:-truecolor}" \
  "${AUTH_ENV[@]}" \
  "${CLAUDE_CODE_ENV[@]}" \
  -e ANTHROPIC_MODEL="$ANTHROPIC_MODEL" \
  -e ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-}" \
  -e ALLOWED_PORTS="${ALLOWED_PORTS:-}" \
  -e NODE_TLS_REJECT_UNAUTHORIZED="${NODE_TLS_REJECT_UNAUTHORIZED:-1}" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$REPO_PATH:$REPO_PATH" \
  -v claude-sandbox-config:"$CTR_CLAUDE_DIR" \
  "${CLAUDE_MOUNTS[@]}" \
  -w "$REPO_PATH" \
  "$IMAGE" "$@"
