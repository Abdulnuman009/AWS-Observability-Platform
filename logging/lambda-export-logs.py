"""
Lambda function: export-cloudwatch-logs
Triggered by EventBridge on a daily schedule (02:00 UTC).
Creates a CloudWatch Logs export task that writes the previous day's
logs to s3://observability-logs-archive/ in a partitioned prefix.

Required environment variables (set in Lambda config):
    LOG_GROUP_NAME  - CloudWatch Logs group to export
    S3_BUCKET_NAME  - Destination S3 bucket

IAM permissions required on the Lambda execution role:
    logs:CreateExportTask
    logs:DescribeExportTasks
    s3:PutObject
    s3:GetBucketAcl (CloudWatch Logs requires this on the destination bucket)
"""

import os
import time
import logging
from datetime import datetime, timezone, timedelta

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

LOG_GROUP_NAME = os.environ["LOG_GROUP_NAME"]
S3_BUCKET_NAME = os.environ["S3_BUCKET_NAME"]

logs_client = boto3.client("logs")


def lambda_handler(event, context):
    """
    Entry point. Calculates the previous UTC day window, creates an export
    task, then polls until the task reaches a terminal state.
    """
    now_utc = datetime.now(timezone.utc)

    # Export window: full previous UTC day
    end_of_yesterday = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
    start_of_yesterday = end_of_yesterday - timedelta(days=1)

    # Epoch milliseconds required by CloudWatch Logs API
    from_time = int(start_of_yesterday.timestamp() * 1000)
    to_time = int(end_of_yesterday.timestamp() * 1000) - 1

    # S3 key prefix: year=YYYY/month=MM/day=DD/
    s3_prefix = (
        f"year={start_of_yesterday.year:04d}/"
        f"month={start_of_yesterday.month:02d}/"
        f"day={start_of_yesterday.day:02d}"
    )

    task_name = (
        f"export-{start_of_yesterday.strftime('%Y-%m-%d')}"
        f"-{int(time.time())}"
    )

    logger.info(
        "Starting export task | log_group=%s | window=%s → %s | s3=%s/%s",
        LOG_GROUP_NAME,
        start_of_yesterday.isoformat(),
        end_of_yesterday.isoformat(),
        S3_BUCKET_NAME,
        s3_prefix,
    )

    response = logs_client.create_export_task(
        taskName=task_name,
        logGroupName=LOG_GROUP_NAME,
        fromTime=from_time,
        to=to_time,
        destination=S3_BUCKET_NAME,
        destinationPrefix=s3_prefix,
    )

    task_id = response["taskId"]
    logger.info("Export task created | task_id=%s", task_id)

    # Poll until terminal state (COMPLETED / FAILED / CANCELLED)
    status = _wait_for_export(task_id)

    if status != "COMPLETED":
        raise RuntimeError(f"Export task {task_id} ended with status: {status}")

    logger.info(
        "Export completed successfully | task_id=%s | s3_prefix=%s",
        task_id,
        s3_prefix,
    )

    return {
        "taskId": task_id,
        "status": status,
        "logGroup": LOG_GROUP_NAME,
        "s3Prefix": s3_prefix,
        "window": {
            "start": start_of_yesterday.isoformat(),
            "end": end_of_yesterday.isoformat(),
        },
    }


def _wait_for_export(task_id: str, max_wait_seconds: int = 600) -> str:
    """
    Poll CloudWatch Logs until the export task reaches a terminal state.
    Returns the final status string.
    """
    terminal_states = {"COMPLETED", "FAILED", "CANCELLED"}
    poll_interval = 15  # seconds
    elapsed = 0

    while elapsed < max_wait_seconds:
        response = logs_client.describe_export_tasks(taskId=task_id)
        tasks = response.get("exportTasks", [])

        if not tasks:
            raise RuntimeError(f"No export task found for task_id={task_id}")

        status_code = tasks[0]["status"]["code"]
        logger.info("Export task status | task_id=%s | status=%s", task_id, status_code)

        if status_code in terminal_states:
            return status_code

        time.sleep(poll_interval)
        elapsed += poll_interval

    raise TimeoutError(
        f"Export task {task_id} did not complete within {max_wait_seconds}s"
    )