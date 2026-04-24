import json
import os
import logging
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

ENV = os.environ.get("ENV", "dev")


def ok(body: Any, status: int = 200) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "X-Environment": ENV,
        },
        "body": json.dumps(body, default=str),
    }


def err(status: int, message: str, details: Any = None) -> dict:
    payload = {"error": message}
    if details:
        payload["details"] = details
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def require_fields(body: dict, fields: list) -> list:
    return [f for f in fields if f not in body or body[f] is None]
