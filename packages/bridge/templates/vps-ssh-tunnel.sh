#!/usr/bin/env bash
set -euo pipefail

# Cross-platform SSH reverse tunnel helper for Nonlocal Bridge
# Configure via environment variables; no host-specific network interfaces or local-only markers.

RELAY_HOST="${NONLOCAL_RELAY_HOST:-<YOUR_VPS_HOST>}"
RELAY_USER="${NONLOCAL_RELAY_USER:-<YOUR_SSH_USER>}"
RELAY_PORT="${NONLOCAL_RELAY_PORT:-22}"
LOCAL_PORT="${NONLOCAL_LOCAL_PORT:-{{PORT}}}"
REMOTE_BIND_PORT="${NONLOCAL_REMOTE_PORT:-18765}"
SSH_KEY="${NONLOCAL_SSH_KEY:-}"

SSH_ARGS=(
  -N
  -T
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -p "${RELAY_PORT}"
  -R "127.0.0.1:${REMOTE_BIND_PORT}:127.0.0.1:${LOCAL_PORT}"
)

if [[ -n "${SSH_KEY}" ]]; then
  SSH_ARGS+=(-i "${SSH_KEY}")
fi

echo "Starting reverse SSH tunnel 127.0.0.1:${REMOTE_BIND_PORT} -> 127.0.0.1:${LOCAL_PORT} via ${RELAY_USER}@${RELAY_HOST}:${RELAY_PORT}"
exec ssh "${SSH_ARGS[@]}" "${RELAY_USER}@${RELAY_HOST}"
