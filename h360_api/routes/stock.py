"""POST /write/drug-stock. The Drug Stock board's Enter stock form: save_drug_stock_entry as the
session's actor (story 3.5, AD-16). Session, CSRF header and origin checks are the app's gate, as
for /write/call-result; the gate also writes the one access log line.
"""

from __future__ import annotations

import datetime as dt
import json
import re

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from h360_api.auth import Actor, error_payload
from h360_api.config import Settings
from h360_api.routes.write import _pool

router = APIRouter()

MAX_STOCK = 1_000_000
MAX_ENTRIES = 100
_INT_MAX = 2147483647
_MONTH = re.compile(r"^\d{4}-\d{2}-01$")
# protocol_drugs.rxnorm_code, varchar(64).
_DRUG_CODE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

# SQL codes from save_drug_stock_entry.
_SQL_STATUS = {
    "bad_request": 400,
    "bad_month": 400,
    "not_facility": 400,
    "forbidden": 403,
    "not_found": 404,
}

_SAVE_SQL = """
SELECT heart360tk_schema.save_drug_stock_entry(
    %s::text,
    %s::text,
    %s::boolean,
    ARRAY(SELECT jsonb_array_elements_text(%s::jsonb)),
    %s::integer,
    %s::date,
    %s::jsonb
) AS result
"""


def execute_stock_save(
    settings: Settings,
    actor: Actor,
    email: str | None,
    org_unit_id: int,
    month: dt.date,
    entries: list[dict],
) -> dict:
    """Call save_drug_stock_entry. Team names travel as JSON so an empty list stays text[]."""
    with _pool(settings.database_url).connection() as conn:
        row = conn.execute(
            _SAVE_SQL,
            (
                actor.login,
                email,
                actor.is_admin,
                json.dumps(list(actor.teams)),
                org_unit_id,
                month.isoformat(),
                json.dumps(entries),
            ),
        ).fetchone()
    result = row[0] if row is not None else None
    if isinstance(result, str):
        result = json.loads(result)
    if not isinstance(result, dict):
        raise RuntimeError("save_drug_stock_entry did not return an object")
    return result


def parse_org_unit_id(value: object) -> int | None:
    """A positive integer, or a string of digits, that fits a Postgres integer."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        number = value
    elif isinstance(value, str) and value.isdigit():
        number = int(value)
    else:
        return None
    if number < 1 or number > _INT_MAX:
        return None
    return number


def parse_month(value: object) -> dt.date | None:
    """`YYYY-MM-01` only."""
    if not isinstance(value, str) or not _MONTH.match(value):
        return None
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        return None


def parse_entries(value: object) -> list[dict] | None:
    """[{drug_code, stock}] with stock a whole number 0..1,000,000 or null (not counted)."""
    if not isinstance(value, list) or not value or len(value) > MAX_ENTRIES:
        return None
    entries: list[dict] = []
    for item in value:
        if not isinstance(item, dict):
            return None
        code = item.get("drug_code")
        if not isinstance(code, str) or not _DRUG_CODE.match(code):
            return None
        stock = item.get("stock")
        if stock is not None:
            if isinstance(stock, bool) or not isinstance(stock, int):
                return None
            if stock < 0 or stock > MAX_STOCK:
                return None
        entries.append({"drug_code": code, "stock": stock})
    return entries


def actor_email(request: Request, actor: Actor) -> str | None:
    """The Grafana email of the session's user, or None (SQL then records the login).

    Actor carries no email, so this asks Grafana /api/user once more with the same cookie.
    """
    email = getattr(actor, "email", None)
    if not email:
        directory = request.app.state.directory
        session = request.cookies.get("grafana_session", "")
        client_factory = getattr(directory, "_client", None)
        getter = getattr(directory, "_get", None)
        if not session or client_factory is None or getter is None:
            return None
        try:
            with client_factory() as client:
                res = getter(client, "/api/user", session)
            user = res.json() if res.status_code == 200 else None
        except Exception:
            return None
        if not isinstance(user, dict) or user.get("login") != actor.login:
            return None
        email = user.get("email")
    if not isinstance(email, str):
        return None
    email = email.strip()
    if not email or len(email) > 320 or any(ch in email for ch in "\r\n"):
        return None
    return email


def _json_error(code: str, message: str, status: int) -> JSONResponse:
    return JSONResponse(status_code=status, content=error_payload(code, message))


def _writer(request: Request):
    writer = getattr(request.app.state, "stock_writer", None)
    if writer is not None:
        return writer
    settings = request.app.state.settings
    return lambda actor, email, org_unit_id, month, entries: execute_stock_save(
        settings, actor, email, org_unit_id, month, entries
    )


@router.post("/write/drug-stock")
async def write_drug_stock(request: Request) -> JSONResponse:
    actor: Actor = request.state.actor
    try:
        payload = json.loads(await request.body())
    except (json.JSONDecodeError, UnicodeError):
        return _json_error("bad_request", "The request body is not valid JSON.", 400)
    if not isinstance(payload, dict):
        return _json_error("bad_request", "The request body must be a JSON object.", 400)

    org_unit_id = parse_org_unit_id(payload.get("org_unit_id"))
    if org_unit_id is None:
        return _json_error("bad_request", "The place id must be digits.", 400)
    month = parse_month(payload.get("month"))
    if month is None:
        return _json_error("bad_request", "The month must look like 2026-11-01.", 400)
    entries = parse_entries(payload.get("entries"))
    if entries is None:
        return _json_error(
            "bad_request",
            "Each stock must be a whole number from 0 to 1,000,000, or blank.",
            400,
        )

    email = actor_email(request, actor)
    try:
        result = _writer(request)(actor, email, org_unit_id, month, entries)
    except Exception:
        # The database message can echo the call. Do not return or log it.
        return _json_error("bad_request", "The stock could not be saved. Try again.", 500)

    if not isinstance(result, dict):
        return _json_error("bad_request", "The stock could not be saved. Try again.", 500)
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
