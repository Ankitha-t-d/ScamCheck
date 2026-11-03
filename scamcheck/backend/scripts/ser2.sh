#!/usr/bin/env bash
# ScamCheck backend installer for Amazon Linux 2023.
#
# Installs Node.js, the Express dependencies, and a systemd service that runs
# the existing backend on port 8000. Run this from the backend/scripts folder:
#
#   chmod +x ser2.sh
#   ./ser2.sh
#
# The script is idempotent: it can be re-run after a git pull.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SERVICE_NAME="scamcheck-api"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_DIR="/etc/scamcheck"
ENV_FILE="${ENV_DIR}/backend.env"
PORT="${PORT:-8000}"

APP_USER="${SUDO_USER:-$(id -un)}"
if [[ "$APP_USER" == "root" ]]; then
  APP_USER="ec2-user"
fi
APP_GROUP="$(id -gn "$APP_USER" 2>/dev/null || true)"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "\033[1;31m[FAIL]\033[0m ser2.sh failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

SUDO=""
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required when this script is not run as root."
  SUDO="sudo"
fi

run_as_app() {
  if [[ $EUID -eq 0 && "$APP_USER" != "root" ]]; then
    local home
    home="$(getent passwd "$APP_USER" | cut -d: -f6)"
    runuser -u "$APP_USER" -- env HOME="$home" "$@"
  else
    "$@"
  fi
}

get_public_ip() {
  local token ip
  token="$(curl -fsS --max-time 2 -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    ip="$(curl -fsS --max-time 2 \
      -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
  else
    ip="$(curl -fsS --max-time 2 \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

# ---------------------------------------------------------------------------
# 1. Detect the operating system
# ---------------------------------------------------------------------------
[[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot detect the operating system."
# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == "2023" ]]; then
  ok "Detected Amazon Linux 2023"
else
  warn "Detected ${PRETTY_NAME:-an unknown OS}. This script targets Amazon Linux 2023; continuing because dnf is available."
fi

command -v dnf >/dev/null 2>&1 || die "dnf is required. This script supports Amazon Linux 2023 (dnf-based)."
id -u "$APP_USER" >/dev/null 2>&1 || die "Service user '$APP_USER' does not exist."
[[ -n "$APP_GROUP" ]] || die "Could not determine the group for '$APP_USER'."
[[ -f "$BACKEND_DIR/server.js" ]] || die "server.js not found in $BACKEND_DIR. Run this script from backend/scripts/."
[[ -f "$BACKEND_DIR/package.json" ]] || die "package.json not found in $BACKEND_DIR."
[[ -f "$BACKEND_DIR/package-lock.json" ]] || warn "package-lock.json not found; npm install will be used instead of npm ci."

# ---------------------------------------------------------------------------
# 2. Install system packages and the Node.js runtime
# ---------------------------------------------------------------------------
log "Updating system packages (dnf update)"
$SUDO dnf update -y

log "Installing Node.js, npm, git, curl, and tar"
$SUDO dnf install -y git curl tar nodejs npm

NODE_BIN="$(command -v node || true)"
NPM_BIN="$(command -v npm || true)"
[[ -n "$NODE_BIN" ]] || die "Node.js was not installed correctly (node not found in PATH)."
[[ -n "$NPM_BIN" ]] || die "npm was not installed correctly (npm not found in PATH)."

NODE_VERSION="$("$NODE_BIN" --version)"
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
(( NODE_MAJOR >= 18 )) || die "Node.js 18 or newer is required; found $NODE_VERSION."
ok "Node.js $NODE_VERSION and npm $("$NPM_BIN" --version)"

# ---------------------------------------------------------------------------
# 3. Install the backend dependencies
# ---------------------------------------------------------------------------
cd "$BACKEND_DIR"

log "Installing backend dependencies in $BACKEND_DIR"
if [[ -f package-lock.json ]]; then
  if ! run_as_app "$NPM_BIN" ci --omit=dev --no-audit --no-fund; then
    warn "npm ci failed; falling back to npm install."
    run_as_app "$NPM_BIN" install --omit=dev --no-audit --no-fund
  fi
else
  run_as_app "$NPM_BIN" install --omit=dev --no-audit --no-fund
fi
ok "Backend dependencies installed"

log "Running the existing backend unit tests"
run_as_app "$NPM_BIN" test
ok "Backend unit tests passed"

# ---------------------------------------------------------------------------
# 4. Runtime configuration
# ---------------------------------------------------------------------------
log "Writing runtime configuration to $ENV_FILE"
$SUDO install -d -m 0755 "$ENV_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  $SUDO tee "$ENV_FILE" >/dev/null <<EOF
# ScamCheck backend runtime configuration.
# ser3.sh updates ALLOWED_ORIGIN with the exact frontend origin.
# Do not use "*" in production.
PORT=$PORT
NODE_ENV=production
ALLOWED_ORIGIN=http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000,http://127.0.0.1:5173
EOF
  $SUDO chmod 0640 "$ENV_FILE"
else
  if $SUDO grep -q '^PORT=' "$ENV_FILE"; then
    $SUDO sed -i "s|^PORT=.*|PORT=$PORT|" "$ENV_FILE"
  else
    printf 'PORT=%s\n' "$PORT" | $SUDO tee -a "$ENV_FILE" >/dev/null
  fi

  if ! $SUDO grep -q '^NODE_ENV=' "$ENV_FILE"; then
    printf 'NODE_ENV=production\n' | $SUDO tee -a "$ENV_FILE" >/dev/null
  fi

  if ! $SUDO grep -q '^ALLOWED_ORIGIN=' "$ENV_FILE"; then
    printf 'ALLOWED_ORIGIN=http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000,http://127.0.0.1:5173\n' \
      | $SUDO tee -a "$ENV_FILE" >/dev/null
  fi
fi

if $SUDO grep -qE '^ALLOWED_ORIGIN=.*\*' "$ENV_FILE"; then
  warn "ALLOWED_ORIGIN contains a wildcard. Run ser3.sh with the frontend URL to lock CORS down."
fi

# ---------------------------------------------------------------------------
# 5. Create the systemd service
# ---------------------------------------------------------------------------
log "Creating systemd service $SERVICE_NAME"
$SUDO tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=ScamCheck API (Node.js/Express)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$ENV_FILE
Environment=NODE_ENV=production
ExecStart=$NODE_BIN $BACKEND_DIR/server.js
Restart=always
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable "$SERVICE_NAME"
$SUDO systemctl restart "$SERVICE_NAME"

# ---------------------------------------------------------------------------
# 6. Verify the backend
# ---------------------------------------------------------------------------
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"
log "Waiting for the health endpoint at $HEALTH_URL"

healthy=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done

if [[ "$healthy" -ne 1 ]]; then
  $SUDO systemctl status --no-pager -l "$SERVICE_NAME" || true
  $SUDO journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  die "Backend did not become healthy. Check the service status and logs above."
fi

ok "Health check passed: $HEALTH_URL"
printf '     Response: %s\n' "$(curl -fsS "$HEALTH_URL" || true)"

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  log "Opening port $PORT in firewalld"
  $SUDO firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
  $SUDO firewall-cmd --reload >/dev/null
  ok "firewalld allows TCP $PORT"
fi

PUBLIC_IP="$(get_public_ip)"
printf '\n\033[1;32mBackend deployment complete.\033[0m\n'
cat <<EOF
  Service:    $SERVICE_NAME (systemd, enabled at boot)
  Port:       $PORT
  Health:     $HEALTH_URL
  Public URL: ${PUBLIC_IP:+http://$PUBLIC_IP:$PORT}
  Logs:       sudo journalctl -u $SERVICE_NAME -f
  Restart:    sudo systemctl restart $SERVICE_NAME
  Env file:   $ENV_FILE
  API docs:   No Swagger/OpenAPI endpoint exists. Use /api/health and the
              POST /api/analyze/message and POST /api/analyze/url endpoints.

Next steps:
  1. In AWS, allow TCP $PORT on app_server_sg from app_client_sg (see README).
  2. On the frontend instance, run cli3.sh with this backend URL.
  3. On this instance, run ser3.sh with the frontend URL to lock down CORS.
EOF
