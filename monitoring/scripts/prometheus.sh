#!/bin/bash

set -e

############################################
# CONFIGURATION
############################################
PROMETHEUS_VERSION="3.5.0"
ALERTMANAGER_VERSION="0.27.0"

# Private IPs of the EC2 instances being monitored
MONITORING_SERVER="10.0.134.152:9100"
APP_SERVER_1="10.0.133.214:9100"
APP_SERVER_2="10.0.133.215:9100"
BACKEND_FASTAPI="10.0.133.214:8000"

############################################
# CREATE USER
############################################
echo "Creating prometheus user..."

if ! id prometheus &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
fi

############################################
# CREATE DIRECTORIES
############################################
echo "Creating directories..."

mkdir -p /etc/prometheus
mkdir -p /var/lib/prometheus

############################################
# DOWNLOAD PROMETHEUS
############################################
cd /tmp

echo "Downloading Prometheus v${PROMETHEUS_VERSION}..."

wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz

echo "Extracting package..."

tar -xzf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz

############################################
# INSTALL BINARIES
############################################
echo "Installing binaries..."

cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/

chmod +x /usr/local/bin/prometheus
chmod +x /usr/local/bin/promtool

############################################
# GENERATE PROMETHEUS CONFIG
############################################
echo "Generating prometheus.yaml..."

cat > /etc/prometheus/prometheus.yaml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "localhost:9093"

rule_files:
  - /etc/prometheus/alert-rules.yml

scrape_configs:
  - job_name: "node_exporters"
    static_configs:
      - targets:
          - "${MONITORING_SERVER}"
          - "${APP_SERVER_1}"
          - "${APP_SERVER_2}"
        labels:
          env: production

  - job_name: "fastapi"
    metrics_path: "/metrics"
    static_configs:
      - targets:
          - "${BACKEND_FASTAPI}"
        labels:
          env: production
          app: observability-backend
EOF

############################################
# COPY ALERT RULES
############################################
# Copy the alert rules from the repo
cp /tmp/alert-rules.yml /etc/prometheus/alert-rules.yml

############################################
# SET PERMISSIONS
############################################
chown -R prometheus:prometheus /etc/prometheus
chown -R prometheus:prometheus /var/lib/prometheus

############################################
# CREATE SYSTEMD SERVICE — PROMETHEUS
############################################
echo "Creating Prometheus systemd service..."

cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Monitoring Server
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple

ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yaml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.listen-address=:9090

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

############################################
# INSTALL ALERTMANAGER
############################################
echo "Downloading Alertmanager v${ALERTMANAGER_VERSION}..."

cd /tmp
wget -q https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
tar -xzf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz

cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager /usr/local/bin/
cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/amtool /usr/local/bin/

mkdir -p /etc/alertmanager /var/lib/alertmanager

# Copy config from repo (must be present at /tmp/alertmanager.yml)
cp /tmp/alertmanager.yml /etc/alertmanager/alertmanager.yml

chown -R prometheus:prometheus /etc/alertmanager
chown -R prometheus:prometheus /var/lib/alertmanager

cat > /etc/systemd/system/alertmanager.service <<EOF
[Unit]
Description=Prometheus Alertmanager
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple

ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager \
  --web.listen-address=:9093

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

############################################
# START SERVICES
############################################
systemctl daemon-reload

systemctl enable prometheus
systemctl restart prometheus

systemctl enable alertmanager
systemctl restart alertmanager

############################################
# VERIFY
############################################
echo ""
echo "Checking Prometheus..."
sleep 5
curl -s http://localhost:9090/-/healthy
echo ""

echo "Checking Alertmanager..."
curl -s http://localhost:9093/-/healthy
echo ""

echo "Prometheus targets:"
echo "  ${MONITORING_SERVER}"
echo "  ${APP_SERVER_1}"
echo "  ${APP_SERVER_2}"
echo "  ${BACKEND_FASTAPI}"
echo ""
echo "Installation completed successfully."