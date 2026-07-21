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

# --- Egress firewall (needs root) ---
if [ "${SANDBOX_FIREWALL:-1}" = "1" ]; then
  /usr/local/bin/init-firewall.sh
else
  _echo "[entrypoint] SANDBOX_FIREWALL=0 -> skipping firewall (network is OPEN)"
fi

# --- Align 'user' user to host UID/GID if provided ---
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
CUR_UID="$(id -u user)"
CUR_GID="$(id -g user)"

if [ "$HOST_GID" != "$CUR_GID" ]; then
  groupmod -g "$HOST_GID" -o user 2>/dev/null || true
fi
if [ "$HOST_UID" != "$CUR_UID" ]; then
  usermod -u "$HOST_UID" -o user 2>/dev/null || true
fi
chown "$HOST_UID:$HOST_GID" /home/user 2>/dev/null || true
chown -R "$HOST_UID:$HOST_GID" /home/user/.claude 2>/dev/null || true

_echo "[entrypoint] workspace: $(pwd)"
_echo "[entrypoint] user     : user ($HOST_UID:$HOST_GID)"
_echo "[entrypoint] launch claude..."
echo

# Drop root and run as the sandbox user. gosu dropping privileges does not
# require new privileges, so it is compatible with --security-opt
# no-new-privileges.
exec gosu user "$@"
