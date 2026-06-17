# VPC & Network Design

## Overview

The platform runs in a single VPC (`10.0.0.0/16`) spread across two Availability Zones. The design follows a strict public/private split — only the ALB is public-facing. All compute and data services are in private subnets with no direct internet exposure.

---

## Network layout

```
VPC: 10.0.0.0/16
│
├── Public Subnet AZ-a    10.0.1.0/24   (ALB, Bastion)
├── Public Subnet AZ-b    10.0.2.0/24   (ALB secondary AZ)
│
├── Private Subnet AZ-a   10.0.10.0/24  (Frontend EC2, Backend EC2)
├── Private Subnet AZ-b   10.0.11.0/24  (Monitoring EC2)
│
├── DB Subnet AZ-a        10.0.20.0/24  (RDS primary)
└── DB Subnet AZ-b        10.0.21.0/24  (RDS standby — Multi-AZ)
```

---

## Routing

| Subnet type | Route table | Default route | Notes |
|-------------|-------------|---------------|-------|
| Public | `public-rt` | `0.0.0.0/0 → igw` | ALB, Bastion; direct internet access |
| Private | `private-rt` | `0.0.0.0/0 → nat-gw` | EC2s use NAT for egress (package installs, CloudWatch API) |
| DB | `db-rt` | *(no default route)* | RDS has no internet egress; VPC local only |

---

## Key components

### Internet Gateway
Attached to the VPC. Used by the ALB (public subnet) to accept inbound traffic from the internet. Private subnets have no IGW route.

### NAT Gateway
Deployed in the public subnet (`10.0.1.0/24`). Allows EC2 instances in private subnets to initiate outbound connections (apt installs, CloudWatch HTTPS endpoint, PagerDuty webhooks from Alertmanager) without receiving unsolicited inbound connections.

### Application Load Balancer
Multi-AZ (public subnets AZ-a and AZ-b). Accepts HTTPS on port 443, terminates TLS, and forwards to:
- Frontend EC2 target group (port 80) — for UI requests
- Backend EC2 target group (port 8000) — for `/api/*` requests

### RDS DB Subnet Group
Spans both DB subnets (`10.0.20.0/24` and `10.0.21.0/24`). RDS uses Multi-AZ: primary in AZ-a, synchronous standby in AZ-b. Automatic failover if the primary AZ has an issue. The DB subnet route table has no default route — RDS cannot initiate any outbound internet connection.

---

## DNS

- ALB DNS name is registered as a CNAME in Route 53 (e.g. `observability.mnuman.online → alb-xyz.ap-south-1.elb.amazonaws.com`)
- All internal EC2-to-EC2 communication uses private IP addresses (resolved via VPC DNS at `10.0.0.2`)
- RDS endpoint (`observability-db.xxxx.ap-south-1.rds.amazonaws.com`) resolves to the private IP of the current primary

---

## VPC Flow Logs

VPC Flow Logs are enabled on the VPC and deliver to a CloudWatch Logs log group (`/aws/vpc/flowlogs`). This records all accepted and rejected traffic at the ENI level — useful for auditing unexpected connection attempts against private resources.