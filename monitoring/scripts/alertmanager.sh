#!/bin/bash

set -e

ALERTMANAGER_VERSION="0.27.0"

echo "Creating alertmanager user..."
if ! id alertmanager &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin alertmanager
fi

echo "Creating directories..."
mkdir -p /etc/alertmanager
mkdir -p /var/lib/alertmanager

cd /tmp

echo "Downloading Alertmanager v${ALERTMANAGER_VERSION}..."
wget -q https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz

echo "Extracting package..."
tar -xzf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz

echo "Installing binaries..."
cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager /usr/local/bin/
cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/amtool /usr/local/bin/

chmod +x /usr/local/bin/alertmanager
chmod +x /usr/local/bin/amtool

echo "Setting permissions..."
chown -R alertmanager:alertmanager /etc/alertmanager
chown -R alertmanager:alertmanager /var/lib/alertmanager
chown alertmanager:alertmanager /usr/local/bin/alertmanager
chown alertmanager:alertmanager /usr/local/bin/amtool

echo "Creating systemd service..."
cat >/etc/systemd/system/alertmanager.service <<EOF
[Unit]
Description=Prometheus Alertmanager
After=network.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple

ExecStart=/usr/local/bin/alertmanager \\
  --config.file=/etc/alertmanager/alertmanager.yaml \\
  --storage.path=/var/lib/alertmanager

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "Starting Alertmanager service..."
systemctl daemon-reload
systemctl enable alertmanager
# Note: It will fail to start until we create the alertmanager.yaml in the next step, 
# so we will just enable it here.
echo "Installation complete. Please create /etc/alertmanager/alertmanager.yaml and run: sudo systemctl restart alertmanager"