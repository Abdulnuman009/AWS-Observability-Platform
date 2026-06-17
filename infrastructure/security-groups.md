# Security Group Design

All EC2 instances and RDS run in private subnets with no public IP addresses. Only the Application Load Balancer sits in the public subnet and accepts internet traffic. Every Security Group follows a least-privilege, source-SG-based model — no IP ranges except for the ALB (which accepts `0.0.0.0/0` on 443 by design).

---

## Security Groups

### `alb-sg` — Application Load Balancer

| Direction | Protocol | Port | Source/Destination | Reason |
|-----------|----------|------|--------------------|--------|
| Inbound | TCP | 80 | 0.0.0.0/0 | HTTP (redirect to HTTPS) |
| Inbound | TCP | 443 | 0.0.0.0/0 | HTTPS from internet users |
| Outbound | TCP | 80 | `frontend-sg` | Forward to frontend Nginx |
| Outbound | TCP | 8000 | `backend-sg` | Direct API path (health checks) |

---

### `frontend-sg` — Frontend EC2

| Direction | Protocol | Port | Source/Destination | Reason |
|-----------|----------|------|--------------------|--------|
| Inbound | TCP | 80 | `alb-sg` | Nginx receives from ALB only |
| Inbound | TCP | 22 | `bastion-sg` | SSH from bastion jump host |
| Inbound | TCP | 9100 | `monitoring-sg` | Prometheus Node Exporter scrape |
| Outbound | TCP | 8000 | `backend-sg` | Nginx reverse proxy to FastAPI |
| Outbound | TCP | 443 | 0.0.0.0/0 | Package downloads via NAT |

---

### `backend-sg` — Backend EC2

| Direction | Protocol | Port | Source/Destination | Reason |
|-----------|----------|------|--------------------|--------|
| Inbound | TCP | 8000 | `frontend-sg` | FastAPI from Nginx only |
| Inbound | TCP | 22 | `bastion-sg` | SSH from bastion |
| Inbound | TCP | 9100 | `monitoring-sg` | Node Exporter scrape |
| Outbound | TCP | 3306 | `rds-sg` | MySQL connection to RDS |
| Outbound | TCP | 4317 | `monitoring-sg` | OTLP gRPC traces to Tempo |
| Outbound | TCP | 443 | 0.0.0.0/0 | Package downloads, CloudWatch API via NAT |

> CloudWatch Agent communicates with the CloudWatch service endpoint over HTTPS (443). This goes through the NAT Gateway — no credentials stored on disk, the EC2 instance role handles auth.

---

### `monitoring-sg` — Monitoring EC2

| Direction | Protocol | Port | Source/Destination | Reason |
|-----------|----------|------|--------------------|--------|
| Inbound | TCP | 9090 | `bastion-sg` | Prometheus UI (through bastion only) |
| Inbound | TCP | 3000 | `bastion-sg` | Grafana UI (through bastion only) |
| Inbound | TCP | 3200 | `backend-sg` | Tempo gRPC (Tempo HTTP API, internal) |
| Inbound | TCP | 4317 | `backend-sg` | OTLP gRPC from FastAPI |
| Inbound | TCP | 9093 | `bastion-sg` | Alertmanager UI |
| Inbound | TCP | 22 | `bastion-sg` | SSH from bastion |
| Outbound | TCP | 9100 | `frontend-sg` | Scrape Node Exporter |
| Outbound | TCP | 9100 | `backend-sg` | Scrape Node Exporter |
| Outbound | TCP | 8000 | `backend-sg` | Scrape FastAPI /metrics |
| Outbound | TCP | 443 | 0.0.0.0/0 | PagerDuty webhook, package downloads |

> Grafana and Prometheus UIs are never exposed to the internet. Access is via SSH tunnel through the bastion host:
> `ssh -L 3000:MONITORING_PRIVATE_IP:3000 ec2-user@BASTION_PUBLIC_IP`

---

### `rds-sg` — Amazon RDS (MySQL)

| Direction | Protocol | Port | Source/Destination | Reason |
|-----------|----------|------|--------------------|--------|
| Inbound | TCP | 3306 | `backend-sg` | MySQL from backend only |

No outbound rules needed — RDS does not initiate connections.

---

### `bastion-sg` — Bastion Host

| Direction | Protocol | Port | Source/Destination | Reason |
|-----------|----------|------|--------------------|--------|
| Inbound | TCP | 22 | `<trusted CIDR>` | SSH from a fixed IP or VPN CIDR only |
| Outbound | TCP | 22 | VPC CIDR | SSH to all private EC2s |

The bastion host is the only EC2 with a public IP. Its security group accepts SSH only from a trusted static IP or corporate VPN CIDR — never `0.0.0.0/0`.

---

## Key security decisions

- **No EC2 instance has a public IP**. All are in private subnets. Egress-only internet access goes through the NAT Gateway.
- **Security Groups reference other Security Groups as sources**, not IP ranges. This means rules automatically update when instances are replaced — no manual IP management.
- **RDS port 3306 is open to `backend-sg` only** — no other service can reach the database, even within the VPC.
- **CloudWatch Agent uses IAM role auth** (instance profile) — no AWS credentials stored on any EC2.
- **Grafana, Prometheus, Alertmanager, and Tempo have zero public exposure** — accessible only via SSH tunnel through the bastion.