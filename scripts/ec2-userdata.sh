#!/usr/bin/env bash
# =============================================================================
#  EC2 "User Data" bootstrap — paste this into the launch wizard (Advanced
#  details -> User data), or pass it to infra/01-ec2.sh:
#
#      ./infra/01-ec2.sh --user-data scripts/ec2-userdata.sh
#
#  It runs ONCE, as root, the first time the instance boots. When it finishes
#  the instance is a working web server showing a "waiting for first deploy"
#  page. The first run of scripts/deploy.sh (or the GitHub Actions workflow)
#  then puts the real app on it.
#
#  Everything here is self-contained on purpose: User Data can't see your repo.
#  The Nginx block below is the same one kept in nginx/three-tier.conf.
#  Log: /var/log/cloud-init-output.log
# =============================================================================
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---- 1. Nginx + AWS CLI --------------------------------------------------
# (Ubuntu 24.04 dropped the "awscli" apt package, so install v2 from AWS.)
apt-get update -y
apt-get install -y nginx curl unzip
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# ---- 2. Folder layout: releases + a "current" symlink --------------------
install -d /var/www/three-tier/releases/000-placeholder
cat > /var/www/three-tier/releases/000-placeholder/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>Weather Board</title>
<body style="font-family:system-ui;background:#0f172a;color:#e2e8f0;display:grid;place-items:center;height:100vh;margin:0">
<div style="text-align:center">
  <h1>Weather Board</h1>
  <p>Server is up. Waiting for the first deploy…</p>
</div>
HTML
ln -sfn /var/www/three-tier/releases/000-placeholder /var/www/three-tier/current

# ---- 3. Nginx site config (keep in sync with nginx/three-tier.conf) ------
cat > /etc/nginx/sites-available/three-tier <<'NGINX'
server {
    listen 80 default_server;
    server_name _;

    root  /var/www/three-tier/current;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        resolver 127.0.0.53 valid=30s;
        set $upstream "api.open-meteo.com";
        rewrite ^/api/(.*)$ /$1 break;
        proxy_pass https://$upstream;
        proxy_ssl_server_name on;
        proxy_set_header Host $upstream;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }
}
NGINX

ln -sfn /etc/nginx/sites-available/three-tier /etc/nginx/sites-enabled/three-tier
rm -f /etc/nginx/sites-enabled/default

# ---- 4. Go live --------------------------------------------------------
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "bootstrap complete: $(date -u)"
