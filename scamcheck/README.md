# ScamCheck

ScamCheck checks suspicious SMS/WhatsApp messages and links for scam signs, highlights the exact phrases that give them away, and tests password strength in the browser. There is no database: every request is analysed on the fly with explainable rules.

**Stack:** Node.js + Express (backend), plain HTML/CSS/JavaScript (frontend).

---

## 1. What this project actually uses

The repository contains a nested `scamcheck/` directory. After cloning, the real paths are:

| Part | Path | Technology |
|---|---|---|
| Backend | `scamcheck/backend/` | Node.js 18+, Express 4.19, `cors` 2.8 |
| Backend entry point | `scamcheck/backend/server.js` | `node server.js` (`npm start`) |
| Frontend | `scamcheck/frontend/` | Static HTML, CSS, and browser JavaScript |
| Frontend entry point | `scamcheck/frontend/index.html` | No build step, no framework |
| Runtime API config | `scamcheck/frontend/config.js` | `window.APP_CONFIG.API_BASE` |

### Inspection results

- **Backend framework:** Express 4. The app is created in `server.js`; it exports `app` and only calls `app.listen()` when run directly.
- **Default backend port:** `3000` (`process.env.PORT || 3000`). The deployment uses `PORT=8000`, which the existing code already supports; no code change is required.
- **Backend dependencies:** only `express` and `cors` (see `backend/package.json` and `package-lock.json`). No native modules, compiler, Python, or system libraries are needed.
- **Frontend framework:** none. It is a single static page with `index.html`, `app.js`, `config.js`, and `style.css`.
- **Frontend production build:** none. There is no `package.json`, bundler, or output directory. Apache can serve the source files directly.
- **Machine learning / NLP / AI models:** none. Detection is deterministic regular expressions and URL heuristics in `backend/src/`.
- **Datasets or model files:** none.
- **File uploads:** none.
- **Database or persistent storage:** none. The only state is an in-memory rate-limit map in `server.js`; it resets when the process restarts.
- **External services:** none at runtime. The page loads Google Fonts from the browser, but the application itself does not call any third-party API.
- **Password checker:** runs entirely in the browser in `frontend/app.js`; passwords are never sent to the backend.
- **Rate limit:** 60 requests per minute per `req.ip` for `/api/*`, held in memory.
- **API documentation:** there is no Swagger/OpenAPI endpoint. The backend does not serve `/docs`.

### API endpoints used by the frontend

| Method | Path | Used by |
|---|---|---|
| `GET` | `/api/health` | Header status indicator and deployment checks |
| `POST` | `/api/analyze/message` | Message tab |
| `POST` | `/api/analyze/url` | Link tab and links found inside messages |

All POST bodies use `{ "input": "..." }`. The frontend builds URLs as `${API_BASE}/api/analyze/<kind>`.

### Existing CORS configuration

`server.js` reads a comma-separated `ALLOWED_ORIGIN` environment variable:

```js
const origins = (process.env.ALLOWED_ORIGIN || '*').split(',').map(s => s.trim());
app.use(cors({ origin: origins.includes('*') ? true : origins }));
```

The deployment scripts keep this single mechanism. `ser2.sh` seeds localhost origins, and `ser3.sh` adds the exact frontend origin without introducing a second CORS middleware or a wildcard.

### Runtime environment variables

| Variable | Default | Deployment value |
|---|---|---|
| `PORT` | `3000` | `8000` |
| `NODE_ENV` | unset | `production` |
| `ALLOWED_ORIGIN` | `*` | Comma-separated exact origins; no `*` |

The systemd unit reads these from `/etc/scamcheck/backend.env`.

---

## 2. AWS architecture

```
                         Browser
                            |
              http://<FRONTEND_PUBLIC_IP>/
                            |
                            v
        +--------------------------------------+
        | app_client (Amazon Linux 2023)       |
        | Apache httpd :80                     |
        | /var/www/html (static ScamCheck)     |
        |                                      |
        | /api/* reverse proxy (default mode)  |
        +------------------+-------------------+
                           |
             http://<BACKEND_PUBLIC_IP>:8000
                           |
                           v
        +--------------------------------------+
        | app_server (Amazon Linux 2023)       |
        | Node.js + Express :8000              |
        | systemd: scamcheck-api               |
        +--------------------------------------+
```

Two EC2 instances, two security groups, two key pairs:

| Instance | Purpose | Port | Key pair | Security group |
|---|---|---:|---|---|
| `app_server` | Node/Express API | `8000` | `app_server_key` | `app_server_sg` |
| `app_client` | Apache static frontend + reverse proxy | `80` | `app_client_key` | `app_client_sg` |

### Important architecture note: static frontend vs. security-group source

The frontend is static, so **the user's browser** is the process that calls the API. A rule that allows TCP `8000` only from `app_client_sg` does **not** allow the browser: that rule only allows traffic whose source is the frontend EC2 instance.

There are two valid ways to handle this:

1. **Reverse proxy (default, recommended).** `cli3.sh` configures Apache on `app_client` to forward `/api/*` to `http://<BACKEND_PUBLIC_IP>:8000`. The browser calls only port 80 on the frontend. The backend security group can stay restricted to `app_client_sg`, exactly as specified.
2. **Direct mode.** `cli3.sh --direct` writes the backend public URL into the deployed `config.js`, so the browser calls port 8000 directly. This is simpler, but `app_server_sg` must then allow TCP 8000 from `0.0.0.0/0` (or the specific client IPs). CORS still limits which web origins can read responses, but the API itself is reachable by anyone who can connect.

The default is proxy mode because it matches the requested `app_client_sg` rule and avoids exposing the API to the whole internet.

### Compatibility notes

- **Port 8000:** compatible. `server.js` already honours `PORT`; the systemd unit sets `PORT=8000`. The frontend has no hardcoded backend port in application source; the deployed `config.js` is runtime configuration.
- **Amazon Linux 2023:** compatible. Node.js 18+ and Apache `httpd` are available from `dnf`.
- **Instance size:** `t3.micro` (2 burstable vCPU, 1 GiB RAM) is enough. There is no ML model, GPU, or large dataset. The Node process and dependencies use well under 200 MB. Use `t3.small` only if you expect many concurrent users.
- **No client-side routing:** the app is a single page with tabs, not routes. A page refresh at `/` works. No SPA rewrite is added, so missing assets still return real 404s.
- **No build step:** `cli2.sh` copies the frontend files directly to `/var/www/html`; it does not run `npm run build`.
- **Rate limiting in proxy mode:** because all proxied requests arrive from the frontend instance, the in-memory 60/min limit is shared by all users in proxy mode. For a lab/demo this is acceptable. Direct mode preserves per-client IP limiting. See the troubleshooting section if you need to change this.
- **Public IP changes:** unless you attach an Elastic IP, stopping and starting an instance changes its public IP. Re-run `cli3.sh` and `ser3.sh` after such a change.

---

## 3. Prerequisites

- An AWS account and permission to create EC2 instances, security groups, and key pairs.
- An AWS region selected in the console (for example `ap-south-1`). Use the same region for both instances.
- A GitHub account that can read `https://github.com/Ankitha-t-d/ScamCheck`.
- A terminal with SSH (Linux/macOS terminal, Windows PowerShell, or Git Bash).
- The `.pem` key files stored outside the repository. Never commit them.

---

## 4. Create the security groups

### 4.1 Backend security group: `app_server_sg`

Create it in the same VPC as the instances.

| Type | Protocol | Port | Source | Purpose |
|---|---|---:|---|---|
| SSH | TCP | `22` | My IP | Administration |
| Custom TCP | TCP | `8000` | `app_client_sg` | Frontend reverse proxy |

The `8000` source must be the **security group**, not a CIDR, for proxy mode. In the console choose **Source → Security group → app_client_sg**.

If you use `cli3.sh --direct`, add one more inbound rule:

| Type | Protocol | Port | Source |
|---|---|---:|---|
| Custom TCP | TCP | `8000` | `0.0.0.0/0` (or your client IPs) |

Do not add both the `app_client_sg` rule and a broad `0.0.0.0/0` rule unless you actually need direct mode.

### 4.2 Frontend security group: `app_client_sg`

| Type | Protocol | Port | Source |
|---|---|---:|---|
| HTTP | TCP | `80` | `0.0.0.0/0` |
| SSH | TCP | `22` | My IP |

### 4.3 Temporary backend access from your laptop

To test the API directly (for example `http://<BACKEND_PUBLIC_IP>:8000/api/health`) without using the frontend:

1. Find your public IP: `curl https://checkip.amazonaws.com`.
2. In `app_server_sg`, add an inbound Custom TCP rule for port `8000` with source `<YOUR_IP>/32`.
3. Run the test.
4. **Remove the rule immediately afterward.** Do not leave port 8000 open to your IP longer than necessary.

AWS CLI equivalents (replace the group IDs and CIDR):

```bash
# Add temporary access
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 8000 --cidr <YOUR_IP>/32

# Remove it again
aws ec2 revoke-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 8000 --cidr <YOUR_IP>/32
```

There is no Swagger page to open. Use `/api/health` and the POST endpoints shown in the testing section.

### 4.4 Security-group CLI example

```bash
# Create the groups (same VPC)
aws ec2 create-security-group \
  --group-name app_server_sg \
  --description "ScamCheck backend: SSH and API from app_client_sg" \
  --vpc-id vpc-xxxxxxxx

aws ec2 create-security-group \
  --group-name app_client_sg \
  --description "ScamCheck frontend: HTTP and SSH" \
  --vpc-id vpc-xxxxxxxx

# Replace sg-server and sg-client with the returned group IDs.
# SSH from your IP
aws ec2 authorize-security-group-ingress \
  --group-id sg-server \
  --protocol tcp --port 22 --cidr <YOUR_IP>/32

# Backend API only from the frontend security group
aws ec2 authorize-security-group-ingress \
  --group-id sg-server \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":8000,"ToPort":8000,"UserIdGroupPairs":[{"GroupId":"sg-client"}]}]'

# Frontend HTTP from anywhere and SSH from your IP
aws ec2 authorize-security-group-ingress \
  --group-id sg-client \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id sg-client \
  --protocol tcp --port 22 --cidr <YOUR_IP>/32
```

---

## 5. Create the key pairs

Create two RSA `.pem` key pairs:

- `app_server_key`
- `app_client_key`

Console: **EC2 → Key pairs → Create key pair**, choose **RSA**, choose **.pem**, and download each file.

AWS CLI:

```bash
aws ec2 create-key-pair \
  --key-name app_server_key \
  --key-type rsa \
  --key-format pem \
  --query 'KeyMaterial' --output text > app_server_key.pem

aws ec2 create-key-pair \
  --key-name app_client_key \
  --key-type rsa \
  --key-format pem \
  --query 'KeyMaterial' --output text > app_client_key.pem

chmod 400 app_server_key.pem app_client_key.pem
```

On Windows PowerShell, write the key material with ASCII encoding and restrict access:

```powershell
aws ec2 create-key-pair --key-name app_server_key --key-type rsa --key-format pem `
  --query 'KeyMaterial' --output text | Out-File -Encoding ascii app_server_key.pem
```

Store the files somewhere safe. If you lose a private key, you cannot recover it; create a new key pair and replace the instance's key.

---

## 6. Launch the EC2 instances

Use **Amazon Linux 2023** (x86_64) for both.

### 6.1 `app_server`

| Setting | Value |
|---|---|
| Name | `app_server` |
| AMI | Amazon Linux 2023 |
| Instance type | `t3.micro` |
| Key pair | `app_server_key` |
| Security group | `app_server_sg` |
| Storage | 8 GiB gp3 (default is enough) |
| Public IP | Auto-assign enabled |

### 6.2 `app_client`

| Setting | Value |
|---|---|
| Name | `app_client` |
| AMI | Amazon Linux 2023 |
| Instance type | `t3.micro` |
| Key pair | `app_client_key` |
| Security group | `app_client_sg` |
| Storage | 8 GiB gp3 |
| Public IP | Auto-assign enabled |

Both instances need outbound internet access (the default security-group egress rule allows it) so `dnf`, `git clone`, and `npm install` work. If you use a private subnet, add a NAT gateway or VPC endpoint; the lab setup normally uses a public subnet.

## 7. Connect to the instances over SSH

In the AWS console:

1. Open **EC2 → Instances**.
2. Select the instance (`app_server` or `app_client`).
3. Choose **Connect → SSH client**.
4. Copy the displayed command. It looks like:

```bash
ssh -i "app_server_key.pem" ec2-user@ec2-xx-xx-xx-xx.compute-1.amazonaws.com
```

5. In your terminal, `cd` to the directory containing the `.pem` file, fix its permissions, and run the command:

```bash
chmod 400 app_server_key.pem
ssh -i app_server_key.pem ec2-user@<BACKEND_PUBLIC_DNS_OR_IP>
```

For the frontend use `app_client_key.pem` and the frontend address.

On Windows PowerShell the same `ssh` command works if OpenSSH is installed. If SSH reports `Permissions 0644 ... too open`, run:

```bash
chmod 400 app_server_key.pem
```

On Windows, use **Properties → Security → Advanced** to remove inherited permissions and grant only your user read access, or run `icacls` to restrict the file.

When the Amazon Linux prompt appears (`[ec2-user@ip-... ~]$`), you are connected. The default user is `ec2-user`; do not use `root`.

---

## 8. Clone the repository on both instances

Run on **each** instance:

```bash
sudo dnf update -y
sudo dnf install git -y
git clone https://github.com/Ankitha-t-d/ScamCheck.git
```

The repository contains a nested `scamcheck/` folder, so the real paths are:

```text
~/ScamCheck/scamcheck/backend
~/ScamCheck/scamcheck/frontend
```

Confirm before continuing:

```bash
cd ~/ScamCheck/scamcheck
ls
# backend  frontend  README.md
```

All commands below use these actual paths. If you clone to a different directory, adjust the `cd` commands, but keep the script names and their locations inside `backend/scripts/` and `frontend/scripts/`.

---

## 9. Backend EC2 deployment

### 9.1 Run `ser2.sh`

On `app_server`:

```bash
cd ~/ScamCheck/scamcheck/backend/scripts
chmod +x ser2.sh
./ser2.sh
```

`ser2.sh` performs these steps:

1. Detects Amazon Linux 2023 (and warns if run on another `dnf`-based system).
2. Runs `sudo dnf update -y`.
3. Installs `git`, `curl`, `tar`, `nodejs`, and `npm`.
4. Checks that Node.js is version 18 or newer.
5. Installs the existing backend dependencies with `npm ci --omit=dev` (or `npm install` if the lockfile is missing).
6. Runs the existing unit tests (`npm test`).
7. Creates `/etc/scamcheck/backend.env` with `PORT=8000`, `NODE_ENV=production`, and localhost CORS origins.
8. Creates `/etc/systemd/system/scamcheck-api.service`, running as `ec2-user` from the actual backend directory.
9. Enables and starts the service, then waits for `GET /api/health`.
10. Prints the service status, health URL, log command, and next steps.

The service uses the existing entry point directly:

```text
/usr/bin/node /home/ec2-user/ScamCheck/scamcheck/backend/server.js
```

No application code is rewritten, and no ML/model setup is needed.

### 9.2 Verify the backend

```bash
sudo systemctl status scamcheck-api --no-pager
curl http://localhost:8000/api/health
```

Expected health response:

```json
{"status":"ok","time":"..."}
```

Test the two real endpoints locally:

```bash
curl -s -X POST http://localhost:8000/api/analyze/url \
  -H 'Content-Type: application/json' \
  -d '{"input":"http://hdfcbank-kyc-update.xyz/login"}'

curl -s -X POST http://localhost:8000/api/analyze/message \
  -H 'Content-Type: application/json' \
  -d '{"input":"Dear customer, your SBI account will be blocked today. Update KYC immediately: http://sbi-kyc-update.top/login"}'
```

The first should return a high score and findings; the second should return `level: "dangerous"`.

### 9.3 API documentation

There is **no Swagger/OpenAPI page**. The backend has no `/docs` route. Use:

- `GET /api/health`
- `POST /api/analyze/url`
- `POST /api/analyze/message`

If you need temporary access from your laptop, add the `8000` rule for your IP described in section 4.3, test, and remove it.

### 9.4 Service and log commands

```bash
sudo systemctl restart scamcheck-api
sudo systemctl status scamcheck-api --no-pager
sudo journalctl -u scamcheck-api -f
sudo journalctl -u scamcheck-api -n 100 --no-pager
```

The service is enabled at boot:

```bash
systemctl is-enabled scamcheck-api
```

### 9.5 Re-running the backend script

`ser2.sh` is idempotent. After `git pull`, run it again. It reinstalls dependencies, rewrites the unit file, and restarts the service. It preserves an existing `ALLOWED_ORIGIN` line, so a previously configured frontend origin is not lost.

---

## 10. Frontend EC2 deployment

### 10.1 Run `cli2.sh`

On `app_client`:

```bash
cd ~/ScamCheck/scamcheck/frontend/scripts
chmod +x cli2.sh
./cli2.sh
```

`cli2.sh` performs these steps:

1. Detects Amazon Linux 2023.
2. Runs `sudo dnf update -y`.
3. Installs Apache HTTP Server (`httpd`), `git`, `curl`, and `tar`.
4. Confirms that `index.html`, `app.js`, `config.js`, and `style.css` exist.
5. Copies the static frontend into `/var/www/html`, excluding `scripts/`, `.git`, and `node_modules`.
6. Sets root ownership and read-only permissions, and restores SELinux contexts with `restorecon`.
7. Writes `/etc/httpd/conf.d/scamcheck.conf` with:
   - `DirectoryIndex index.html`
   - directory access for `/var/www/html`
   - no directory listing
   - no-cache headers for `config.js` and `index.html`
8. Enables and starts `httpd`.
9. Tests `/`, `/style.css`, `/app.js`, and `/config.js` through `localhost`.
10. Opens HTTP in `firewalld` if `firewalld` is active.

There is no frontend runtime or package manager to install because there is no build step. Apache serves the files directly.

### 10.2 Verify the frontend

```bash
sudo systemctl status httpd --no-pager
curl -I http://localhost/
```

Open `http://<FRONTEND_PUBLIC_IP>` in a browser. You should see the ScamCheck page. The header status will say **Server unreachable** until `cli3.sh` points the site at the backend; that is expected at this stage.

Useful files and commands:

```bash
cat /etc/httpd/conf.d/scamcheck.conf
sudo systemctl restart httpd
sudo journalctl -u httpd -f
sudo tail -f /var/log/httpd/scamcheck-error.log
sudo tail -f /var/log/httpd/scamcheck-access.log
```

### 10.3 Re-running the frontend script

`cli2.sh` is idempotent, but it **resets** `/var/www/html/config.js` to the repository default (`http://localhost:3000`). After re-running it, run `cli3.sh` again to restore the backend connection.

## 11. Connect the frontend to the backend

### 11.1 Default: reverse proxy mode (recommended)

This mode keeps the backend security group restricted to `app_client_sg`. The browser talks only to Apache on the frontend, and Apache forwards `/api/*` to the backend public IP.

**On `app_client`:**

```bash
cd ~/ScamCheck/scamcheck/frontend/scripts
chmod +x cli3.sh
./cli3.sh http://<BACKEND_PUBLIC_IP>:8000
```

`cli3.sh` performs these steps:

1. Validates the backend URL (scheme, host, optional port; no path or wildcard).
2. Checks `http://<BACKEND_PUBLIC_IP>:8000/api/health` from the frontend instance.
3. Enables Apache `mod_proxy`, `mod_proxy_http`, and `mod_headers` if needed.
4. Sets the SELinux boolean `httpd_can_network_connect` when SELinux is enforcing.
5. Writes `/etc/httpd/conf.d/scamcheck-api-proxy.conf`:

```apache
ProxyRequests Off
ProxyPreserveHost Off
ProxyTimeout 30
ProxyPass        /api  http://<BACKEND_PUBLIC_IP>:8000/api  timeout=30
ProxyPassReverse /api  http://<BACKEND_PUBLIC_IP>:8000/api
RequestHeader set X-Forwarded-Proto "http"
```

6. Writes the deployed `/var/www/html/config.js` with `API_BASE: ""`, so `app.js` calls `/api/...` on the same origin.
7. Reloads Apache and tests `/api/health` and `POST /api/analyze/url` through the proxy.
8. Prints the frontend URL and the next command to run on the backend.

The repository copy `frontend/config.js` is intentionally left unchanged; the backend IP is not hardcoded into application source.

**On `app_server`, lock CORS to the frontend origin:**

```bash
cd ~/ScamCheck/scamcheck/backend/scripts
chmod +x ser3.sh
./ser3.sh http://<FRONTEND_PUBLIC_IP>
```

`ser3.sh` performs these steps:

1. Validates the frontend origin.
2. Updates `ALLOWED_ORIGIN` in `/etc/scamcheck/backend.env` to:
   `http://<FRONTEND_PUBLIC_IP>,http://localhost:3000,http://localhost:5173,http://localhost:8080,http://127.0.0.1:3000,http://127.0.0.1:5173,http://127.0.0.1:8080`
3. Restarts `scamcheck-api`.
4. Waits for `/api/health`.
5. Verifies both the simple CORS response and the `OPTIONS` preflight response for the exact origin.
6. Never writes `*`.

Use the exact frontend origin. `http://1.2.3.4` and `http://1.2.3.4:80` are different strings; pick the form the browser actually uses (usually no explicit `:80`).

### 11.2 Direct mode (optional, less secure)

Use this only if you specifically want the browser to call port 8000:

```bash
cd ~/ScamCheck/scamcheck/frontend/scripts
./cli3.sh --direct http://<BACKEND_PUBLIC_IP>:8000
```

Then:

1. In `app_server_sg`, add inbound TCP `8000` from `0.0.0.0/0` (or the client IPs that need access). The `app_client_sg` rule alone is not sufficient because the request comes from the browser, not from the frontend instance.
2. Run `ser3.sh` on the backend with the frontend origin, as above.
3. Open the frontend and test.

Direct mode exposes the API to the internet. CORS restricts which web pages can read responses, but it does not prevent direct `curl` access. Prefer proxy mode.

### 11.3 Verify CORS manually

On `app_server`:

```bash
curl -i -H "Origin: http://<FRONTEND_PUBLIC_IP>" \
  http://localhost:8000/api/health
```

Look for:

```text
Access-Control-Allow-Origin: http://<FRONTEND_PUBLIC_IP>
```

Preflight check:

```bash
curl -i -X OPTIONS \
  -H "Origin: http://<FRONTEND_PUBLIC_IP>" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" \
  http://localhost:8000/api/analyze/message
```

The response should be `204` with the same `Access-Control-Allow-Origin` header and `Access-Control-Allow-Methods` including `POST`.

### 11.4 If a public IP changes

If you stop/start an instance without an Elastic IP, its public IP changes. Then:

- If the **backend** IP changed: re-run `cli3.sh` on the frontend with the new URL.
- If the **frontend** IP changed: re-run `ser3.sh` on the backend with the new origin.
- Reload the browser with a hard refresh (`Ctrl+F5`) so the updated `config.js` is used.

---

## 12. Final integration testing

Test the real functionality, not only the homepage.

### 12.1 Backend checklist

```bash
# Service is active and enabled
sudo systemctl is-active scamcheck-api
sudo systemctl is-enabled scamcheck-api

# Health endpoint
curl -s http://localhost:8000/api/health

# Real URL analysis
curl -s -X POST http://localhost:8000/api/analyze/url \
  -H 'Content-Type: application/json' \
  -d '{"input":"https://paypa1.com/verify"}'

# Real message analysis
curl -s -X POST http://localhost:8000/api/analyze/message \
  -H 'Content-Type: application/json' \
  -d '{"input":"This is CBI. A parcel in your name has narcotics. Call +91 9876543210 now to avoid arrest."}'
```

Expected:

- `is-active` prints `active`; `is-enabled` prints `enabled`.
- Health returns `{"status":"ok",...}`.
- The typosquat URL returns findings and a score of at least 25.
- The CBI message returns `level: "dangerous"` or at least a suspicious score with findings.
- No ML/model files are needed; there is nothing to load.
- `ALLOWED_ORIGIN` contains the exact frontend origin and no `*`.

### 12.2 Frontend checklist

```bash
sudo systemctl is-active httpd
sudo systemctl is-enabled httpd
curl -I http://localhost/
curl -I http://localhost/style.css
curl -I http://localhost/app.js
curl -I http://localhost/config.js
```

Expected: Apache is active and enabled, and all four requests return `200`.

In the browser, open `http://<FRONTEND_PUBLIC_IP>` and check:

- The ScamCheck page loads with CSS and JavaScript.
- The status indicator says **Server online**.
- The **Message**, **Link**, and **Password** tabs switch correctly.
- Refreshing the page at `/` works.
- The browser developer console has no CORS or mixed-content errors.

### 12.3 End-to-end application tests

1. **Message tab:** click the **Bank KYC scam** example and press **Check message**. You should see a red/dangerous verdict, highlighted phrases, findings, and advice.
2. **Link tab:** click **Fake bank** and check it. You should see findings for the suspicious domain, `http` warning, and risky TLD.
3. **Genuine OTP example:** the result should be safe or low risk, demonstrating that the rules are not simply flagging everything.
4. **Password tab:** type `password123`; the result should be weak. Type a long random passphrase; the result should be strong. This runs only in the browser; confirm the network tab does not send the password.
5. **Input validation:** submit an empty input, an invalid URL, and a message shorter than 5 characters. The UI should show the existing validation messages rather than crashing.
6. **File uploads:** not supported by this project, so there is nothing to test.
7. **API failure path:** stop the backend temporarily and confirm the frontend shows a useful error. Restart the backend and retry.

### 12.4 Reboot persistence test

On each instance:

```bash
sudo reboot
```

Reconnect after the instance is running, then verify:

```bash
# On app_server
sudo systemctl is-active scamcheck-api
curl -s http://localhost:8000/api/health

# On app_client
sudo systemctl is-active httpd
curl -I http://localhost/
```

Both services should come back automatically because they are enabled in systemd.

---

## 13. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl: (7) Failed to connect` to `:8000` | Service down, wrong IP, or security group blocks the source | `sudo systemctl status scamcheck-api`; `sudo ss -ltnp \| grep ':8000'`; check `app_server_sg` |
| Browser says **Server unreachable** | Backend down or `config.js` points at the wrong URL | `curl http://localhost:8000/api/health` on the backend; rerun `cli3.sh` on the frontend |
| `502 Bad Gateway` / `503 Service Unavailable` through the frontend | Apache cannot reach the backend | Check backend health; check `app_server_sg` allows 8000 from `app_client_sg`; check SELinux boolean `httpd_can_network_connect` |
| CORS error in the browser console | `ALLOWED_ORIGIN` does not exactly match the frontend origin | Run `./ser3.sh http://<FRONTEND_PUBLIC_IP>` with the exact scheme/host/port; no trailing slash |
| `403 Forbidden` from Apache | Wrong file permissions or SELinux label | `sudo chown -R root:root /var/www/html`; `sudo find /var/www/html -type f -exec chmod 644 {} +`; `sudo restorecon -R /var/www/html` |
| Page loads but CSS/JS are missing | Assets were not copied or Apache is serving the wrong docroot | `ls -l /var/www/html`; rerun `cli2.sh`; check `/etc/httpd/conf.d/scamcheck.conf` |
| Refreshing a sub-page gives 404 | The app has no client-side routes; only `/` exists | Open `http://<FRONTEND_PUBLIC_IP>/`; do not expect `/message` or `/link` URLs |
| Old backend URL still used after `cli3.sh` | Browser cached `config.js` | Hard refresh (`Ctrl+F5`); the Apache config sends `no-store` for `config.js` |
| `npm ci` fails | Lockfile or npm version mismatch | `cd ~/ScamCheck/scamcheck/backend && npm install`; rerun `ser2.sh` |
| `EADDRINUSE: address already in use :::8000` | Another process is using port 8000 | `sudo ss -ltnp \| grep ':8000'`; stop the other process or change `PORT` in `/etc/scamcheck/backend.env` and the systemd unit |
| `Cannot find module 'express'` | Dependencies not installed or wrong `WorkingDirectory` | `cd ~/ScamCheck/scamcheck/backend && npm ci`; `sudo systemctl restart scamcheck-api`; check the unit's `WorkingDirectory` |
| `Permission denied (publickey)` | Wrong key, wrong user, or `.pem` permissions too open | Use `ec2-user`; `chmod 400 key.pem`; confirm the key pair name matches the instance |
| `429 Too many requests` | The in-memory rate limit (60/min) was exceeded | Wait a minute. In proxy mode all users share the limit; see the note below |
| Direct mode works from the frontend shell but not the browser | `app_server_sg` allows only `app_client_sg`, not the browser | Use proxy mode, or add TCP 8000 from `0.0.0.0/0`/client IPs |
| Mixed-content error | An HTTPS frontend is calling an HTTP backend | Use HTTPS for the backend or terminate TLS at Apache and proxy over HTTPS |
| Apache will not start | Syntax error or missing module | `sudo httpd -t`; read the error; check `/etc/httpd/conf.d/scamcheck*.conf` |
| `setsebool: command not found` | SELinux tools are missing | `sudo dnf install -y policycoreutils`; `sudo setsebool -P httpd_can_network_connect 1` |
| Service fails only after reboot | Unit not enabled or `EnvironmentFile` missing | `sudo systemctl enable scamcheck-api`; `ls -l /etc/scamcheck/backend.env`; `journalctl -u scamcheck-api -b` |
| `npm test` fails | A dependency or source file is missing | `cd ~/ScamCheck/scamcheck/backend && npm install && npm test`; inspect the failing test |
| Disk full during install | Small root volume or old logs | `df -h`; `sudo dnf clean all`; increase the EBS volume |

### Rate limiting in proxy mode

`server.js` uses `req.ip` for the in-memory limit. In proxy mode every request reaches Node from the frontend instance, so the 60 requests/minute budget is shared by all browser users. For a lab/demo this is fine. If you need per-user limits, either:

- Use direct mode (the browser's IP reaches Node), or
- Configure Express `trust proxy` and pass `X-Forwarded-For` correctly. That is an application change and is intentionally not made by these deployment scripts.

---

## 14. Restart, logs, and health commands

```bash
# Backend
sudo systemctl restart scamcheck-api
sudo systemctl status scamcheck-api --no-pager
sudo journalctl -u scamcheck-api -f
sudo journalctl -u scamcheck-api -n 100 --no-pager
curl -s http://localhost:8000/api/health

# Frontend
sudo systemctl restart httpd
sudo systemctl status httpd --no-pager
sudo journalctl -u httpd -f
sudo tail -f /var/log/httpd/scamcheck-error.log
sudo tail -f /var/log/httpd/scamcheck-access.log
curl -I http://localhost/

# Configuration files
sudo cat /etc/scamcheck/backend.env
sudo cat /etc/systemd/system/scamcheck-api.service
sudo cat /etc/httpd/conf.d/scamcheck.conf
sudo cat /etc/httpd/conf.d/scamcheck-api-proxy.conf
```

To change the backend port, edit `PORT` in `/etc/scamcheck/backend.env`, update the systemd unit and security group, then restart the service. Port 8000 is the tested configuration.

---

## 15. Security notes and cleanup

- Keep SSH (`22`) restricted to **My IP**.
- Keep `app_server_sg` port `8000` restricted to `app_client_sg` when using proxy mode.
- Do not use `ALLOWED_ORIGIN=*` in production. `ser3.sh` writes exact origins.
- Do not commit `.pem` files or `/etc/scamcheck/backend.env` to Git.
- The API has no authentication by design; it performs rule-based analysis and stores no user data. Still, avoid exposing it more broadly than necessary.
- The in-memory rate limit is a basic abuse control, not a full WAF.
- For a public production deployment, add HTTPS (ACM/ALB or Apache TLS), an Elastic IP or DNS name, and monitoring.
- Cleanup: terminate both instances, delete `app_server_sg` and `app_client_sg`, delete `app_server_key` and `app_client_key`, and release any Elastic IPs you created.

---

## 16. Script reference

| Script | Actual path | Purpose |
|---|---|---|
| `ser2.sh` | `scamcheck/backend/scripts/ser2.sh` | Install Node.js/dependencies, create and start the systemd backend on port 8000 |
| `ser3.sh` | `scamcheck/backend/scripts/ser3.sh` | Set exact CORS origins, restart the backend, verify CORS |
| `cli2.sh` | `scamcheck/frontend/scripts/cli2.sh` | Install Apache, deploy the static frontend to `/var/www/html`, start httpd |
| `cli3.sh` | `scamcheck/frontend/scripts/cli3.sh` | Configure the frontend-to-backend path (proxy by default, direct with `--direct`) |

### Exact command sequence

**On `app_server`:**

```bash
git clone https://github.com/Ankitha-t-d/ScamCheck.git
cd ~/ScamCheck/scamcheck/backend/scripts
chmod +x ser2.sh
./ser2.sh
# later, after the frontend exists:
chmod +x ser3.sh
./ser3.sh http://<FRONTEND_PUBLIC_IP>
```

**On `app_client`:**

```bash
git clone https://github.com/Ankitha-t-d/ScamCheck.git
cd ~/ScamCheck/scamcheck/frontend/scripts
chmod +x cli2.sh cli3.sh
./cli2.sh
./cli3.sh http://<BACKEND_PUBLIC_IP>:8000
```

**Then test in a browser:**

```text
http://<FRONTEND_PUBLIC_IP>
```

If you re-run `cli2.sh`, run `cli3.sh` again afterward because `cli2.sh` restores the repository's default `config.js`.

---

## How it works

- **Links:** checks for raw IPs, `@` tricks, look-alike (punycode) domains, brand impersonation and misspellings (for example `paypa1.com`), shorteners, risky endings, bait words, many subdomains.
- **Messages:** matches scam patterns common in India (OTP requests, account-block threats, KYC/PAN updates, prizes, fee or QR payment requests, fake jobs, "digital arrest" calls, urgency), then runs every link through the link checker.
- **Passwords:** entropy estimate with penalties for common passwords, sequences, repeats and years. Runs only in the browser.

Rule-based results are guidance, not proof. Report fraud at cybercrime.gov.in or call 1930.
