#!/usr/bin/env bash
# Connect the deployed ScamCheck frontend to the backend.
#
# Usage:
#   ./cli3.sh http://<BACKEND_PRIVATE_IP>:8000
#   ./cli3.sh --direct http://<BACKEND_PUBLIC_IP>:8000
#
# Default (proxy) mode:
#   Browser -> Apache on the frontend :80 -> backend private IP :8000
#   The backend security group can stay restricted to app_client_sg, because
#   AWS security-group referencing matches the frontend's private IP.
#   Both instances must be in the same VPC. Use `hostname -I` on the backend.
#
# Direct mode:
#   Browser -> backend public IP :8000
#   The backend security group must allow the browser's IP address (normally
#   0.0.0.0/0). This is simpler but exposes the API to the internet.
#
# The script changes only the deployed runtime configuration. It does not
# hardcode the backend IP into the repository's application source.
set -Eeuo pipefail
IFS=$'\n\t'

DOCROOT="/var/www/html"
PROXY_CONF="/etc/httpd/conf.d/scamcheck-api-proxy.conf"
MODE="proxy"
BACKEND_URL=""
TMP_FILE=""

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
trap '[[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE"' EXIT
trap 'printf "\033[1;31m[FAIL]\033[0m cli3.sh failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

usage() {
  cat <<EOF
Usage: ./cli3.sh [--proxy|--direct] <backend-origin>

  --proxy   (default) Apache forwards /api to the backend private IP. The
            backend security group can remain limited to app_client_sg.
            Both instances must be in the same VPC.
  --direct  The browser calls the backend public IP directly. The backend
            security group must allow the browser IPs (for example 0.0.0.0/0).

Examples:
  ./cli3.sh http://10.0.1.25:8000              # proxy, private IP
  ./cli3.sh --direct http://54.123.45.67:8000  # direct, public IP
EOF
}

for arg in "$@"; do
  case "$arg" in
    --proxy)  MODE="proxy" ;;
    --direct) MODE="direct" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $arg" ;;
    *)
      [[ -z "$BACKEND_URL" ]] || die "Only one backend URL can be supplied."
      BACKEND_URL="$arg"
      ;;
  esac
done

if [[ -z "$BACKEND_URL" ]]; then
  usage
  exit 1
fi

BACKEND_URL="${BACKEND_URL%/}"
BACKEND_URL="${BACKEND_URL,,}"

if [[ ! "$BACKEND_URL" =~ ^(https?)://([A-Za-z0-9.-]+)(:([0-9]{1,5}))?$ ]]; then
  die "Invalid backend URL: '$BACKEND_URL'. Use http://HOST:PORT with no path."
fi

SCHEME="${BASH_REMATCH[1]}"
HOST="${BASH_REMATCH[2]}"
BACKEND_PORT="${BASH_REMATCH[4]:-}"
if [[ -n "$BACKEND_PORT" ]]; then
  (( 10#$BACKEND_PORT >= 1 && 10#$BACKEND_PORT <= 65535 )) \
    || die "Invalid port '$BACKEND_PORT' in '$BACKEND_URL'."
fi
BACKEND_URL="${SCHEME}://${HOST}${BACKEND_PORT:+:$BACKEND_PORT}"

SUDO=""
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required when this script is not run as root."
  SUDO="sudo"
fi

command -v httpd >/dev/null 2>&1 || die "httpd is not installed. Run frontend/scripts/cli2.sh first."
command -v curl >/dev/null 2>&1 || die "curl is not installed. Run frontend/scripts/cli2.sh first."
[[ -f "$DOCROOT/index.html" ]] || die "$DOCROOT/index.html not found. Run frontend/scripts/cli2.sh first."
[[ -f "$DOCROOT/config.js" ]] || die "$DOCROOT/config.js not found. Run frontend/scripts/cli2.sh first."

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

ensure_module() {
  local name="$1" file="$2"
  if ! httpd -M 2>/dev/null | grep -q "${name}"; then
    log "Enabling Apache module ${name}"
    printf 'LoadModule %s %s\n' "$name" "$file" \
      | $SUDO tee "/etc/httpd/conf.modules.d/99-scamcheck-${name}.conf" >/dev/null
  fi
}

write_config_js() {
  local api_base="$1" mode="$2"
  TMP_FILE="$(mktemp)"
  cat > "$TMP_FILE" <<EOF
// Managed by frontend/scripts/cli3.sh (${mode} mode).
// The repository copy frontend/config.js is intentionally left unchanged.
window.APP_CONFIG = { API_BASE: "${api_base}" };
EOF
  $SUDO install -m 0644 -o root -g root "$TMP_FILE" "$DOCROOT/config.js"
  rm -f "$TMP_FILE"
  TMP_FILE=""
  if command -v restorecon >/dev/null 2>&1; then
    $SUDO restorecon "$DOCROOT/config.js" >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# 1. Verify that the backend is reachable from this frontend instance
# ---------------------------------------------------------------------------
HEALTH_URL="${BACKEND_URL}/api/health"
log "Checking backend reachability from the frontend instance: $HEALTH_URL"
if ! curl -fsS --connect-timeout 5 --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
  cat >&2 <<EOF

Cannot reach the backend at $HEALTH_URL.

Check all of the following:
  - The backend systemd service is running: sudo systemctl status scamcheck-api
  - The backend listens on 0.0.0.0:8000: sudo ss -ltnp | grep ':8000'
  - app_server_sg allows TCP 8000 from app_client_sg (proxy mode) or from the
    browser/client IPs (direct mode).
  - Proxy mode uses the backend PRIVATE IP (from 'hostname -I' on app_server),
    and both instances are in the same VPC. Direct mode uses the public IP.
  - The backend IP is correct and the instance is running.
EOF
  die "Backend health check failed."
fi
ok "Backend health endpoint is reachable"

# ---------------------------------------------------------------------------
# 2. Configure Apache and the runtime config.js
# ---------------------------------------------------------------------------
if [[ "$MODE" == "proxy" ]]; then
  log "Configuring Apache reverse proxy (browser -> Apache -> backend)"

  ensure_module proxy_module modules/mod_proxy.so
  ensure_module proxy_http_module modules/mod_proxy_http.so
  ensure_module headers_module modules/mod_headers.so

  # SELinux blocks httpd from opening outbound network connections by default.
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    if command -v setsebool >/dev/null 2>&1; then
      log "Allowing httpd outbound connections (SELinux)"
      $SUDO setsebool -P httpd_can_network_connect 1
    else
      warn "SELinux is enforcing but setsebool is missing; if the proxy returns 503, install policycoreutils and run: sudo setsebool -P httpd_can_network_connect 1"
    fi
  fi

  $SUDO tee "$PROXY_CONF" >/dev/null <<EOF
# Managed by frontend/scripts/cli3.sh (proxy mode).
# Browser -> Apache :80 -> ${BACKEND_URL}
ProxyRequests Off
ProxyPreserveHost Off
ProxyTimeout 30
ProxyPass        /api  ${BACKEND_URL}/api  timeout=30
ProxyPassReverse /api  ${BACKEND_URL}/api
RequestHeader set X-Forwarded-Proto "http"
EOF

  # Same-origin browser requests: app.js calls /api/... on the frontend.
  write_config_js "" "proxy"
  ok "Proxy configuration written to $PROXY_CONF"

else
  log "Configuring direct browser-to-backend mode"
  if [[ -f "$PROXY_CONF" ]]; then
    $SUDO rm -f "$PROXY_CONF"
    ok "Removed the previous proxy configuration"
  fi
  write_config_js "$BACKEND_URL" "direct"
  ok "Runtime config.js points at $BACKEND_URL"
fi

# ---------------------------------------------------------------------------
# 3. Reload Apache and verify the deployed site
# ---------------------------------------------------------------------------
$SUDO httpd -t
if ! $SUDO systemctl reload httpd; then
  warn "Apache reload failed; restarting httpd."
  $SUDO systemctl restart httpd
fi

healthy=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 "http://127.0.0.1/" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done

if [[ "$healthy" -ne 1 ]]; then
  $SUDO systemctl status --no-pager -l httpd || true
  $SUDO journalctl -u httpd -n 80 --no-pager || true
  die "Apache did not serve the frontend after the configuration change."
fi

curl -fsS --max-time 5 "http://127.0.0.1/" | grep -q 'ScamCheck' \
  || die "The frontend does not contain the ScamCheck title."
curl -fsS --max-time 5 "http://127.0.0.1/config.js" | grep -q 'APP_CONFIG' \
  || die "The deployed config.js is not valid."

if [[ "$MODE" == "proxy" ]]; then
  log "Testing the full browser path through Apache"
  if ! curl -fsS --max-time 10 "http://127.0.0.1/api/health" | grep -q '"status":"ok"'; then
    $SUDO tail -n 50 /var/log/httpd/scamcheck-error.log 2>/dev/null || true
    $SUDO journalctl -u httpd -n 50 --no-pager || true
    die "Apache could not proxy /api/health to the backend."
  fi
  ok "Apache proxy health check passed"

  if ! curl -fsS --max-time 10 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"input":"https://www.hdfcbank.com/personal"}' \
    "http://127.0.0.1/api/analyze/url" | grep -q '"type":"url"'; then
    die "The proxy reached the backend, but the analyze endpoint did not return the expected JSON."
  fi
  ok "Full proxy path to POST /api/analyze/url works"
else
  log "Testing the backend analyze endpoint from this instance"
  if ! curl -fsS --max-time 10 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"input":"https://www.hdfcbank.com/personal"}' \
    "${BACKEND_URL}/api/analyze/url" | grep -q '"type":"url"'; then
    die "The backend analyze endpoint did not return the expected JSON."
  fi
  ok "Backend analyze endpoint works from the frontend instance"
fi

FRONTEND_PUBLIC_IP="$(get_public_ip)"
FRONTEND_URL="${FRONTEND_PUBLIC_IP:+http://$FRONTEND_PUBLIC_IP}"

if [[ "$MODE" == "proxy" ]]; then
  PROXY_DISPLAY="$PROXY_CONF"
else
  PROXY_DISPLAY="not used (direct mode)"
fi

printf '\n\033[1;32mFrontend/backend connection configured.\033[0m\n'
cat <<EOF
  Mode:          $MODE
  Backend URL:   $BACKEND_URL
  Frontend URL:  ${FRONTEND_URL:-http://<frontend-public-ip>}
  Runtime file:  $DOCROOT/config.js
  Proxy file:    $PROXY_DISPLAY

EOF

if [[ "$MODE" == "proxy" ]]; then
  cat <<EOF
Proxy mode is active. The browser calls the frontend on port 80, and Apache
forwards /api to the backend private IP. Keep app_server_sg inbound TCP 8000
restricted to app_client_sg; do not open 8000 to the world for this mode.
If you passed the backend public IP, switch to the private IP (hostname -I on
app_server) because the app_client_sg reference matches private addresses.
EOF
else
  cat <<EOF
WARNING: Direct mode makes the user's browser connect to $BACKEND_URL.

The lab rule "TCP 8000 from app_client_sg" is NOT enough for direct mode,
because the request comes from the user's browser, not from the frontend
instance. Add an inbound rule for TCP 8000 from 0.0.0.0/0 (or the specific
client IPs) to app_server_sg. CORS still restricts which web origins can read
the response, but the API itself is reachable by anyone who can connect.
EOF
fi

cat <<EOF

Next step (on the backend instance):
  cd ~/ScamCheck/scamcheck/backend/scripts
  ./ser3.sh ${FRONTEND_URL:-http://<frontend-public-ip>}

Then open ${FRONTEND_URL:-http://<frontend-public-ip>} in a browser and test
the message, link, and password tabs. If you changed config.js before, use a
hard refresh (Ctrl+F5) because browsers cache JavaScript.
EOF
