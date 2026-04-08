#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap gogcli end-to-end: credentials → keyring → token server → sandbox.
#
# Usage:
#   GOG_KEYRING_PASSWORD=<pw> ./gogcli-skill/bootstrap.sh \
#     --credentials <file> \
#     --email <gmail-address> \
#     --sandbox <sandbox-name>
#
# Required:
#   --credentials   Path to a GCP Console OAuth client secret JSON file
#                   (the file downloaded from console.cloud.google.com).
#                   Passed directly to `gog auth credentials set`.
#   --email         Gmail address to authorise.
#   --sandbox       OpenShell sandbox name to push gogcli into.
#
# Optional:
#   --gog           Path to the gog binary (auto-detected if omitted).
#   --port          Token server port (default: 9100).
#
# Environment:
#   GOG_KEYRING_PASSWORD   Encrypts the local token file. Required.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse flags ───────────────────────────────────────────────────────────────

CREDS_FILE=""
EMAIL=""
SANDBOX=""
GOG_BIN_OVERRIDE=""
TOKEN_PORT="${GOG_TOKEN_SERVER_PORT:-9100}"

usage() {
  echo "Usage: GOG_KEYRING_PASSWORD=<pw> $0 \\"
  echo "         --credentials <file> --email <addr> --sandbox <name>"
  echo ""
  echo "  --credentials  GCP Console OAuth client secret JSON"
  echo "  --email        Gmail address"
  echo "  --sandbox      OpenShell sandbox name"
  echo "  --gog          Path to gog binary (auto-detected if omitted)"
  echo "  --port         Token server port (default: 9100)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --credentials) CREDS_FILE="$2"; shift 2 ;;
    --email)       EMAIL="$2";      shift 2 ;;
    --sandbox)     SANDBOX="$2";    shift 2 ;;
    --gog)         GOG_BIN_OVERRIDE="$2"; shift 2 ;;
    --port)        TOKEN_PORT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$CREDS_FILE" ]]  && echo "Error: --credentials is required." && usage
[[ -z "$EMAIL" ]]       && echo "Error: --email is required."       && usage
[[ -z "$SANDBOX" ]]     && echo "Error: --sandbox is required."     && usage

if [[ ! -f "$CREDS_FILE" ]]; then
  echo "Error: credentials file not found: $CREDS_FILE"
  exit 1
fi

if [[ -z "${GOG_KEYRING_PASSWORD:-}" ]]; then
  echo "Error: GOG_KEYRING_PASSWORD is required."
  echo "  export GOG_KEYRING_PASSWORD=<choose-any-password>"
  exit 1
fi

# ── Locate gog binary ─────────────────────────────────────────────────────────

GOG_BIN="$GOG_BIN_OVERRIDE"
if [[ -z "$GOG_BIN" ]]; then
  for candidate in \
    "$(command -v gog 2>/dev/null || true)" \
    "$HOME/demo/gogcli/bin/gog" \
    "$HOME/gogcli/bin/gog" \
    "$(dirname "$(dirname "$SKILL_DIR")")/gogcli/bin/gog"; do
    if [[ -x "$candidate" ]]; then
      GOG_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "$GOG_BIN" ]]; then
  echo "Error: gog binary not found. Build it first:"
  echo "  cd ~/demo/gogcli && make"
  echo "Or pass --gog /path/to/bin/gog"
  exit 1
fi

echo "Using gog binary: $GOG_BIN"
echo "Account: $EMAIL"

GOG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gogcli"

GOG_ENV=(
  env
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
  GOG_KEYRING_BACKEND=file
  GOG_KEYRING_PASSWORD="$GOG_KEYRING_PASSWORD"
)

# ── Store OAuth client credentials ────────────────────────────────────────────

echo "Storing OAuth client credentials..."
"${GOG_ENV[@]}" "$GOG_BIN" auth credentials set "$CREDS_FILE"

# ── Authorise account (OAuth consent flow) ────────────────────────────────────

echo ""
echo "Authorising $EMAIL — a browser window will open. Sign in and grant access."
echo ""
"${GOG_ENV[@]}" "$GOG_BIN" auth add "$EMAIL" \
  --services gmail,calendar,drive \
  --manual

# ── Verify keyring ────────────────────────────────────────────────────────────

echo "Verifying keyring..."
"${GOG_ENV[@]}" "$GOG_BIN" auth list

# ── Start (or restart) token server ──────────────────────────────────────────

TOKEN_SERVER_PID_FILE="$GOG_CONFIG_DIR/token-server.pid"

if [[ -f "$TOKEN_SERVER_PID_FILE" ]]; then
  OLD_PID=$(cat "$TOKEN_SERVER_PID_FILE" 2>/dev/null || true)
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Stopping existing token server (pid $OLD_PID)..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$TOKEN_SERVER_PID_FILE"
fi

echo "Starting token server on port $TOKEN_PORT..."
"${GOG_ENV[@]}" nohup python3 "$SKILL_DIR/gog-token-server.py" \
  "$EMAIL" \
  --port "$TOKEN_PORT" \
  --gog "$GOG_BIN" \
  > "$GOG_CONFIG_DIR/token-server.log" 2>&1 &
echo $! > "$TOKEN_SERVER_PID_FILE"

retries=10
while (( retries-- > 0 )); do
  if curl -sf "http://127.0.0.1:${TOKEN_PORT}/health" >/dev/null 2>&1; then
    echo "Token server ready (pid $(cat "$TOKEN_SERVER_PID_FILE"))."
    break
  fi
  sleep 1
done
if (( retries < 0 )); then
  echo "Warning: token server did not respond within 10s; check $GOG_CONFIG_DIR/token-server.log"
fi

# ── Push gogcli into sandbox ──────────────────────────────────────────────────

HOST_IP="$(hostname -I | awk '{print $1}')"
if [[ -z "$HOST_IP" ]]; then
  echo "Error: could not determine host IP address."
  exit 1
fi
echo "Host IP: $HOST_IP"

UPLOAD_DIR=$(mktemp -d /tmp/gogcli-upload-XXXXXX)
trap 'rm -rf "$UPLOAD_DIR"' EXIT

cp -r "$GOG_CONFIG_DIR/." "$UPLOAD_DIR/"
rm -rf "$UPLOAD_DIR/keyring" "$UPLOAD_DIR/gog" "$UPLOAD_DIR/gog-bin" "$UPLOAD_DIR/env.sh" \
       "$UPLOAD_DIR/token-server.pid" "$UPLOAD_DIR/token-server.log"

cp "$GOG_BIN" "$UPLOAD_DIR/gog-bin"
chmod +x "$UPLOAD_DIR/gog-bin"

cat > "$UPLOAD_DIR/gog" <<WRAPEOF
#!/bin/bash
# gogcli wrapper — fetches a fresh access token from the host token server.
_GOG_TOKEN="\$(curl -sf 'http://${HOST_IP}:${TOKEN_PORT}/token')" || {
  echo "gogcli: could not reach token server at ${HOST_IP}:${TOKEN_PORT}" >&2
  exit 1
}
export XDG_CONFIG_HOME=/sandbox/.config
exec env GOG_ACCESS_TOKEN="\$_GOG_TOKEN" /sandbox/.config/gogcli/gog-bin "\$@"
WRAPEOF
chmod +x "$UPLOAD_DIR/gog"

echo "Uploading gogcli config + wrapper into sandbox '$SANDBOX'..."
openshell sandbox upload "$SANDBOX" "$UPLOAD_DIR" /sandbox/.config/gogcli

# ── Apply network policy ──────────────────────────────────────────────────────

echo "Applying network policy..."

CURRENT=$(openshell policy get --full "$SANDBOX" 2>/dev/null | awk '/^---/{found=1; next} found{print}')

GOOGLE_BLOCKS=$(awk '
  /^  google_gmail:/ || /^  google_calendar:/ || /^  google_drive:/ { found=1 }
  /^  [a-z]/ && found && !/^  google_gmail:/ && !/^  google_calendar:/ && !/^  google_drive:/ { found=0 }
  found { print }
' "$SKILL_DIR/policy.yaml")

TOKEN_SERVER_BLOCK=$(cat <<TSEOF
  google_token_server:
    name: google_token_server
    endpoints:
      - host: ${HOST_IP}
        port: ${TOKEN_PORT}
        protocol: rest
        enforcement: enforce
        tls: passthrough
        rules:
          - allow: { method: GET, path: "/token" }
          - allow: { method: GET, path: "/health" }
    binaries:
      - { path: /usr/bin/curl }
      - { path: /usr/bin/curl* }
TSEOF
)

POLICY_FILE=$(mktemp /tmp/gogcli-policy-XXXXXX.yaml)
echo "${CURRENT:-version: 1}" > "$POLICY_FILE"
if ! grep -q "^network_policies:" "$POLICY_FILE"; then
  echo "" >> "$POLICY_FILE"
  echo "network_policies:" >> "$POLICY_FILE"
fi
printf '%s\n' "$GOOGLE_BLOCKS" >> "$POLICY_FILE"
printf '%s\n' "$TOKEN_SERVER_BLOCK" >> "$POLICY_FILE"
openshell policy set --policy "$POLICY_FILE" --wait "$SANDBOX"
rm -f "$POLICY_FILE"

# ── Upload SKILL.md ───────────────────────────────────────────────────────────

echo "Uploading SKILL.md..."
openshell sandbox upload "$SANDBOX" \
  "$SKILL_DIR/SKILL.md" \
  /sandbox/.openclaw/skills/gogcli/

# ── Restart OpenClaw gateway ──────────────────────────────────────────────────

echo "Restarting OpenClaw gateway..."
openclaw gateway stop 2>/dev/null || true
sleep 2
nohup openclaw gateway run \
  --allow-unconfigured --dev \
  --bind loopback --port 18789 \
  --token hello \
  > /tmp/gateway.log 2>&1 &

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "gogcli ready in sandbox '$SANDBOX'."
echo "  Token server: http://${HOST_IP}:${TOKEN_PORT} (pid $(cat "$TOKEN_SERVER_PID_FILE" 2>/dev/null || echo '?'))"
echo "  Log: $GOG_CONFIG_DIR/token-server.log"
echo ""
echo "Try it:"
echo "  \"Search my Gmail for unread messages and summarize them.\""
echo "  \"Check my calendar for meetings tomorrow.\""
echo "  \"List recent files in my Google Drive.\""
