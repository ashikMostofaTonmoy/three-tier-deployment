#!/usr/bin/env bash
# =============================================================================
#  Part 5/6 monitoring: node_exporter + nginx-prometheus-exporter go on the
#  FRONTEND instance (bound to all interfaces — the security group, not the
#  bind address, is what keeps them private). Everything else — Prometheus,
#  Alertmanager, Loki, Promtail, Grafana, postgres_exporter (pointed at RDS)
#  — installs on the BACKEND instance, exactly like Part 3/4's single-VM
#  stack, just relocated. Prometheus on the backend scrapes the frontend's
#  two exporters over its PRIVATE IP.
#
#  Usage:
#    scripts/deploy-monitoring-vpc.sh
#    SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..." scripts/deploy-monitoring-vpc.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/_common-vpc.sh

FRONTEND_ID="$(state_get FRONTEND_INSTANCE_ID)"; : "${FRONTEND_ID:?run infra/44-ec2-instances.sh first}"
BACKEND_ID="$(state_get BACKEND_INSTANCE_ID)"; : "${BACKEND_ID:?run infra/44-ec2-instances.sh first}"
FRONTEND_PRIVATE_IP="$(state_get FRONTEND_PRIVATE_IP)"
DB_ENDPOINT="$(state_get DB_ENDPOINT)"; : "${DB_ENDPOINT:?run infra/43-rds.sh first}"
DB_NAME="$(state_get DB_NAME)"; DB_USER="$(state_get DB_USER)"; DB_PASSWORD="$(state_get DB_PASSWORD)"
DEPLOY_BUCKET="$(state_get DEPLOY_BUCKET)"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/PLACEHOLDER/PLACEHOLDER/PLACEHOLDER}"

echo "==> staging monitoring configs (templated with the frontend's private IP) in S3"
WORKDIR="$(mktemp -d)"
cp -r monitoring/. "$WORKDIR/"
sed -i "s/FRONTEND_PRIVATE_IP/${FRONTEND_PRIVATE_IP}/" "$WORKDIR/prometheus-vpc.yml"
tar -czf /tmp/monitoring-vpc.tgz -C "$WORKDIR" .
aws s3 cp /tmp/monitoring-vpc.tgz "s3://${DEPLOY_BUCKET}/monitoring-vpc.tgz"
rm -rf "$WORKDIR" /tmp/monitoring-vpc.tgz

# ---- Part A: exporters on the FRONTEND instance ---------------------------
FRONT_TMP="$(mktemp)"
cat > "$FRONT_TMP" <<'REMOTE'
set -e
ARCH=amd64
latest_tag() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+'; }

if ! systemctl is-active --quiet node_exporter 2>/dev/null; then
  V=$(latest_tag prometheus/node_exporter); VN=${V#v}
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
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now node_exporter
  echo "node_exporter installed"
else
  echo "node_exporter already running"
fi

if ! grep -q "nginx_status" /etc/nginx/sites-available/three-tier 2>/dev/null; then
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
  curl -fsSL -o /tmp/nginx-exporter.tgz "https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/${V}/nginx-prometheus-exporter_${VN}_linux_${ARCH}.tar.gz"
  tar -xzf /tmp/nginx-exporter.tgz -C /tmp nginx-prometheus-exporter
  sudo mv /tmp/nginx-prometheus-exporter /usr/local/bin/nginx-prometheus-exporter
  cat <<'UNIT' | sudo tee /etc/systemd/system/nginx-exporter.service >/dev/null
[Unit]
Description=Nginx Prometheus Exporter
After=network.target nginx.service
[Service]
ExecStart=/usr/local/bin/nginx-prometheus-exporter --web.listen-address=0.0.0.0:9113 --nginx.scrape-uri=http://127.0.0.1/nginx_status
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now nginx-exporter
  echo "nginx-exporter installed"
else
  echo "nginx-exporter already running"
fi
rm -f /tmp/*.tgz
REMOTE

echo "==> installing exporters on the frontend (${FRONTEND_ID})"
ssm_run "$FRONTEND_ID" "$FRONT_TMP"
rm -f "$FRONT_TMP"

# ---- Part B: the full stack on the BACKEND instance ------------------------
BACK_TMP="$(mktemp)"
cat > "$BACK_TMP" <<REMOTE
set -e
ARCH=amd64
BUCKET=${DEPLOY_BUCKET}
DB_ENDPOINT=${DB_ENDPOINT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
latest_tag() { curl -fsSL "https://api.github.com/repos/\$1/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+'; }

if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  sudo apt-get update -y -qq && sudo apt-get install -y -qq unzip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
rm -rf /tmp/monitoring && mkdir -p /tmp/monitoring
aws s3 cp "s3://\${BUCKET}/monitoring-vpc.tgz" /tmp/monitoring.tgz
tar -xzf /tmp/monitoring.tgz -C /tmp/monitoring

if ! systemctl is-active --quiet node_exporter 2>/dev/null; then
  V=\$(latest_tag prometheus/node_exporter); VN=\${V#v}
  curl -fsSL -o /tmp/node_exporter.tgz "https://github.com/prometheus/node_exporter/releases/download/\${V}/node_exporter-\${VN}.linux-\${ARCH}.tar.gz"
  tar -xzf /tmp/node_exporter.tgz -C /tmp
  sudo mv "/tmp/node_exporter-\${VN}.linux-\${ARCH}/node_exporter" /usr/local/bin/node_exporter
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
  sudo systemctl daemon-reload && sudo systemctl enable --now node_exporter
fi

sudo -u postgres -H true 2>/dev/null || true
if ! systemctl is-active --quiet postgres_exporter 2>/dev/null; then
  V=\$(latest_tag prometheus-community/postgres_exporter); VN=\${V#v}
  curl -fsSL -o /tmp/postgres_exporter.tgz "https://github.com/prometheus-community/postgres_exporter/releases/download/\${V}/postgres_exporter-\${VN}.linux-\${ARCH}.tar.gz"
  tar -xzf /tmp/postgres_exporter.tgz -C /tmp
  sudo mv "/tmp/postgres_exporter-\${VN}.linux-\${ARCH}/postgres_exporter" /usr/local/bin/postgres_exporter
  cat <<UNIT | sudo tee /etc/systemd/system/postgres_exporter.service >/dev/null
[Unit]
Description=Postgres Exporter (RDS)
After=network.target
[Service]
Environment=DATA_SOURCE_NAME=postgresql://\${DB_USER}:\${DB_PASSWORD}@\${DB_ENDPOINT}:5432/\${DB_NAME}?sslmode=require
ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=127.0.0.1:9187
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload && sudo systemctl enable --now postgres_exporter
fi

sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo cp /tmp/monitoring/prometheus-vpc.yml /etc/prometheus/prometheus.yml
sudo cp /tmp/monitoring/alert-rules.yml /etc/prometheus/alert-rules.yml
if ! systemctl is-active --quiet prometheus 2>/dev/null; then
  V=\$(latest_tag prometheus/prometheus); VN=\${V#v}
  curl -fsSL -o /tmp/prometheus.tgz "https://github.com/prometheus/prometheus/releases/download/\${V}/prometheus-\${VN}.linux-\${ARCH}.tar.gz"
  tar -xzf /tmp/prometheus.tgz -C /tmp
  sudo mv "/tmp/prometheus-\${VN}.linux-\${ARCH}/prometheus" "/tmp/prometheus-\${VN}.linux-\${ARCH}/promtool" /usr/local/bin/
  sudo useradd --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true
  sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
  cat <<'UNIT' | sudo tee /etc/systemd/system/prometheus.service >/dev/null
[Unit]
Description=Prometheus
After=network.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --web.listen-address=127.0.0.1:9090 --web.enable-lifecycle
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload && sudo systemctl enable --now prometheus
else
  sudo chown -R prometheus:prometheus /etc/prometheus
  curl -fsS -X POST http://localhost:9090/-/reload
fi

sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sed "s#https://hooks.slack.com/services/PLACEHOLDER/PLACEHOLDER/PLACEHOLDER#\${SLACK_WEBHOOK_URL}#" /tmp/monitoring/alertmanager.yml.example | sudo tee /etc/alertmanager/alertmanager.yml >/dev/null
if ! systemctl is-active --quiet alertmanager 2>/dev/null; then
  V=\$(latest_tag prometheus/alertmanager); VN=\${V#v}
  curl -fsSL -o /tmp/alertmanager.tgz "https://github.com/prometheus/alertmanager/releases/download/\${V}/alertmanager-\${VN}.linux-\${ARCH}.tar.gz"
  tar -xzf /tmp/alertmanager.tgz -C /tmp
  sudo mv "/tmp/alertmanager-\${VN}.linux-\${ARCH}/alertmanager" "/tmp/alertmanager-\${VN}.linux-\${ARCH}/amtool" /usr/local/bin/
  sudo useradd --no-create-home --shell /usr/sbin/nologin alertmanager 2>/dev/null || true
  sudo chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
  cat <<'UNIT' | sudo tee /etc/systemd/system/alertmanager.service >/dev/null
[Unit]
Description=Alertmanager
After=network.target
[Service]
User=alertmanager
ExecStart=/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=127.0.0.1:9093
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload && sudo systemctl enable --now alertmanager
else
  sudo chown -R alertmanager:alertmanager /etc/alertmanager
  sudo systemctl restart alertmanager
fi

sudo mkdir -p /etc/loki /var/lib/loki /etc/promtail /var/lib/promtail
sudo cp /tmp/monitoring/loki-config.yml /etc/loki/loki-config.yml
sudo cp /tmp/monitoring/promtail-config.yml /etc/promtail/promtail-config.yml
if ! systemctl is-active --quiet loki 2>/dev/null; then
  V=\$(latest_tag grafana/loki)
  curl -fsSL -o /tmp/loki.zip "https://github.com/grafana/loki/releases/download/\${V}/loki-linux-\${ARCH}.zip"
  sudo apt-get install -y -qq unzip
  unzip -q -o /tmp/loki.zip -d /tmp
  sudo mv "/tmp/loki-linux-\${ARCH}" /usr/local/bin/loki
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
  sudo systemctl daemon-reload && sudo systemctl enable --now loki
else
  sudo systemctl restart loki
fi
if ! systemctl is-active --quiet promtail 2>/dev/null; then
  V=v3.5.0   # pinned — Loki dropped Promtail from releases after this (see monitoring/README notes)
  curl -fsSL -o /tmp/promtail.zip "https://github.com/grafana/loki/releases/download/\${V}/promtail-linux-\${ARCH}.zip"
  unzip -q -o /tmp/promtail.zip -d /tmp
  sudo mv "/tmp/promtail-linux-\${ARCH}" /usr/local/bin/promtail
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
  sudo systemctl daemon-reload && sudo systemctl enable --now promtail
else
  sudo systemctl restart promtail
fi

if ! command -v grafana-server >/dev/null 2>&1; then
  sudo apt-get install -y -qq apt-transport-https software-properties-common gnupg
  curl -fsSL https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/grafana.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list >/dev/null
  sudo apt-get update -y -qq
  sudo apt-get install -y -qq grafana
  sudo sed -i 's/^;http_port = 3000/http_port = 3001/' /etc/grafana/grafana.ini
  sudo systemctl enable --now grafana-server
fi

rm -f /tmp/*.tgz /tmp/*.zip
sudo apt-get clean

echo
echo "=== service status ==="
for s in node_exporter postgres_exporter prometheus alertmanager loki promtail grafana-server; do
  printf "%-18s %s\n" "\$s" "\$(systemctl is-active \$s)"
done
REMOTE

echo "==> installing the monitoring stack on the backend (${BACKEND_ID})"
ssm_run "$BACKEND_ID" "$BACK_TMP"
rm -f "$BACK_TMP"

echo "==> OK. Reach the UIs via SSM port-forwarding, e.g.:"
echo "    aws ssm start-session --target ${BACKEND_ID} --document-name AWS-StartPortForwardingSession \\"
echo "      --parameters '{\"portNumber\":[\"3001\"],\"localPortNumber\":[\"3001\"]}'"
echo "    then open http://localhost:3001"
