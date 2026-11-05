"""POST /write/call-result. The only runtime write: save_call_result as the session's actor."""

from __future__ import annotations

import json
import threading
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from h360_api.auth import Actor, error_payload
from h360_api.config import Settings

router = APIRouter()

# SQL codes from save_call_result. bad_status is an unknown overdue-list string.
_SQL_STATUS = {
    "bad_request": 400,
    "bad_status": 400,
    "forbidden": 403,
    "not_found": 404,
}

_BIGINT_MAX = 9223372036854775807

_SAVE_SQL = """
SELECT save_call_result(
    %s::text,
    %s::bigint,
    %s::boolean,
    ARRAY(SELECT jsonb_array_elements_text(%s::jsonb)),
    %s::bigint,
    %s::text
) AS result
"""

_pools: dict[str, Any] = {}
_pools_lock = threading.Lock()


def _pool(database_url: str):
    import psycopg
    from psycopg_pool import ConnectionPool

    with _pools_lock:
        pool = _pools.get(database_url)
        if pool is None:
            pool = ConnectionPool(
                database_url,
                kwargs={"autocommit": True},
                min_size=1,
                max_size=4,
                open=True,
                connection_class=psycopg.Connection,
            )
            _pools[database_url] = pool
        return pool


def execute_save(settings: Settings, actor: Actor, patient_id: int, status: str) -> dict:
    """Call save_call_result. Team names travel as JSON so an empty list stays text[]."""
    with _pool(settings.database_url).connection() as conn:
        row = conn.execute(
            _SAVE_SQL,
            (
                actor.login,
                actor.actor_id,
                actor.is_admin,
                json.dumps(list(actor.teams)),
                patient_id,
                status,
            ),
        ).fetchone()
    result = row[0] if row is not None else None
    if isinstance(result, str):
        result = json.loads(result)
    if not isinstance(result, dict):
        raise RuntimeError("save_call_result did not return an object")
    return result


def parse_patient_id(value: object) -> int | None:
    """Digits only: a non-negative integer, or a string of digits. No signs or spaces."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        number = value
    elif isinstance(value, str) and value.isdigit():
        number = int(value)
    else:
        return None
    if number < 0 or number > _BIGINT_MAX:
        return None
    return number


def _json_error(code: str, message: str, status: int) -> JSONResponse:
    return JSONResponse(status_code=status, content=error_payload(code, message))


@router.post("/write/call-result")
async def write_call_result(request: Request) -> JSONResponse:
    actor: Actor = request.state.actor
    try:
        payload = json.loads(await request.body())
    except (json.JSONDecodeError, UnicodeError):
        return _json_error("bad_request", "The request body is not valid JSON.", 400)
    if not isinstance(payload, dict):
        return _json_error("bad_request", "The request body must be a JSON object.", 400)

    patient_id = parse_patient_id(payload.get("patient_id"))
    status = payload.get("status")
    if patient_id is None:
        return _json_error("bad_request", "The patient id must be digits.", 400)
    if not isinstance(status, str):
        return _json_error("bad_request", "The call result must be text.", 400)

    try:
        result = request.app.state.writer(actor, patient_id, status)
    except Exception:
        # The database message can echo the call. Do not return or log it.
        return _json_error("bad_request", "The save could not be recorded. Try again.", 500)

    if not isinstance(result, dict):
        return _json_error("bad_request", "The save could not be recorded. Try again.", 500)
    if result.get("ok") is True:
        return JSONResponse(status_code=200, content=result)
    code = result.get("error")
    status_code = _SQL_STATUS.get(code, 400)
    message = result.get("message")
    if not isinstance(message, str) or not message.strip():
        message = "The save was refused."
    body = dict(result)
    body["ok"] = False
    body["message"] = message
    if not isinstance(code, str):
        body["error"] = "bad_request"
    return JSONResponse(status_code=status_code, content=body)
