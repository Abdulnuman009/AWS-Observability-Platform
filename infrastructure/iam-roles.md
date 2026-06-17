# IAM Roles & Policies

The platform uses two IAM roles, following the principle of least privilege. No AWS credentials are stored on any EC2 instance — all authentication is handled via instance profiles and execution roles.

---

## `ec2-observability-role` — EC2 Instance Profile

Attached to the **Backend EC2** instance profile. Grants the CloudWatch Agent running on the instance permission to publish log data to CloudWatch without any credentials stored on disk.

### Managed policy

```
arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
```

This AWS-managed policy grants:
- `cloudwatch:PutMetricData`
- `logs:CreateLogGroup`
- `logs:CreateLogStream`
- `logs:PutLogEvents`
- `logs:DescribeLogStreams`
- `ec2:DescribeVolumes`, `ec2:DescribeTags` (for instance metadata in log streams)

### How to attach

```bash
# Create the role
aws iam create-role \
  --role-name ec2-observability-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach managed policy
aws iam attach-role-policy \
  --role-name ec2-observability-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

# Create instance profile and attach role
aws iam create-instance-profile \
  --instance-profile-name ec2-observability-profile

aws iam add-role-to-instance-profile \
  --instance-profile-name ec2-observability-profile \
  --role-name ec2-observability-role

# Attach to the EC2 instance
aws ec2 associate-iam-instance-profile \
  --instance-id <BACKEND_EC2_INSTANCE_ID> \
  --iam-instance-profile Name=ec2-observability-profile
```

---

## `lambda-log-export-role` — Lambda Execution Role

Attached to the **export-cloudwatch-logs** Lambda function. Grants minimum permissions to create a CloudWatch export task and write output to the archive S3 bucket.

### Inline policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogsExport",
      "Effect": "Allow",
      "Action": [
        "logs:CreateExportTask",
        "logs:DescribeExportTasks",
        "logs:DescribeLogGroups"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/ec2/observability-platform:*"
    },
    {
      "Sid": "S3Archive",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetBucketAcl"
      ],
      "Resource": [
        "arn:aws:s3:::observability-logs-archive",
        "arn:aws:s3:::observability-logs-archive/*"
      ]
    }
  ]
}
```

The Lambda also needs the basic execution role for CloudWatch Logs (writing Lambda invocation logs):

```
arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

### How to create

```bash
# Trust policy for Lambda
cat > lambda-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lambda-log-export-role \
  --assume-role-policy-document file://lambda-trust-policy.json

# Attach managed execution policy
aws iam attach-role-policy \
  --role-name lambda-log-export-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Create and attach the inline policy
aws iam put-role-policy \
  --role-name lambda-log-export-role \
  --policy-name log-export-s3-policy \
  --policy-document file://lambda-inline-policy.json
```

---

## Why no credentials are stored on EC2

Both roles are assumed automatically:
- The EC2 instance profile is retrieved by the CloudWatch Agent from the EC2 metadata endpoint (`169.254.169.254/latest/meta-data/iam/`) — credentials rotate automatically every few hours
- The Lambda execution role is provided by the Lambda runtime at invocation time

This eliminates the risk of long-lived AWS credentials being leaked from an EC2 instance.