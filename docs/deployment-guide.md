# Deployment Guide

Step-by-step instructions to deploy the full AWS Observability Platform from scratch.

---

## Prerequisites

- AWS account with appropriate permissions (EC2, RDS, Lambda, CloudWatch, S3, IAM, EventBridge)
- AWS CLI configured (`aws configure`)
- SSH key pair created in the target region

---

## Step 1 — Network

1. Create VPC `10.0.0.0/16`
2. Create subnets as per [infrastructure/vpc.md](vpc.md)
3. Create and attach Internet Gateway to the VPC
4. Create NAT Gateway in the public subnet (requires an Elastic IP)
5. Configure route tables (public → IGW, private → NAT, DB → local only)
6. Create all Security Groups as per [infrastructure/security-groups.md](security-groups.md)

---

## Step 2 — IAM

Create both IAM roles as per [infrastructure/iam-roles.md](iam-roles.md):

- `ec2-observability-role` + instance profile (for CloudWatch Agent on Backend EC2)
- `lambda-log-export-role` (for the log export Lambda)

---

## Step 3 — RDS

```bash
aws rds create-db-instance \
  --db-instance-identifier observability-db \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --engine-version 8.0 \
  --master-username admin \
  --master-user-password <STRONG_PASSWORD> \
  --allocated-storage 20 \
  --vpc-security-group-ids <rds-sg-id> \
  --db-subnet-group-name <db-subnet-group> \
  --multi-az \
  --no-publicly-accessible \
  --backup-retention-period 7
```

Note the RDS endpoint — set it as `DB_HOST` in the backend `.env`.

---

## Step 4 — EC2 Instances

Launch three EC2 instances (Ubuntu 22.04 LTS, `t3.micro` for dev / `t3.small` for prod):

| Instance | Subnet | Security Group | Instance Profile |
|----------|--------|----------------|-----------------|
| Frontend EC2 | Private AZ-a | `frontend-sg` | none |
| Backend EC2 | Private AZ-a | `backend-sg` | `ec2-observability-profile` |
| Monitoring EC2 | Private AZ-b | `monitoring-sg` | none |

No instances get a public IP. SSH access is via the bastion host.

---

## Step 5 — Backend Application

On the Backend EC2 (via bastion SSH tunnel):

```bash
# Clone repo
git clone https://github.com/<YOUR_USERNAME>/AWS-Observability-Platform.git
cd AWS-Observability-Platform/app/backend

# Create virtualenv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Configure environment
cp .env.example .env
nano .env   # Set DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME

# Create systemd service
sudo tee /etc/systemd/system/fastapi.service <<EOF
[Unit]
Description=FastAPI Backend
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/AWS-Observability-Platform/app/backend
EnvironmentFile=/home/ubuntu/AWS-Observability-Platform/app/backend/.env
ExecStart=/home/ubuntu/AWS-Observability-Platform/app/backend/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable fastapi
sudo systemctl start fastapi

# Verify
curl http://localhost:8000/
curl http://localhost:8000/docs
curl http://localhost:8000/metrics | head -20
```

---

## Step 6 — Frontend Application

On the Frontend EC2:

```bash
# Install Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Clone repo and build
git clone https://github.com/<YOUR_USERNAME>/AWS-Observability-Platform.git
cd AWS-Observability-Platform/app/frontend

cp .env.example .env
# Set REACT_APP_API_URL=/api  (Nginx will proxy /api/* to backend)

npm install
npm run build

# Install and configure Nginx
sudo apt install nginx -y
sudo mkdir -p /var/www/observability
sudo cp -r build/* /var/www/observability/

sudo tee /etc/nginx/sites-available/observability <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/observability;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://<BACKEND_PRIVATE_IP>:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF

sudo rm /etc/nginx/sites-enabled/default
sudo ln -s /etc/nginx/sites-available/observability /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

---

## Step 7 — Node Exporter (all three EC2s)

Run on each EC2:

```bash
bash monitoring/scripts/node-exporter.sh
```

Verify: `curl http://localhost:9100/metrics | head`

---

## Step 8 — Prometheus, Grafana, Alertmanager (Monitoring EC2)

```bash
# Copy alert rules and alertmanager config to /tmp first
cp monitoring/alerting/alert-rules.yml /tmp/
cp monitoring/alerting/alertmanager.yml /tmp/
# Edit alertmanager.yml to add your PagerDuty integration keys

bash monitoring/scripts/prometheus.sh
bash monitoring/scripts/grafana.sh
```

Access Grafana via SSH tunnel:
```bash
ssh -L 3000:<MONITORING_PRIVATE_IP>:3000 ubuntu@<BASTION_PUBLIC_IP>
# Then open http://localhost:3000 in your browser
```

Import dashboards:
- Dashboard ID `1860` — Node Exporter Full (infrastructure metrics)
- Dashboard ID `17175` — FastAPI Observability (application metrics)

---

## Step 9 — CloudWatch Logging

```bash
# On Backend EC2
bash logging/setup-cloudwatch-agent.sh  # or follow logging/README.md manually

# Create S3 bucket and set bucket policy (see logging/README.md)

# Deploy Lambda
cd logging
zip lambda-export-logs.zip lambda-export-logs.py
aws lambda create-function \
  --function-name export-cloudwatch-logs \
  --runtime python3.12 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/lambda-log-export-role \
  --handler lambda-export-logs.lambda_handler \
  --zip-file fileb://lambda-export-logs.zip \
  --timeout 600 \
  --environment Variables="{LOG_GROUP_NAME=/aws/ec2/observability-platform,S3_BUCKET_NAME=observability-logs-archive}"

# Create EventBridge rule
aws events put-rule \
  --name observability-log-export-daily \
  --schedule-expression "cron(0 2 * * ? *)" \
  --state ENABLED
```

---

## Step 10 — Distributed Tracing

```bash
# On Monitoring EC2: install Tempo
TEMPO_VERSION="2.4.1"
wget https://github.com/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_linux_amd64.tar.gz
tar -xzf tempo_${TEMPO_VERSION}_linux_amd64.tar.gz
sudo cp tempo /usr/local/bin/
sudo mkdir -p /var/lib/tempo/{traces,wal,generator/wal} /etc/tempo
sudo cp tracing/tempo-config.yaml /etc/tempo/tempo.yaml
# Create systemd service (see tracing/README.md)

# On Backend EC2: add OTel dependencies
pip install opentelemetry-sdk opentelemetry-api \
  opentelemetry-instrumentation-fastapi \
  opentelemetry-instrumentation-sqlalchemy \
  opentelemetry-exporter-otlp-proto-grpc

# Set environment variable
export OTEL_EXPORTER_OTLP_ENDPOINT=<MONITORING_PRIVATE_IP>:4317

# In main.py: call configure_tracing(app, engine=engine)
# See tracing/otel-config.py

# In Grafana: add Tempo data source → http://localhost:3200
```

---

## Step 11 — Application Load Balancer

```bash
# Create target groups
aws elbv2 create-target-group \
  --name frontend-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id <VPC_ID> \
  --health-check-path /

aws elbv2 create-target-group \
  --name backend-tg \
  --protocol HTTP \
  --port 8000 \
  --vpc-id <VPC_ID> \
  --health-check-path /

# Register instances
aws elbv2 register-targets \
  --target-group-arn <FRONTEND_TG_ARN> \
  --targets Id=<FRONTEND_EC2_ID>

aws elbv2 register-targets \
  --target-group-arn <BACKEND_TG_ARN> \
  --targets Id=<BACKEND_EC2_ID>

# Create ALB (see AWS Console for HTTPS listener + ACM certificate setup)
```

---

## Verification checklist

- [ ] `curl http://<ALB_DNS>/` returns React app
- [ ] `curl http://<ALB_DNS>/api/` returns `{"status":"healthy"}`
- [ ] Prometheus targets all show `UP` at `http://localhost:9090/targets`
- [ ] Grafana dashboards show data
- [ ] CloudWatch Logs log group shows active streams
- [ ] Lambda invocation succeeds and files appear in S3
- [ ] Traces appear in Grafana Tempo Explore
- [ ] Test alert fires in Alertmanager (`amtool alert add test-alert severity=critical`)