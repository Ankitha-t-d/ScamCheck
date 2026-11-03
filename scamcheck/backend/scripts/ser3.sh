#!/usr/bin/env bash
# Configure ScamCheck backend CORS for one frontend origin.
#
# Usage:
#   ./ser3.sh http://<FRONTEND_PUBLIC_IP>
#   ./ser3.sh https://scamcheck.example.com
#
# The script updates ALLOWED_ORIGIN in /etc/scamcheck/backend.env, keeps the
# localhost origins used for local development, restarts the systemd service,
# and verifies the CORS response. It never writes a wildcard origin.
set -Eeuo pipefail
IFS=$'\n\t'

SERVICE_NAME="scamcheck-api"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_DIR="/etc/scamcheck"
ENV_FILE="${ENV_DIR}/backend.env"
PORT="${PORT:-8000}"
TMP_FILE=""

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
trap '[[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE"' EXIT
trap 'printf "\033[1;31m[FAIL]\033[0m ser3.sh failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

usage() {
  cat <<EOF
Usage: ./ser3.sh <frontend-origin>

Examples:
  ./ser3.sh http://54.123.45.67
  ./ser3.sh https://scamcheck.example.com

The argument must be an origin only: scheme, host, and optional port.
Do not include a path, query string, or wildcard.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

FRONTEND_URL="$1"
FRONTEND_URL="${FRONTEND_URL%/}"
FRONTEND_URL="${FRONTEND_URL,,}"

if [[ ! "$FRONTEND_URL" =~ ^(https?)://([A-Za-z0-9.-]+)(:([0-9]{1,5}))?$ ]]; then
  die "Invalid frontend origin: '$1'. Use http://HOST or https://HOST[:PORT], with no path."
fi

SCHEME="${BASH_REMATCH[1]}"
HOST="${BASH_REMATCH[2]}"
FRONTEND_PORT="${BASH_REMATCH[4]:-}"
if [[ -n "$FRONTEND_PORT" ]]; then
  (( 10#$FRONTEND_PORT >= 1 && 10#$FRONTEND_PORT <= 65535 )) \
    || die "Invalid port '$FRONTEND_PORT' in '$1'."
fi
FRONTEND_URL="${SCHEME}://${HOST}${FRONTEND_PORT:+:$FRONTEND_PORT}"

SUDO=""
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required when this script is not run as root."
  SUDO="sudo"
fi

[[ -f "$SERVICE_FILE" ]] || die "systemd service $SERVICE_NAME not found. Run backend/scripts/ser2.sh first."
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Run backend/scripts/ser2.sh first."
command -v curl >/dev/null 2>&1 || die "curl is required. Run backend/scripts/ser2.sh first."

# The systemd unit reads PORT from the env file, so use that value for the
# health checks even if the caller's shell has a different PORT.
ENV_PORT="$($SUDO grep -E '^PORT=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"
if [[ -n "$ENV_PORT" ]]; then
  PORT="$ENV_PORT"
fi

# Keep local development origins. The deployed frontend origin is placed first.
LOCAL_ORIGINS=(
  "http://localhost:3000"
  "http://localhost:5173"
  "http://localhost:8080"
  "http://127.0.0.1:3000"
  "http://127.0.0.1:5173"
  "http://127.0.0.1:8080"
)
ALLOWED_ORIGIN="$FRONTEND_URL"
for origin in "${LOCAL_ORIGINS[@]}"; do
  [[ "$origin" == "$FRONTEND_URL" ]] || ALLOWED_ORIGIN="${ALLOWED_ORIGIN},${origin}"
done

log "Updating ALLOWED_ORIGIN in $ENV_FILE"
TMP_FILE="$(mktemp)"
$SUDO grep -v '^ALLOWED_ORIGIN=' "$ENV_FILE" > "$TMP_FILE" || true
printf 'ALLOWED_ORIGIN=%s\n' "$ALLOWED_ORIGIN" >> "$TMP_FILE"
$SUDO install -m 0640 -o root -g root "$TMP_FILE" "$ENV_FILE"
rm -f "$TMP_FILE"
TMP_FILE=""
ok "ALLOWED_ORIGIN=$ALLOWED_ORIGIN"

log "Restarting $SERVICE_NAME"
$SUDO systemctl restart "$SERVICE_NAME"

HEALTH_URL="http://127.0.0.1:${PORT}/api/health"
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
  die "Backend did not become healthy after the CORS update."
fi
ok "Backend is healthy: $HEALTH_URL"

log "Verifying the CORS response for $FRONTEND_URL"
SIMPLE_HEADERS="$(curl -sS -D - -o /dev/null \
  -H "Origin: $FRONTEND_URL" \
  "$HEALTH_URL")"

if ! grep -Fqi "access-control-allow-origin: $FRONTEND_URL" <<< "$SIMPLE_HEADERS"; then
  printf '%s\n' "$SIMPLE_HEADERS" >&2
  die "The backend did not return Access-Control-Allow-Origin for $FRONTEND_URL. Check $ENV_FILE and the service logs."
fi
ok "Simple request CORS header is correct"

PREFLIGHT_HEADERS="$(curl -sS -D - -o /dev/null -X OPTIONS \
  -H "Origin: $FRONTEND_URL" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" \
  "http://127.0.0.1:${PORT}/api/analyze/message")"

if ! grep -Fqi "access-control-allow-origin: $FRONTEND_URL" <<< "$PREFLIGHT_HEADERS"; then
  printf '%s\n' "$PREFLIGHT_HEADERS" >&2
  die "The backend did not return Access-Control-Allow-Origin on the preflight request."
fi
ok "Preflight request CORS header is correct"

printf '\n\033[1;32mCORS configuration complete.\033[0m\n'
cat <<EOF
  Frontend origin: $FRONTEND_URL
  Allowed origins: $ALLOWED_ORIGIN
  Service:         $SERVICE_NAME (restarted and healthy)
  Health:          $HEALTH_URL
  Logs:            sudo journalctl -u $SERVICE_NAME -f

Notes:
  - Localhost origins are kept for local development.
  - Re-running this script replaces the production frontend origin with the
    one supplied here; it does not accumulate old public IP addresses.
  - The frontend must use exactly this origin in the browser. If you open the
    site by a different hostname or port, run this script again with it.
EOF
