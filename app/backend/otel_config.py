"""
OpenTelemetry instrumentation for the FastAPI backend.
Instruments all incoming HTTP requests and SQLAlchemy DB calls,
exports spans to Grafana Tempo via OTLP over gRPC.

Install dependencies (add to requirements.txt):
    opentelemetry-sdk
    opentelemetry-api
    opentelemetry-instrumentation-fastapi
    opentelemetry-instrumentation-sqlalchemy
    opentelemetry-exporter-otlp-proto-grpc

Environment variable:
    OTEL_EXPORTER_OTLP_ENDPOINT - gRPC endpoint for Tempo (default: localhost:4317)
"""

import os
import logging

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

logger = logging.getLogger(__name__)

OTEL_ENDPOINT = os.getenv(
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "localhost:4317",
)


def configure_tracing(app, engine=None):
    """
    Call once at application startup, before any requests are served.

    Args:
        app:    The FastAPI application instance.
        engine: Optional SQLAlchemy engine — if provided, all SQL
                queries will be traced as child spans.
    """
    resource = Resource.create(
        attributes={
            "service.name": "observability-backend",
            "service.version": "1.0.0",
            "deployment.environment": os.getenv("APP_ENV", "production"),
        }
    )

    exporter = OTLPSpanExporter(
        endpoint=OTEL_ENDPOINT,
        insecure=True,  # TLS terminated at ALB; internal traffic is private VPC
    )

    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    # Auto-instrument all FastAPI routes (creates a span per request,
    # records HTTP method, route, status code, and response time)
    FastAPIInstrumentor.instrument_app(app)

    # Auto-instrument SQLAlchemy (adds DB query spans as children of
    # the parent request span — makes slow queries immediately visible)
    if engine is not None:
        SQLAlchemyInstrumentor().instrument(engine=engine)

    logger.info(
        "OpenTelemetry tracing configured | endpoint=%s | service=observability-backend",
        OTEL_ENDPOINT,
    )


def get_tracer(name: str = "observability-backend"):
    """
    Returns a tracer for creating manual spans in application code.

    Usage:
        tracer = get_tracer()
        with tracer.start_as_current_span("my-operation") as span:
            span.set_attribute("user.id", user_id)
            # ... do work
    """
    return trace.get_tracer(name)