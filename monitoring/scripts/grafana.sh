#!/bin/bash

set -e

echo "=========================================="
echo "Installing Grafana Enterprise"
echo "=========================================="

# Update package index
apt-get update -y

# Install required packages
apt-get install -y wget adduser libfontconfig1 musl

# Download Grafana package
cd /tmp
GRAFANA_VERSION="13.0.2"
echo "Downloading Grafana ${GRAFANA_VERSION}..."
wget -q https://dl.grafana.com/enterprise/release/grafana-enterprise_${GRAFANA_VERSION}_amd64.deb

echo "Installing Grafana..."
dpkg -i grafana-enterprise_${GRAFANA_VERSION}_amd64.deb || apt-get install -f -y

echo "Enabling Grafana service..."
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server

echo ""
echo "Checking service status..."
echo ""
systemctl --no-pager --full status grafana-server

echo ""
echo "Checking port 3000..."
echo ""
ss -tulpn | grep 3000

echo ""
echo "Grafana installation completed successfully."
echo ""
echo "Local URL:"
echo "http://localhost:3000"
echo ""
echo "Default Credentials:"
echo "Username: admin"
echo "Password: admin"
echo ""
echo "You will be prompted to change the password on first login."