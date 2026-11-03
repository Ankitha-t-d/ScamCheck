#!/usr/bin/env bash
# ScamCheck frontend installer for Amazon Linux 2023.
#
# ScamCheck's frontend is plain HTML/CSS/JavaScript: there is no framework,
# no package.json, and no production build step. This script installs Apache,
# copies the static files into /var/www/html, and enables httpd on port 80.
#
# Run from frontend/scripts:
#   chmod +x cli2.sh
#   ./cli2.sh
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DOCROOT="/var/www/html"
HTTPD_CONF="/etc/httpd/conf.d/scamcheck.conf"
TMP_DIR=""

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
trap '[[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"' EXIT
trap 'printf "\033[1;31m[FAIL]\033[0m cli2.sh failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

SUDO=""
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required when this script is not run as root."
  SUDO="sudo"
fi

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
[[ -f "$FRONTEND_DIR/index.html" ]] || die "index.html not found in $FRONTEND_DIR. Run this script from frontend/scripts/."
[[ -f "$FRONTEND_DIR/app.js" ]] || die "app.js not found in $FRONTEND_DIR."
[[ -f "$FRONTEND_DIR/config.js" ]] || die "config.js not found in $FRONTEND_DIR."
[[ -f "$FRONTEND_DIR/style.css" ]] || die "style.css not found in $FRONTEND_DIR."

# ---------------------------------------------------------------------------
# 2. Install Apache
# ---------------------------------------------------------------------------
log "Updating system packages (dnf update)"
$SUDO dnf update -y

log "Installing Apache HTTP Server (httpd), git, curl, and tar"
$SUDO dnf install -y git curl tar httpd

command -v httpd >/dev/null 2>&1 || die "httpd was not installed correctly."

# The Header directives below need mod_headers. Amazon Linux loads it by
# default, but make sure before writing the configuration.
if ! httpd -M 2>/dev/null | grep -q 'headers_module'; then
  log "Enabling mod_headers"
  printf 'LoadModule headers_module modules/mod_headers.so\n' \
    | $SUDO tee /etc/httpd/conf.modules.d/99-scamcheck-headers.conf >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. Deploy the static frontend
# ---------------------------------------------------------------------------
log "Deploying the static frontend to $DOCROOT"
$SUDO install -d -m 0755 "$DOCROOT"

# The document root is dedicated to this site. Clear stale files so removed
# assets do not keep being served, but keep the directory itself.
$SUDO find "$DOCROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

TMP_DIR="$(mktemp -d)"
tar -C "$FRONTEND_DIR" \
  --exclude='./scripts' \
  --exclude='./scripts/*' \
  --exclude='./node_modules' \
  --exclude='./node_modules/*' \
  --exclude='./.git' \
  --exclude='./.git/*' \
  --exclude='./.env' \
  -cf "$TMP_DIR/frontend.tar" .
$SUDO tar -C "$DOCROOT" -xf "$TMP_DIR/frontend.tar"
rm -rf "$TMP_DIR"
TMP_DIR=""

# Apache runs as the apache user and only needs read access. SELinux needs the
# httpd_sys_content_t label, which restorecon restores from the policy.
$SUDO chown -R root:root "$DOCROOT"
$SUDO find "$DOCROOT" -type d -exec chmod 0755 {} +
$SUDO find "$DOCROOT" -type f -exec chmod 0644 {} +
if command -v restorecon >/dev/null 2>&1; then
  $SUDO restorecon -R "$DOCROOT" >/dev/null 2>&1 || true
fi
ok "Frontend files deployed"

# ---------------------------------------------------------------------------
# 4. Configure Apache
# ---------------------------------------------------------------------------
log "Writing Apache configuration to $HTTPD_CONF"
$SUDO tee "$HTTPD_CONF" >/dev/null <<'EOF'
# Managed by frontend/scripts/cli2.sh
# ScamCheck is a single static page. There are no client-side routes, so no
# SPA rewrite is required; real 404s for missing assets stay real 404s.
DirectoryIndex index.html

<Directory "/var/www/html">
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# cli3.sh changes the runtime API address. Never let a browser cache it.
<Files "config.js">
    Header set Cache-Control "no-store, no-cache, must-revalidate"
    Header set Pragma "no-cache"
</Files>

<Files "index.html">
    Header set Cache-Control "no-cache"
</Files>
EOF

$SUDO httpd -t

log "Enabling and starting httpd"
$SUDO systemctl enable httpd
$SUDO systemctl restart httpd

# ---------------------------------------------------------------------------
# 5. Verify the frontend
# ---------------------------------------------------------------------------
log "Testing the site through localhost"
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
  die "Apache did not serve the site on port 80."
fi

curl -fsS --max-time 5 "http://127.0.0.1/" | grep -q 'ScamCheck' \
  || die "index.html was served but does not contain the ScamCheck title."

for asset in style.css app.js config.js; do
  curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1/${asset}" \
    || die "Apache is not serving /${asset}."
done

ok "Frontend and static assets are served correctly"

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  log "Opening HTTP in firewalld"
  $SUDO firewall-cmd --permanent --add-service=http >/dev/null
  $SUDO firewall-cmd --reload >/dev/null
  ok "firewalld allows HTTP"
fi

PUBLIC_IP="$(get_public_ip)"
printf '\n\033[1;32mFrontend deployment complete.\033[0m\n'
cat <<EOF
  Apache:        httpd (systemd, enabled at boot)
  Document root: $DOCROOT
  Local URL:     http://127.0.0.1/
  Public URL:    ${PUBLIC_IP:+http://$PUBLIC_IP}
  Logs:          sudo journalctl -u httpd -f
                 sudo tail -f /var/log/httpd/scamcheck-error.log
  Restart:       sudo systemctl restart httpd

Notes:
  - No frontend build step exists: index.html, app.js, config.js, and
    style.css are served directly from /var/www/html.
  - This script copies the repository's default config.js, which points at
    http://localhost:3000. Run cli3.sh next to point the deployed site at the
    backend. Re-running cli2.sh resets config.js, so re-run cli3.sh afterward.
  - The backend security group must allow TCP 8000 from app_client_sg. The
    default cli3.sh proxy mode is designed for exactly that rule.

Next step:
  ./cli3.sh http://<BACKEND_PUBLIC_IP>:8000
EOF
