"""Chat registry (story 6.3, AD-30, EP-5, PD-12).

The chat answers only from the stored functions named here. Each function takes exactly
(reporting_month, org_unit_id). Chips are listed only when every function they need is live:
a function whose comment carries `h360:stub` (PD-2), or that is missing or not executable by
h360_api, hides its chips.

Database access goes through a `ChatDb` (PgChatDb in the service, a fake in tests). PgChatDb
runs three statements only: h360_access_allows, one registry function by whitelisted name, and
a read of the registry functions' comments in pg_catalog (EP-5 stub check).
"""

from __future__ import annotations

import datetime as dt
import json
import re
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol

from h360_api.auth import Actor

SCHEMA = "heart360tk_schema"
STUB_MARK = "h360:stub"
FACILITY_LEVEL = 3
DISTRICT_LEVEL = 2
MAX_TEXT = 200
STUB_CACHE_SECONDS = 60.0


@dataclass(frozen=True)
class Entry:
    function: str
    note: str


# AD-30 entries, keyed by PRD query name. `first_appointment_gap` is Deferred and absent.
REGISTRY: dict[str, Entry] = {
    "control_summary": Entry("chat_control_summary", "HTN tab control for the place and its facilities"),
    "new_patient_return": Entry("report_new_patients", "new patients who did not come back (new_loss_pct)"),
    "phone_capture": Entry("report_new_patients", "new patients with a usable phone (new_usable_phone_pct)"),
    "overdue_calling": Entry("report_calling", "overdue patients called, and called early"),
    "titration_rate": Entry("report_titration", "high BP visits where medicine was stepped up"),
    "fudging_score": Entry("report_fudging", "readings just under 140 against just over"),
    "statin_gap": Entry("report_statins", "eligible patients not on a statin"),
    "drug_stock_gate": Entry("chat_drug_stock_gate", "Patient-Days per protocol stock category"),
    "facility_rank_district": Entry("chat_facility_rank_district", "district facilities by uncontrolled patients"),
    "call_plan": Entry("chat_call_plan", "overdue patients with a phone over four weeks"),
    # Story 7.9 (UX-06, UX-10, UX-25): the Reports tabs' established forms. Optional: no chip needs
    # them; when one is a stub or missing, the answer falls back to the entries above.
    "titration_monthly": Entry("report_titration_monthly", "titration by month with the network average"),
    "statins_monthly": Entry("report_statins_monthly", "statins by month with the network average"),
    "fudging_quarterly": Entry("report_fudging_quarterly", "readings 130-139 against 140-149 by quarter"),
    "calling_return": Entry("report_calling_return", "called patients who came back, one fixed window (UX-11)"),
}

REGISTRY_FUNCTIONS: frozenset[str] = frozenset(e.function for e in REGISTRY.values())


@dataclass(frozen=True)
class Chip:
    id: str
    label: str
    needs: tuple[str, ...]


# Labels are exactly the UX chip table (EXPERIENCE.md, Chat chips).
CHIPS: dict[str, Chip] = {
    "why_control_low": Chip("why_control_low", "Why is my BP control low?", ("control_summary",)),
    "who_to_call": Chip("who_to_call", "Who should I call this week?", ("call_plan", "overdue_calling")),
    "medicines_adjusted": Chip("medicines_adjusted", "Are medicines being adjusted?", ("titration_rate",)),
    "readings_reliable": Chip("readings_reliable", "Are my BP readings reliable?", ("fudging_score",)),
    "statin_gap": Chip("statin_gap", "Who needs a statin?", ("statin_gap",)),
    "visit_first": Chip(
        "visit_first", "Which facilities should I visit first?", ("facility_rank_district", "control_summary")
    ),
}
PICK_DISTRICT = {"id": "pick_district", "label": "Pick a district"}

# Follow-up questions reached from a nudge, not shown as chips.
FOLLOW_UPS: dict[str, tuple[str, ...]] = {
    "call_plan": ("call_plan", "overdue_calling"),
}

FACILITY_CHIPS = ("why_control_low", "who_to_call", "medicines_adjusted", "readings_reliable", "statin_gap")
# District: the first facility chip, visit_first, then the four facility chips after the first (6.7).
DISTRICT_CHIPS = ("why_control_low", "visit_first") + FACILITY_CHIPS[1:]

# Typed text -> chip. Each hit scores one point; ties go to the chip listed first for the scope.
KEYWORDS: dict[str, tuple[str, ...]] = {
    "why_control_low": ("control", "controlled", "uncontrolled", "low", "why", "worse", "bad"),
    "who_to_call": ("call", "calls", "calling", "phone", "overdue", "this week", "who should i call"),
    "medicines_adjusted": ("medicine", "medicines", "medication", "step up", "stepped", "adjust", "dose", "titrat"),
    "readings_reliable": ("reading", "readings", "reliable", "rounding", "rounded", "measure", "bunch", "accurate"),
    "statin_gap": ("statin", "statins", "cholesterol"),
    "visit_first": ("visit first", "which facilit", "facilities", "visit", "where should i go"),
}


class ChatDb(Protocol):
    def allows(self, actor: Actor, org_unit_id: int | None) -> bool: ...

    def call(self, function: str, month: dt.date, org_unit_id: int | None) -> list[dict]: ...

    def live_functions(self, functions: frozenset[str]) -> frozenset[str]: ...


class Forbidden(Exception):
    """h360_access_allows refused the node."""


class NotFound(Exception):
    """No org unit has this id."""


# ---------------------------------------------------------------------------- request parsing

_MONTH = re.compile(r"^\d{4}-\d{2}-01$")
_INT_MAX = 2147483647


def latest_completed_month(today: dt.date | None = None) -> dt.date:
    """First day of the month before today (report_window's NULL rule)."""
    today = today or dt.date.today()
    first = today.replace(day=1)
    return (first - dt.timedelta(days=1)).replace(day=1)


def parse_month(value: object) -> dt.date | None | bool:
    """None for missing, a date for YYYY-MM-01, False for anything else."""
    if value is None or value == "":
        return None
    if not isinstance(value, str) or not _MONTH.match(value):
        return False
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        return False


def parse_org_unit(value: object) -> int | None | bool:
    """None for national (missing, empty or 0), an int id, False for anything else."""
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        number = value
    elif isinstance(value, str) and value.isdigit():
        number = int(value)
    else:
        return False
    if number < 0 or number > _INT_MAX:
        return False
    return number or None


# ---------------------------------------------------------------------------- per-request fetch


class Fetcher:
    """Runs registry entries for one month, caching each (function, node) for the request."""

    def __init__(self, db: ChatDb, month: dt.date) -> None:
        self.db = db
        self.month = month
        self._cache: dict[tuple[str, int | None], list[dict]] = {}
        self._months: dict[dt.date, Fetcher] = {month: self}

    def at(self, month: dt.date) -> Fetcher:
        """The same registry functions for another month (the overlay series, UX-10).

        Access was checked for the node before the first query; the month is the only change.
        """
        other = self._months.get(month)
        if other is None:
            other = Fetcher(self.db, month)
            other._months = self._months
            self._months[month] = other
        return other

    def rows(self, key: str, org_unit_id: int | None) -> list[dict]:
        entry = REGISTRY[key]  # KeyError: not a registry entry, never run
        cache_key = (entry.function, org_unit_id)
        if cache_key not in self._cache:
            self._cache[cache_key] = list(self.db.call(entry.function, self.month, org_unit_id))
        return self._cache[cache_key]

    def selected(self, key: str, org_unit_id: int | None) -> dict | None:
        for row in self.rows(key, org_unit_id):
            if row.get("is_selected") is True:
                return row
        return None

    def facilities(self, key: str, org_unit_id: int | None) -> list[dict]:
        return [r for r in self.rows(key, org_unit_id) if not r.get("is_selected")]


# ---------------------------------------------------------------------------- scope


@dataclass
class Place:
    org_unit_id: int | None
    name: str
    level: int
    scope: str  # facility | district | national

    def as_dict(self) -> dict:
        return {"org_unit_id": self.org_unit_id, "name": self.name, "level": self.level, "scope": self.scope}


NATIONAL_NAME = "All places"


def resolve_place(db: ChatDb, fetch: Fetcher, actor: Actor, org_unit_id: int | None) -> Place:
    """AD-30 scope. Access is checked for the node before any query, then for the scope node."""
    if org_unit_id is None:
        # No node, no query: the only answer is `Pick a district`.
        return Place(None, NATIONAL_NAME, 0, "national")
    if not db.allows(actor, org_unit_id):
        raise Forbidden()
    row = fetch.selected("control_summary", org_unit_id)
    if row is None:
        raise NotFound()
    level = int(row.get("level") or 0)
    name = str(row.get("org_unit_name") or "")
    if level <= 1:
        return Place(org_unit_id, name, level, "national")
    if level == DISTRICT_LEVEL:
        return Place(org_unit_id, name, level, "district")
    if level == FACILITY_LEVEL:
        return Place(org_unit_id, name, level, "facility")
    # Below facility: answer for the level-3 ancestor. chat_drug_stock_gate reports the place it used,
    # which is the facility ancestor for a node below facility level (0.6.13_to_0.6.14).
    ancestor = None
    for stock in fetch.rows("drug_stock_gate", org_unit_id):
        if stock.get("org_unit_id") is not None:
            ancestor = int(stock["org_unit_id"])
            break
    if ancestor is None or ancestor == org_unit_id:
        return Place(org_unit_id, name, level, "facility")
    if not db.allows(actor, ancestor):
        raise Forbidden()
    arow = fetch.selected("control_summary", ancestor)
    if arow is None:
        raise NotFound()
    return Place(ancestor, str(arow.get("org_unit_name") or ""), int(arow.get("level") or FACILITY_LEVEL), "facility")


# ---------------------------------------------------------------------------- chips

_stub_lock = threading.Lock()
_stub_cache: dict[int, tuple[float, frozenset[str]]] = {}


def live_entries(db: ChatDb, now: Callable[[], float] = time.monotonic) -> frozenset[str]:
    """Registry keys whose function is live (not a stub, present, executable). Cached briefly."""
    key = id(db)
    with _stub_lock:
        hit = _stub_cache.get(key)
        if hit is not None and now() - hit[0] < STUB_CACHE_SECONDS:
            live_fns = hit[1]
        else:
            live_fns = frozenset(db.live_functions(REGISTRY_FUNCTIONS))
            _stub_cache[key] = (now(), live_fns)
    return frozenset(k for k, e in REGISTRY.items() if e.function in live_fns)


def clear_stub_cache() -> None:
    with _stub_lock:
        _stub_cache.clear()


def chip_live(chip_id: str, live: frozenset[str]) -> bool:
    needs = CHIPS[chip_id].needs if chip_id in CHIPS else FOLLOW_UPS.get(chip_id)
    return needs is not None and all(n in live for n in needs)


def chips_for(scope: str, live: frozenset[str]) -> list[dict]:
    if scope == "national":
        return [dict(PICK_DISTRICT)]
    order = DISTRICT_CHIPS if scope == "district" else FACILITY_CHIPS
    return [{"id": c, "label": CHIPS[c].label} for c in order if chip_live(c, live)][:6]


def answerable(chip_id: str, scope: str, live: frozenset[str]) -> bool:
    if scope == "national":
        return False
    if chip_id in FOLLOW_UPS:
        return chip_live(chip_id, live)
    return any(c["id"] == chip_id for c in chips_for(scope, live))


def match_text(text: str, chip_ids: list[str]) -> str | None:
    """Keyword table: the chip with the most hits among those offered, else None."""
    words = " " + re.sub(r"[^a-z0-9 ]+", " ", text.lower()) + " "
    best, best_score = None, 0
    for chip_id in chip_ids:
        score = 0
        for kw in KEYWORDS.get(chip_id, ()):
            if (" " + kw) in words:  # word-start match; "titrat" matches "titration"
                score += 1
        if score > best_score:
            best, best_score = chip_id, score
    return best


# ---------------------------------------------------------------------------- Postgres


class PgChatDb:
    """psycopg implementation. Only registry functions, h360_access_allows and the stub check."""

    _ALLOWS_SQL = (
        "SELECT heart360tk_schema.h360_access_allows("
        "%s::boolean, ARRAY(SELECT jsonb_array_elements_text(%s::jsonb)), %s::integer)"
    )
    _LIVE_SQL = (
        "SELECT p.proname FROM pg_catalog.pg_proc p "
        "JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = %s AND p.proname = ANY(%s) "
        "AND has_function_privilege(p.oid, 'EXECUTE') "
        "AND position(%s in COALESCE(pg_catalog.obj_description(p.oid, 'pg_proc'), '')) = 0"
    )

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url

    def _pool(self):
        from h360_api.routes.write import _pool

        return _pool(self.database_url)

    def allows(self, actor: Actor, org_unit_id: int | None) -> bool:
        with self._pool().connection() as conn:
            row = conn.execute(
                self._ALLOWS_SQL, (actor.is_admin, json.dumps(list(actor.teams)), org_unit_id)
            ).fetchone()
        return bool(row and row[0] is True)

    def call(self, function: str, month: dt.date, org_unit_id: int | None) -> list[dict]:
        if function not in REGISTRY_FUNCTIONS:
            raise ValueError("not a registry function")
        from psycopg import sql
        from psycopg.rows import dict_row

        query = sql.SQL("SELECT * FROM {}.{}(%s::date, %s::integer)").format(
            sql.Identifier(SCHEMA), sql.Identifier(function)
        )
        with self._pool().connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(query, (month, org_unit_id))
                return list(cur.fetchall())

    def live_functions(self, functions: frozenset[str]) -> frozenset[str]:
        with self._pool().connection() as conn:
            rows = conn.execute(self._LIVE_SQL, (SCHEMA, sorted(functions), STUB_MARK)).fetchall()
        return frozenset(r[0] for r in rows)


def default_db(settings: Any) -> PgChatDb:
    return PgChatDb(settings.database_url)
