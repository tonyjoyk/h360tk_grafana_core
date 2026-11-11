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

from h360_api.auth import Actor
from h360_api.config import Settings
from h360_api.registry import parse_month, parse_org_unit
from h360_api.routes.write import _json_error, _pool, read_json_object, sql_result_response

router = APIRouter()

MAX_STOCK = 1_000_000
MAX_ENTRIES = 100
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
    payload = await read_json_object(request)
    if isinstance(payload, JSONResponse):
        return payload

    org_unit_id = parse_org_unit(payload.get("org_unit_id"))
    if not org_unit_id:  # None (missing, empty or 0) or False (not digits)
        return _json_error("bad_request", "The place id must be digits.", 400)
    month = parse_month(payload.get("month"))
    if not month:  # None (missing) or False (not YYYY-MM-01)
        return _json_error("bad_request", "The month must look like 2026-11-01.", 400)
    entries = parse_entries(payload.get("entries"))
    if entries is None:
        return _json_error(
            "bad_request",
            "Each stock must be a whole number from 0 to 1,000,000, or blank.",
            400,
        )

    try:
        result = _writer(request)(actor, actor.email, org_unit_id, month, entries)
    except Exception:
        # The database message can echo the call. Do not return or log it.
        result = None
    return sql_result_response(result, _SQL_STATUS, "The stock could not be saved. Try again.")
