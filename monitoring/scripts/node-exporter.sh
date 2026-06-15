#!/bin/bash

set -e

NODE_EXPORTER_VERSION="1.9.1"

echo "Creating node_exporter user..."

if ! id "node_exporter" &>/dev/null; then
useradd --no-create-home --shell /bin/false node_exporter
fi

cd /tmp

echo "Downloading Node Exporter..."

wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz

echo "Extracting package..."

tar -xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz

echo "Installing binary..."

cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/

chown node_exporter:node_exporter /usr/local/bin/node_exporter

echo "Creating systemd service..."

cat <<EOF >/etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

echo "Verifying service..."

systemctl status node_exporter --no-pager

echo "Checking metrics endpoint..."

sleep 3

curl http://localhost:9100/metrics | head

echo ""
echo "Node Exporter installation completed successfully."