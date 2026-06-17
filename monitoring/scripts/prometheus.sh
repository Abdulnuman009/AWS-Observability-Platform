#!/bin/bash

set -e

############################################
# CONFIGURATION
############################################
PROMETHEUS_VERSION="3.5.0"

# Replace with your actual private IPs
MONITORING_SERVER="10.0.134.152:9100"
APP_SERVER_1="10.0.133.214:9100"
APP_SERVER_2="10.0.133.215:9100"

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

cat >/etc/prometheus/prometheus.yaml <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "node_exporters"
    static_configs:
      - targets:
          - "${MONITORING_SERVER}"
          - "${APP_SERVER_1}"
          - "${APP_SERVER_2}"
EOF

############################################
# SET PERMISSIONS
############################################
chown -R prometheus:prometheus /etc/prometheus
chown -R prometheus:prometheus /var/lib/prometheus

############################################
# CREATE SYSTEMD SERVICE
############################################
echo "Creating systemd service..."

cat >/etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Monitoring Server
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple

ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yaml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --web.listen-address=:9090

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

############################################
# START SERVICE
############################################
systemctl daemon-reload
systemctl enable prometheus
systemctl restart prometheus

############################################
# VERIFY
############################################
echo ""
echo "Checking Prometheus service..."
echo ""

systemctl status prometheus --no-pager

echo ""
echo "Checking Prometheus health endpoint..."
echo ""

sleep 5

curl -s http://localhost:9090/-/healthy

echo ""
echo ""
echo "Prometheus installation completed successfully."

echo ""
echo "Configured targets:"
echo "${MONITORING_SERVER}"
echo "${APP_SERVER_1}"
echo "${APP_SERVER_2}"