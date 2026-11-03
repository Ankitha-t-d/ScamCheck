# ScamCheck

Checks suspicious SMS/WhatsApp messages and links for scam signs, highlights the exact phrases that give them away, and tests password strength in the browser. No database: every request is analysed on the fly with explainable rules.

**Stack:** Node.js + Express (backend), HTML/CSS/JavaScript (frontend).

| Part | Path | Notes |
|---|---|---|
| API | `backend/` | `POST /api/analyze/message`, `POST /api/analyze/url`, `GET /api/health` |
| Website | `frontend/` | Static files. API address is set in `frontend/config.js` |

## Run locally
```bash
cd backend && npm install && npm start      # http://localhost:3000
# open frontend/index.html in a browser (or: npx serve frontend)
npm test                                     # unit tests for the detection rules
```

## Deploy on AWS (two EC2 instances, Amazon Linux 2023)

### Backend instance
1. Security group `scam_server_sg`: Custom TCP `3000` (Anywhere IPv4) and SSH `22`. Key pair `scam_server_key`. Launch instance `scam_server`.
2. Connect with SSH, then:
```bash
sudo dnf update -y
sudo dnf install git nodejs npm -y
git clone https://github.com/<your-username>/<your-repo>.git
cd <your-repo>/backend
npm install
sudo npm install -g pm2
pm2 start server.js --name scamcheck-api
pm2 save && pm2 startup        # run the command it prints
curl http://localhost:3000/api/health
```

### Frontend instance
1. Security group `scam_client_sg`: HTTP `80` and SSH `22`. Key pair `scam_client_key`. Launch instance `scam_client`.
2. Connect with SSH, then:
```bash
sudo dnf update -y
sudo dnf install git httpd -y
git clone https://github.com/<your-username>/<your-repo>.git
sudo cp -r <your-repo>/frontend/* /var/www/html/
sudo sed -i 's|http://localhost:3000|http://<BACKEND_PUBLIC_IP>:3000|' /var/www/html/config.js
sudo systemctl enable --now httpd
```

### Lock the API to your frontend
On the backend instance:
```bash
pm2 delete scamcheck-api
ALLOWED_ORIGIN=http://<FRONTEND_PUBLIC_IP> pm2 start server.js --name scamcheck-api
pm2 save
```
Open `http://<FRONTEND_PUBLIC_IP>` in a browser.

## How it works
- **Links:** checks for raw IPs, `@` tricks, look-alike (punycode) domains, brand impersonation and misspellings (for example `paypa1.com`), shorteners, risky endings, bait words, many subdomains.
- **Messages:** matches scam patterns common in India (OTP requests, account-block threats, KYC/PAN updates, prizes, fee or QR payment requests, fake jobs, "digital arrest" calls, urgency), then runs every link through the link checker.
- **Passwords:** entropy estimate with penalties for common passwords, sequences, repeats and years. Runs only in the browser.

Rule-based results are guidance, not proof. Report fraud at cybercrime.gov.in or call 1930.
