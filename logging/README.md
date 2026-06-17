# Logging Pipeline

Centralized log collection and long-term archival using CloudWatch Agent, CloudWatch Logs, EventBridge, Lambda, and Amazon S3.

## Pipeline

```
Backend EC2 (log files on disk)
        │
        ▼  (CloudWatch Agent — unified agent, daemon)
CloudWatch Logs
  Log group: /aws/ec2/observability-platform
  Log streams:
    {instance_id}/syslog
    {instance_id}/auth
    {instance_id}/fastapi-app
    {instance_id}/nginx-access
    {instance_id}/nginx-error
        │
        ▼  (EventBridge — scheduled rule, daily 02:00 UTC)
Lambda: export-cloudwatch-logs
  Creates a CloudWatch export task for the previous UTC day
        │
        ▼
Amazon S3: s3://observability-logs-archive/
  Prefix: year=YYYY/month=MM/day=DD/
```

## What gets collected

| Log stream | Source file | Contents |
|------------|-------------|----------|
| `{id}/syslog` | `/var/log/syslog` | OS-level events, kernel messages, service starts/stops |
| `{id}/auth` | `/var/log/auth.log` | SSH logins, sudo usage, authentication failures |
| `{id}/fastapi-app` | `/var/log/fastapi/app.log` | Application logs, request traces, errors |
| `{id}/nginx-access` | `/var/log/nginx/access.log` | Every inbound HTTP request (status, latency, bytes) |
| `{id}/nginx-error` | `/var/log/nginx/error.log` | Nginx errors, upstream failures |

## Setup

### 1 — Install CloudWatch Agent on the backend EC2

```bash
# Download the unified CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i amazon-cloudwatch-agent.deb

# Copy config
sudo cp cloudwatch-agent-config.json \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Start the agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

# Verify
sudo systemctl status amazon-cloudwatch-agent
```

> The EC2 instance must have the `CloudWatchAgentServerPolicy` IAM policy attached via its instance profile — no credentials stored on disk.

### 2 — Create the S3 bucket

```bash
aws s3api create-bucket \
  --bucket observability-logs-archive \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1

# Block all public access
aws s3api put-public-access-block \
  --bucket observability-logs-archive \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Lifecycle policy: move to Glacier after 90 days, delete after 365
aws s3api put-bucket-lifecycle-configuration \
  --bucket observability-logs-archive \
  --lifecycle-configuration file://s3-lifecycle.json
```

CloudWatch Logs requires the bucket to grant it `s3:GetBucketAcl` and `s3:PutObject`. Attach the following bucket policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "logs.amazonaws.com" },
      "Action": ["s3:GetBucketAcl", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::observability-logs-archive",
        "arn:aws:s3:::observability-logs-archive/*"
      ]
    }
  ]
}
```

### 3 — Deploy the Lambda function

```bash
# Package
zip lambda-export-logs.zip lambda-export-logs.py

# Deploy
aws lambda create-function \
  --function-name export-cloudwatch-logs \
  --runtime python3.12 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/lambda-log-export-role \
  --handler lambda-export-logs.lambda_handler \
  --zip-file fileb://lambda-export-logs.zip \
  --timeout 600 \
  --environment Variables="{
    LOG_GROUP_NAME=/aws/ec2/observability-platform,
    S3_BUCKET_NAME=observability-logs-archive
  }"
```

### 4 — Create the EventBridge rule

```bash
aws events put-rule \
  --name observability-log-export-daily \
  --schedule-expression "cron(0 2 * * ? *)" \
  --state ENABLED

aws events put-targets \
  --rule observability-log-export-daily \
  --targets "Id=1,Arn=<LAMBDA_ARN>"

aws lambda add-permission \
  --function-name export-cloudwatch-logs \
  --statement-id allow-eventbridge \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn <EVENTBRIDGE_RULE_ARN>
```

## IAM roles

### EC2 instance profile

Policy: `arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy`

Grants the CloudWatch Agent running on EC2 permission to publish logs to CloudWatch without storing any credentials on disk.

### Lambda execution role (`lambda-log-export-role`)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateExportTask",
        "logs:DescribeExportTasks",
        "logs:DescribeLogGroups"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/ec2/observability-platform:*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetBucketAcl"],
      "Resource": [
        "arn:aws:s3:::observability-logs-archive",
        "arn:aws:s3:::observability-logs-archive/*"
      ]
    }
  ]
}
```

## Verification

After setup, verify the pipeline end-to-end:

```bash
# On the EC2 — confirm agent is running and sending
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status

# In AWS Console — confirm log streams are appearing
aws logs describe-log-streams \
  --log-group-name /aws/ec2/observability-platform \
  --order-by LastEventTime \
  --descending

# Manually trigger the Lambda to test export
aws lambda invoke \
  --function-name export-cloudwatch-logs \
  --payload '{}' \
  response.json && cat response.json

# Confirm logs landed in S3
aws s3 ls s3://observability-logs-archive/ --recursive
```