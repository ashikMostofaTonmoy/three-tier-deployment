#!/usr/bin/env bash
# =============================================================================
#  Install the full monitoring stack on the VM: node_exporter,
#  nginx-prometheus-exporter, postgres_exporter, Prometheus, Alertmanager,
#  Loki, Promtail, and Grafana — all as systemd services, all idempotent
#  (safe to re-run after editing a monitoring/*.yml file).
#
#  Usage:
#    scripts/deploy-monitoring.sh
#    SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..." scripts/deploy-monitoring.sh
#
#  Requires: infra/01-ec2.sh and infra/30-monitoring-sg.sh already run, and
#  the Part 2 app stack (scripts/deploy-db.sh / deploy-backend.sh / deploy.sh)
#  already deployed — this script does not install the app itself.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/_common.sh

HOST="$(state_get PUBLIC_IP)"; : "${HOST:?run infra/01-ec2.sh first}"
# Must stay a well-formed URL even as a placeholder — Alertmanager validates
# the URL's syntax at startup, not just when it tries to send (see the
# comment in monitoring/alertmanager.yml.example).
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/PLACEHOLDER/PLACEHOLDER/PLACEHOLDER}"
SSH=(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${HOST}")
SCP=(scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "==> uploading monitoring/ configs to ${HOST}"
"${SSH[@]}" 'mkdir -p /tmp/monitoring'
"${SCP[@]}" -r monitoring/. "ubuntu@${HOST}:/tmp/monitoring/"

echo "==> installing + configuring the stack (this takes a few minutes the first time)"
"${SSH[@]}" SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL" 'bash -s' <<'REMOTE'
set -e
ARCH=amd64
latest_tag() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+'; }

# ---- 1. node_exporter — SERVER monitoring -------------------------------
if ! systemctl is-active --quiet node_exporter 2>/dev/null; then
  V=$(latest_tag prometheus/node_exporter); VN=${V#v}
  echo "-- node_exporter $V --"
  curl -fsSL -o /tmp/node_exporter.tgz "https://github.com/prometheus/node_exporter/releases/download/${V}/node_exporter-${VN}.linux-${ARCH}.tar.gz"
  tar -xzf /tmp/node_exporter.tgz -C /tmp
  sudo mv "/tmp/node_exporter-${VN}.linux-${ARCH}/node_exporter" /usr/local/bin/node_exporter
  sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true
  cat <<'UNIT' | sudo tee /etc/systemd/system/node_exporter.service >/dev/null
[Unit]
Description=Prometheus Node Exporter
After=network.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now node_exporter
else
  echo "-- node_exporter already running --"
fi

# ---- 2. nginx stub_status + nginx-prometheus-exporter — frontend tier ---
if ! grep -q "nginx_status" /etc/nginx/sites-available/three-tier 2>/dev/null; then
  echo "-- adding Nginx stub_status (127.0.0.1 only) --"
  sudo sed -i '/location = \/healthz {/i\
    location = /nginx_status {\
        stub_status;\
        allow 127.0.0.1;\
        deny all;\
        access_log off;\
    }\
' /etc/nginx/sites-available/three-tier
  sudo nginx -t && sudo systemctl reload nginx
fi
if ! systemctl is-active --quiet nginx-exporter 2>/dev/null; then
  V=$(latest_tag nginxinc/nginx-prometheus-exporter); VN=${V#v}
  echo "-- nginx-prometheus-exporter $V --"
  curl -fsSL -o /tmp/nginx-exporter.tgz "https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/${V}/nginx-prometheus-exporter_${VN}_linux_${ARCH}.tar.gz"
  tar -xzf /tmp/nginx-exporter.tgz -C /tmp nginx-prometheus-exporter
  sudo mv /tmp/nginx-prometheus-exporter /usr/local/bin/nginx-prometheus-exporter
  cat <<'UNIT' | sudo tee /etc/systemd/system/nginx-exporter.service >/dev/null
[Unit]
Description=Nginx Prometheus Exporter
After=network.target nginx.service
[Service]
ExecStart=/usr/local/bin/nginx-prometheus-exporter --web.listen-address=127.0.0.1:9113 --nginx.scrape-uri=http://127.0.0.1/nginx_status
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now nginx-exporter
else
  echo "-- nginx-exporter already running --"
fi

# ---- 3. postgres_exporter — database tier -------------------------------
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='postgres_exporter'" | grep -q 1 || {
  PGEXP_PASSWORD=$(openssl rand -hex 12)
  sudo -u postgres psql -c "CREATE USER postgres_exporter WITH PASSWORD '${PGEXP_PASSWORD}';"
  sudo -u postgres psql -c "GRANT pg_monitor TO postgres_exporter;"
  echo "$PGEXP_PASSWORD" | sudo tee /etc/postgres_exporter_password >/dev/null
  sudo chmod 600 /etc/postgres_exporter_password
}
PGEXP_PASSWORD=$(sudo cat /etc/postgres_exporter_password)
if ! systemctl is-active --quiet postgres_exporter 2>/dev/null; then
  V=$(latest_tag prometheus-community/postgres_exporter); VN=${V#v}
  echo "-- postgres_exporter $V --"
  curl -fsSL -o /tmp/postgres_exporter.tgz "https://github.com/prometheus-community/postgres_exporter/releases/download/${V}/postgres_exporter-${VN}.linux-${ARCH}.tar.gz"
  tar -xzf /tmp/postgres_exporter.tgz -C /tmp
  sudo mv "/tmp/postgres_exporter-${VN}.linux-${ARCH}/postgres_exporter" /usr/local/bin/postgres_exporter
  cat <<UNIT | sudo tee /etc/systemd/system/postgres_exporter.service >/dev/null
[Unit]
Description=Postgres Exporter
After=network.target postgresql.service
[Service]
Environment=DATA_SOURCE_NAME=postgresql://postgres_exporter:${PGEXP_PASSWORD}@localhost:5432/three_tier?sslmode=disable
ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=127.0.0.1:9187
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now postgres_exporter
else
  echo "-- postgres_exporter already running --"
fi

# ---- 4. Prometheus -------------------------------------------------------
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo cp /tmp/monitoring/prometheus.yml /etc/prometheus/prometheus.yml
sudo cp /tmp/monitoring/alert-rules.yml /etc/prometheus/alert-rules.yml
if ! systemctl is-active --quiet prometheus 2>/dev/null; then
  V=$(latest_tag prometheus/prometheus); VN=${V#v}
  echo "-- prometheus $V --"
  curl -fsSL -o /tmp/prometheus.tgz "https://github.com/prometheus/prometheus/releases/download/${V}/prometheus-${VN}.linux-${ARCH}.tar.gz"
  tar -xzf /tmp/prometheus.tgz -C /tmp
  sudo mv "/tmp/prometheus-${VN}.linux-${ARCH}/prometheus" "/tmp/prometheus-${VN}.linux-${ARCH}/promtool" /usr/local/bin/
  # Prometheus 3.x dropped the old consoles/console_libraries dirs from the
  # tarball (replaced by the bundled React UI) — only copy them if present,
  # so this still works on both 2.x and 3.x releases.
  [ -d "/tmp/prometheus-${VN}.linux-${ARCH}/consoles" ] && \
    sudo cp -r "/tmp/prometheus-${VN}.linux-${ARCH}/consoles" "/tmp/prometheus-${VN}.linux-${ARCH}/console_libraries" /etc/prometheus/ || true
  sudo useradd --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true
  sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
  cat <<'UNIT' | sudo tee /etc/systemd/system/prometheus.service >/dev/null
[Unit]
Description=Prometheus
After=network.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now prometheus
else
  echo "-- prometheus already installed, reloading config --"
  sudo chown -R prometheus:prometheus /etc/prometheus
  curl -fsS -X POST http://localhost:9090/-/reload
fi

# ---- 5. Alertmanager ------------------------------------------------------
sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sed "s#https://hooks.slack.com/services/PLACEHOLDER/PLACEHOLDER/PLACEHOLDER#${SLACK_WEBHOOK_URL}#" /tmp/monitoring/alertmanager.yml.example \
  | sudo tee /etc/alertmanager/alertmanager.yml >/dev/null
if ! systemctl is-active --quiet alertmanager 2>/dev/null; then
  V=$(latest_tag prometheus/alertmanager); VN=${V#v}
  echo "-- alertmanager $V --"
  curl -fsSL -o /tmp/alertmanager.tgz "https://github.com/prometheus/alertmanager/releases/download/${V}/alertmanager-${VN}.linux-${ARCH}.tar.gz"
  tar -xzf /tmp/alertmanager.tgz -C /tmp
  sudo mv "/tmp/alertmanager-${VN}.linux-${ARCH}/alertmanager" "/tmp/alertmanager-${VN}.linux-${ARCH}/amtool" /usr/local/bin/
  sudo useradd --no-create-home --shell /usr/sbin/nologin alertmanager 2>/dev/null || true
  sudo chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
  cat <<'UNIT' | sudo tee /etc/systemd/system/alertmanager.service >/dev/null
[Unit]
Description=Alertmanager
After=network.target
[Service]
User=alertmanager
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager \
  --web.listen-address=0.0.0.0:9093
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now alertmanager
else
  echo "-- alertmanager already installed, restarting to pick up config --"
  sudo chown -R alertmanager:alertmanager /etc/alertmanager
  sudo systemctl restart alertmanager
fi

# ---- 6. Loki + Promtail — logs --------------------------------------------
sudo mkdir -p /etc/loki /var/lib/loki /etc/promtail /var/lib/promtail
sudo cp /tmp/monitoring/loki-config.yml /etc/loki/loki-config.yml
sudo cp /tmp/monitoring/promtail-config.yml /etc/promtail/promtail-config.yml
if ! systemctl is-active --quiet loki 2>/dev/null; then
  V=$(latest_tag grafana/loki)
  echo "-- loki $V --"
  curl -fsSL -o /tmp/loki.zip "https://github.com/grafana/loki/releases/download/${V}/loki-linux-${ARCH}.zip"
  sudo apt-get install -y -qq unzip
  unzip -q -o /tmp/loki.zip -d /tmp
  sudo mv "/tmp/loki-linux-${ARCH}" /usr/local/bin/loki
  cat <<'UNIT' | sudo tee /etc/systemd/system/loki.service >/dev/null
[Unit]
Description=Loki
After=network.target
[Service]
ExecStart=/usr/local/bin/loki --config.file=/etc/loki/loki-config.yml
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now loki
else
  echo "-- loki already installed, restarting to pick up config --"
  sudo systemctl restart loki
fi
if ! systemctl is-active --quiet promtail 2>/dev/null; then
  # NOT latest_tag: Grafana stopped shipping Promtail with Loki releases
  # after v3.5.0 (Loki 3.7+ has no promtail-*.zip asset at all) — they're
  # steering everyone toward "Grafana Alloy" instead. Promtail is simpler to
  # teach and still fully supported (maintenance mode, not gone), so this
  # pins the last release that included it. The Loki *server* above still
  # runs latest — only the promtail client version is pinned.
  V=v3.5.0
  echo "-- promtail $V (pinned — see comment above) --"
  curl -fsSL -o /tmp/promtail.zip "https://github.com/grafana/loki/releases/download/${V}/promtail-linux-${ARCH}.zip"
  unzip -q -o /tmp/promtail.zip -d /tmp
  sudo mv "/tmp/promtail-linux-${ARCH}" /usr/local/bin/promtail
  cat <<'UNIT' | sudo tee /etc/systemd/system/promtail.service >/dev/null
[Unit]
Description=Promtail
After=network.target loki.service
[Service]
ExecStart=/usr/local/bin/promtail --config.file=/etc/promtail/promtail-config.yml
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now promtail
else
  echo "-- promtail already installed, restarting to pick up config --"
  sudo systemctl restart promtail
fi

# ---- 7. Grafana ------------------------------------------------------------
if ! command -v grafana-server >/dev/null 2>&1; then
  echo "-- installing Grafana (official apt repo) --"
  sudo apt-get install -y -qq apt-transport-https software-properties-common gnupg
  curl -fsSL https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/grafana.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | sudo tee /etc/apt/sources.list.d/grafana.list >/dev/null
  sudo apt-get update -y -qq
  sudo apt-get install -y -qq grafana
  # 3000 is already the backend's internal port on this box — move Grafana to 3001.
  sudo sed -i 's/^;http_port = 3000/http_port = 3001/' /etc/grafana/grafana.ini
  sudo systemctl enable --now grafana-server
else
  echo "-- grafana already installed --"
fi

echo
echo "-- disk cleanup: the downloaded archives + build dirs above easily add
-- up to 700MB+ on this VM's ~7GB root volume. Not needed once installed. --"
rm -f /tmp/*.tgz /tmp/*.zip
rm -rf /tmp/prometheus-*.linux-* /tmp/alertmanager-*.linux-* /tmp/node_exporter-*.linux-* \
       /tmp/postgres_exporter-*.linux-*
sudo apt-get clean
df -h / | tail -1

echo
echo "=== versions ==="
node_exporter --version 2>&1 | head -1 || true
/usr/local/bin/prometheus --version 2>&1 | head -1
/usr/local/bin/alertmanager --version 2>&1 | head -1
/usr/local/bin/loki --version 2>&1 | head -1
grafana-server -v 2>&1 | head -1

echo
echo "=== service status ==="
for s in node_exporter nginx-exporter postgres_exporter prometheus alertmanager loki promtail grafana-server; do
  printf "%-18s %s\n" "$s" "$(systemctl is-active $s)"
done
REMOTE

echo "==> OK — monitoring stack installed. See README §25/§31 for how to open each UI."
