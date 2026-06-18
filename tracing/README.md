# Distributed Tracing

End-to-end distributed tracing using OpenTelemetry, Grafana Tempo, and Grafana.

## Pipeline

```
FastAPI request handler
        │
        ▼  (opentelemetry-instrumentation-fastapi — auto-instrumented)
OTel SDK (TraceProvider, BatchSpanProcessor)
        │  Span attributes: http.method, http.route, http.status_code,
        │  http.duration, db.statement (from SQLAlchemy instrumentation)
        ▼  (OTLP exporter — gRPC, port 4317, private VPC)
Grafana Tempo (Monitoring EC2, port 3200)
        │
        ▼  (Tempo data source in Grafana)
Grafana
  Explore → TraceQL queries
  Trace-to-logs correlation (via trace_id in log lines)
```

## What gets traced

| Span | Source | Key attributes |
|------|--------|----------------|
| HTTP request | FastAPI auto-instrumentation | `http.method`, `http.route`, `http.status_code`, duration |
| SQL query | SQLAlchemy auto-instrumentation | `db.statement`, `db.system`, duration |
| Custom spans | Manual `tracer.start_as_current_span()` | Application-specific attributes |

Every span carries a `trace_id` that is also injected into the application log line for that request, making it possible to jump from a trace directly to the corresponding logs in Grafana.

## Setup

### 1 — Install Python dependencies

Add to `app/backend/requirements.txt`:

```
opentelemetry-sdk
opentelemetry-api
opentelemetry-instrumentation-fastapi
opentelemetry-instrumentation-sqlalchemy
opentelemetry-exporter-otlp-proto-grpc
```

### 2 — Instrument the FastAPI app

In `main.py`, import and call `configure_tracing` at startup:

```python
from otel_config import configure_tracing

app = FastAPI(title="AWS Observability Demo API")

configure_tracing(app, engine=engine)
```

Set the environment variable on the backend EC2:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=<MONITORING_EC2_PRIVATE_IP>:4317
```

### 3 — Install and start Grafana Tempo

On the Monitoring EC2:

```bash
# Download Tempo
TEMPO_VERSION="2.4.1"
wget https://github.com/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_linux_amd64.tar.gz
tar -xzf tempo_${TEMPO_VERSION}_linux_amd64.tar.gz

# Create directories
sudo mkdir -p /var/lib/tempo/{traces,wal,generator/wal}
sudo mkdir -p /etc/tempo

# Install binary and config
sudo cp tempo /usr/local/bin/
sudo cp tempo-config.yaml /etc/tempo/tempo.yaml

# Create systemd service
sudo tee /etc/systemd/system/tempo.service <<EOF
[Unit]
Description=Grafana Tempo
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/tempo -config.file=/etc/tempo/tempo.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tempo
sudo systemctl start tempo

# Verify
curl http://localhost:3200/ready
```

### 4 — Add Tempo as a Grafana data source

In Grafana → Connections → Add data source → Tempo:

- **URL**: `http://localhost:3200`
- **Trace to logs**: Enable, set data source to your log source, use `{trace_id="$__trace.traceId"}` as the log query

### 5 — Verify traces are flowing

```bash
# Confirm Tempo is receiving spans
curl http://localhost:3200/api/search?limit=5 | python3 -m json.tool

# Generate a test trace by hitting the FastAPI endpoint
curl http://<BACKEND_PRIVATE_IP>:8000/users

# In Grafana → Explore → select Tempo data source
# Search: { .http.route = "/users" }
```

## TraceQL query examples

```
# All requests to /users slower than 200ms
{ .http.route = "/users" && duration > 200ms }

# All 5xx errors in the last 15 minutes
{ .http.status_code >= 500 }

# All database queries slower than 100ms
{ span.db.system = "mysql" && duration > 100ms }

# Traces for a specific user ID
{ .user.id = "42" }
```

## Security group note

The Monitoring EC2 security group must allow inbound TCP 4317 (OTLP gRPC) **from the Backend EC2 security group only**. No public access.