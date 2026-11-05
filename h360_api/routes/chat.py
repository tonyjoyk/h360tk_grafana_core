"""GET /chat/chips and POST /chat (stories 6.3 to 6.7, AD-30 to AD-32).

Read-only. Session, CSRF header and origin checks are the app's gate (as for /write/*), which
also writes the one access log line. Every query is a registry function, after
h360_access_allows has allowed the node (registry.resolve_place).

POST /chat answer: the AD-30 fields {mode, place, month, reasons, also_check, stock_line, nudge,
plan, honesty, links} plus the widget's optional `title` and `control_line`; a nudge may carry
`url` (a link) or `org_unit_id` (a follow-up about another place, from `visit_first`).
"""

from __future__ import annotations

import hashlib
import json
import threading
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from h360_api import ranker, registry, wording
from h360_api.auth import Actor, error_payload

router = APIRouter()

MSG_FORBIDDEN = "You do not have access to this place."
MSG_NOT_FOUND = "No place has this ID."
MSG_FAILED = "I couldn't get an answer. Your reports are not affected."
MSG_BAD_PLACE = "The place id must be digits."
MSG_BAD_MONTH = "The month must be the first day of a month, as YYYY-MM-01."
MSG_BAD_CHIP = "This question is not available for this place."
MSG_TOO_LONG = "Keep the question to 200 characters or fewer."

_clients: dict[str, Any] = {}
_clients_lock = threading.Lock()


def _error(code: str, message: str, status: int) -> JSONResponse:
    return JSONResponse(status_code=status, content=error_payload(code, message))


class _Refusal(Exception):
    def __init__(self, code: str, message: str, status: int) -> None:
        super().__init__(code)
        self.code, self.message, self.status = code, message, status


def _db(request: Request) -> registry.ChatDb:
    db = getattr(request.app.state, "chat_db", None)
    if db is None:
        db = registry.default_db(request.app.state.settings)
        request.app.state.chat_db = db
    return db


def _client_factory(request: Request):
    """Fakes in tests via app.state.claude_client_factory; one SDK client per key otherwise."""
    injected = getattr(request.app.state, "claude_client_factory", None)
    if injected is not None:
        return injected

    def factory(api_key: str):
        slot = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
        with _clients_lock:
            client = _clients.get(slot)
            if client is None:
                client = wording.make_claude_client(api_key)
                _clients[slot] = client
            return client

    return factory


def _mode(settings) -> str:
    return "claude" if settings.anthropic_api_key else "offline"


def _parse_common(org_value: object, month_value: object):
    org = registry.parse_org_unit(org_value)
    if org is False:
        raise _Refusal("bad_request", MSG_BAD_PLACE, 400)
    month = registry.parse_month(month_value)
    if month is False:
        raise _Refusal("bad_request", MSG_BAD_MONTH, 400)
    return org, month or registry.latest_completed_month()


def _scope(db, actor: Actor, org, month):
    fetch = registry.Fetcher(db, month)
    try:
        place = registry.resolve_place(db, fetch, actor, org)
    except registry.Forbidden:
        raise _Refusal("forbidden", MSG_FORBIDDEN, 403)
    except registry.NotFound:
        raise _Refusal("not_found", MSG_NOT_FOUND, 404)
    return fetch, place


def chips_body(db, settings, actor: Actor, org_value: object, month_value: object) -> dict:
    org, month = _parse_common(org_value, month_value)
    fetch, place = _scope(db, actor, org, month)
    live = registry.live_entries(db) if place.scope != "national" else frozenset()
    return {
        "scope": place.scope,
        "place": place.as_dict(),
        "month": month.isoformat(),
        "mode": _mode(settings),
        "chips": registry.chips_for(place.scope, live),
    }


def answer_body(db, settings, actor: Actor, payload: dict, client_factory) -> dict:
    org, month = _parse_common(payload.get("org_unit_id"), payload.get("reporting_month"))
    chip_id = payload.get("chip_id")
    text = payload.get("text")
    if chip_id is not None and not isinstance(chip_id, str):
        raise _Refusal("bad_request", MSG_BAD_CHIP, 400)
    if not chip_id:
        if not isinstance(text, str) or not text.strip():
            raise _Refusal("bad_request", wording.NO_MATCH, 400)
        if len(text) > registry.MAX_TEXT:
            raise _Refusal("bad_request", MSG_TOO_LONG, 400)
    fetch, place = _scope(db, actor, org, month)
    if place.scope == "national":
        return wording.national_answer(place.as_dict(), month.isoformat())
    live = registry.live_entries(db)
    if not chip_id:
        offered = [c["id"] for c in registry.chips_for(place.scope, live)]
        chip_id = registry.match_text(text, offered)
        if chip_id is None:
            raise _Refusal("bad_request", wording.NO_MATCH, 400)
    if not registry.answerable(chip_id, place.scope, live):
        raise _Refusal("bad_request", MSG_BAD_CHIP, 400)
    facts = ranker.build_facts(chip_id, place, fetch, live)
    return wording.compose(facts, settings.anthropic_api_key, settings.anthropic_model, client_factory)


@router.get("/chat/chips")
async def chat_chips(request: Request) -> JSONResponse:
    actor: Actor = request.state.actor
    params = request.query_params
    try:
        body = await run_in_threadpool(
            chips_body, _db(request), request.app.state.settings, actor,
            params.get("org_unit_id"), params.get("reporting_month"),
        )
    except _Refusal as refusal:
        return _error(refusal.code, refusal.message, refusal.status)
    except Exception:
        # A database message can echo the call. Do not return or log it.
        return _error("bad_request", MSG_FAILED, 500)
    return JSONResponse(status_code=200, content=body)


@router.post("/chat")
async def chat(request: Request) -> JSONResponse:
    actor: Actor = request.state.actor
    try:
        payload = json.loads(await request.body())
    except (json.JSONDecodeError, UnicodeError):
        return _error("bad_request", "The request body is not valid JSON.", 400)
    if not isinstance(payload, dict):
        return _error("bad_request", "The request body must be a JSON object.", 400)
    try:
        body = await run_in_threadpool(
            answer_body, _db(request), request.app.state.settings, actor, payload, _client_factory(request)
        )
    except _Refusal as refusal:
        return _error(refusal.code, refusal.message, refusal.status)
    except Exception:
        return _error("bad_request", MSG_FAILED, 500)
    return JSONResponse(status_code=200, content=body)
