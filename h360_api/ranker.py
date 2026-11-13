"""Deterministic evidence ranker (stories 6.4, 6.7 and 7.9, AD-31, PD-11).

Turns registry rows into a facts dict: which reasons, in which order, with which numbers. The
offline sentences are written from these facts by wording.py; Claude may reword them, but never
changes the order or a number. The same rows always give the same facts.

The answer follows the hearts360ai supervision prototype (story 7.9, UX audit groups K and L):
- only problems are reasons; a lever that meets its line is never listed as a cause (UX-07);
- each reason carries the monthly series behind it, so the widget can draw the chart (UX-10);
- each action is sized and its numbers are computed here, with the inputs named (`derived`), so
  every number shown can be traced back to a registry function (UX-08);
- medicine stock is read before any stepping-up or calling advice (UX-09).
Where the prototype uses data these reports do not have (a titration conversion rate, the share
of returning patients who reach control, potential gain in controlled patients), the slot is left
out rather than estimated.

Thresholds. Where a stored function already applies a threshold, the ranker uses its result and
holds no number of its own: `low` (chat.stock_days_below), `breaches` (chattogram.*), `also_check`
and `looks_fine_check` (common.high_control_pct), and the report `flag` columns. h360_api has no
privilege on report_flag_thresholds or h360_threshold, so the lines the sentences name are
mirrored in THRESHOLDS below, keyed exactly as the report_flag_thresholds rows. Keep them equal to
that table (CLINICAL-RULES section 2).
"""

from __future__ import annotations

import datetime as dt
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from h360_api.registry import Fetcher, Place

# Mirror of report_flag_thresholds rows (report.key -> value). See module docstring.
THRESHOLDS: dict[str, Decimal] = {
    "common.high_control_pct": Decimal("60"),
    "chat.new_loss_above_pct": Decimal("25"),
    "chat.usable_phone_below_pct": Decimal("90"),
    "chat.called_below_pct": Decimal("10"),
    "chat.early_below_pct": Decimal("50"),
    "chat.titration_below_pct": Decimal("40"),
    "chat.stock_days_below": Decimal("30"),
    "fudging.flag_score": Decimal("2.0"),
    "fudging.min_readings": Decimal("20"),
    "fudging.flag_ratio": Decimal("2.0"),
    "statins.flag_below_pct": Decimal("25"),
    "chattogram.control_below_pct": Decimal("50"),
    "chattogram.missed_visit_above_pct": Decimal("25"),
}

# Plain constants the sentences use. They are part of the facts, so the number check covers them.
#   per_one, band_*: the readings ratio as report_fudging and report_fudging_quarterly count it
#     (130-139 against 140-149, the BP Fudging PRD).
#   calls_per_nurse_week: one nurse's weekly calls in the Dr Rai action plan ("Assign one nurse to
#     call 25 overdue patients each week"); the plan is sized from it, never from the whole list.
#   plan_weeks: the calling plan covers the next four weeks.
#   window_months: the report functions count the 3 months to the reporting month.
CONSTANTS = {
    "bp_line": 140,
    "per_one": 1,
    "band_low_from": 130,
    "band_low_to": 139,
    "band_high_from": 140,
    "band_high_to": 149,
    "calls_per_nurse_week": 25,
    "plan_weeks": 4,
    "window_months": 3,
}

SERIES_MONTHS = 6

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

# Report tab slugs (PD-4) and visible names.
TABS = {
    "Right-medicines": "Right medicines",
    "Stepping-up": "Stepping up",
    "BP-readings-check": "BP readings check",
    "Statins": "Statins",
    "Overdue-calls": "Overdue calls",
}

# The prototype's issue order: overdue calling, then titration; new patients and phones follow.
LEVER_ORDER = ("overdue_calling", "titration_rate", "new_patient_return", "phone_capture")
LEVER_SLUG = {
    "new_patient_return": "Overdue-calls",
    "phone_capture": "Overdue-calls",
    "overdue_calling": "Overdue-calls",
    "titration_rate": "Stepping-up",
    "fudging_score": "BP-readings-check",
    "statin_gap": "Statins",
}
STOCK_SENSITIVE = ("overdue_calling", "titration_rate")
FLAG_REPORTS = (("fudging_score", "BP readings check"), ("titration_rate", "Stepping up"))
# Flags a district names per facility, in the Reports tab order (UX-17).
FACILITY_FLAGS = (
    ("titration_rate", "Stepping-up"),
    ("fudging_score", "BP-readings-check"),
    ("overdue_calling", "Overdue-calls"),
    ("statin_gap", "Statins"),
)

# Series per lever: registry key, value column, numerator, denominator (None: computed).
SERIES = {
    "control": ("control_summary", "controlled_pct", "controlled_n", "under_care_n"),
    "overdue_calling": ("overdue_calling", "called_pct", "called_n", "overdue_with_phone_n"),
    "titration_rate": ("titration_rate", "titration_pct", "stepped_up_n", "uncontrolled_visits_n"),
    "new_patient_return": ("new_patient_return", "new_loss_pct", None, "new_patients_n"),
    "phone_capture": ("phone_capture", "new_usable_phone_pct", "new_usable_phone_n", "new_patients_n"),
    "fudging_score": ("fudging_score", "score", "band_135_139_n", "band_140_144_n"),
    "statin_gap": ("statin_gap", "on_statin_pct", "on_statin_n", "eligible_n"),
}


def month_label(month: dt.date) -> str:
    return f"{MONTHS[month.month - 1]}-{month.year}"


def add_months(month: dt.date, delta: int) -> dt.date:
    index = month.year * 12 + month.month - 1 + delta
    return dt.date(index // 12, index % 12 + 1, 1)


def num(value: Any) -> Any:
    """Numbers as the SQL shows them: Decimal as its text ('75.0'), ints as ints."""
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (int, str)):
        return value
    if isinstance(value, float):
        return str(Decimal(str(value)))
    return value


def dec(value: Any) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return Decimal(str(value).replace(",", ""))
    except Exception:
        return None


def plain(value: Decimal) -> str:
    """A Decimal as a short plain string: 30, 2.5 (no exponent, no trailing zeros)."""
    text = format(value.normalize(), "f")
    return text


def _usable(row: dict | None, column: str) -> bool:
    return row is not None and row.get("too_few") is not True and dec(row.get(column)) is not None


# ---------------------------------------------------------------------------- derived numbers
# Every number the ranker computes is recorded with its rule and inputs, so the number check (and
# scripts/verify_chat.sh) can recompute it from registry output. The rules are deliberately few.

def apply_rule(rule: str, inputs: list[Decimal]) -> Decimal:
    if rule == "sub":
        return inputs[0] - inputs[1]
    if rule == "add":
        return inputs[0] + inputs[1]
    if rule == "mul":
        return inputs[0] * inputs[1]
    if rule == "min":
        return min(inputs)
    if rule == "round0":
        return inputs[0].quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    if rule == "round1":
        return inputs[0].quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)
    if rule == "pct_of":  # round(a * b / 100)
        return (inputs[0] * inputs[1] / Decimal(100)).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    if rule == "pct":  # round(100 * a / b)
        return (Decimal(100) * inputs[0] / inputs[1]).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    raise ValueError(rule)


def derive(log: list[dict], rule: str, *inputs: Any) -> str:
    values = [dec(i) for i in inputs]
    if any(v is None for v in values):
        raise ValueError("missing input")
    value = plain(apply_rule(rule, values))
    entry = {"value": value, "rule": rule, "inputs": [plain(v) for v in values]}
    if entry not in log:
        log.append(entry)
    return value


class Ranker:
    def __init__(self, fetch: Fetcher, place: Place, live: frozenset[str]) -> None:
        self.fetch = fetch
        self.place = place
        self.live = live
        self.node = place.org_unit_id
        self.derived: list[dict] = []

    # ------------------------------------------------------------------ helpers
    def _sel(self, key: str, node: int | None = None, fetch: Fetcher | None = None) -> dict | None:
        if key not in self.live:
            return None
        return (fetch or self.fetch).selected(key, self.node if node is None else node)

    def _rows(self, key: str) -> list[dict]:
        if key not in self.live:
            return []
        return self.fetch.rows(key, self.node)

    def months(self) -> list[dt.date]:
        return [add_months(self.fetch.month, -i) for i in range(SERIES_MONTHS - 1, -1, -1)]

    def window(self) -> dict:
        """The months the report functions count: the 3 months to the reporting month."""
        end = self.fetch.month
        start = add_months(end, 1 - CONSTANTS["window_months"])
        return {"start": start.isoformat(), "end": end.isoformat(),
                "start_year": start.year, "end_year": end.year}

    def series(self, name: str) -> list[dict]:
        """One point per month for the last six months, from the same registry function.

        Titration and statins use the Reports tab's monthly function (with the network average)
        and readings the quarterly one, when they are live (story 7.9).
        """
        if name == "titration_rate" and "titration_monthly" in self.live:
            return self._monthly("titration_monthly", "follow_up_n", "titrated_n")
        if name == "statin_gap" and "statins_monthly" in self.live:
            return self._monthly("statins_monthly", "eligible_n", "on_statin_n")
        if name == "fudging_score":
            view = self.fudging_view()
            if view and view["source"] == "quarterly":
                return view["quarters"]
        key, value_col, num_col, den_col = SERIES[name]
        if key not in self.live:
            return []
        points = []
        for m in self.months():
            row = self._sel(key, fetch=self.fetch.at(m))
            point = {"month": m.isoformat(), "value": None, "num": None, "den": None}
            if row is not None and row.get("too_few") is not True and dec(row.get(value_col)) is not None:
                point["value"] = num(row.get(value_col))
                point["den"] = num(row.get(den_col))
                if num_col is not None:
                    point["num"] = num(row.get(num_col))
                elif name == "new_patient_return":
                    n, back = dec(row.get("new_patients_n")), dec(row.get("new_returned_n"))
                    point["num"] = None if n is None or back is None else int(n - back)
                if name == "fudging_score" and (dec(point["den"]) or 0) < THRESHOLDS["fudging.min_readings"]:
                    # A ratio over a handful of 140-149 readings is noise: the month is not drawn.
                    point["value"] = None
                    point["thin"] = True
            points.append(point)
        return points

    def _monthly(self, key: str, den_col: str, num_col: str) -> list[dict]:
        oid = self.node
        wanted = {m.isoformat() for m in self.months()}
        points = []
        for row in self.fetch.rows(key, oid):
            if int(row.get("org_unit_id") or -1) != oid:
                continue
            month = str(row.get("month_date"))[:10]
            if month not in wanted:
                continue
            ok = row.get("too_few") is not True and dec(row.get("rate_pct")) is not None
            points.append({
                "month": month,
                "value": num(row.get("rate_pct")) if ok else None,
                "num": num(row.get(num_col)),
                "den": num(row.get(den_col)),
                "average": num(row.get("average_rate_pct")),
            })
        return sorted(points, key=lambda p: p["month"])

    def fudging_view(self, node: int | None = None, oid: int | None = None) -> dict | None:
        """The readings ratio for one place: the last completed quarter (UX-25), else the window.

        `node` is the place the function is called for; `oid` picks a facility row inside it.
        """
        node = self.node if node is None else node
        oid = node if oid is None else oid
        if "fudging_quarterly" in self.live:
            rows = [r for r in self.fetch.rows("fudging_quarterly", node)
                    if int(r.get("org_unit_id") or -1) == oid]
            done = sorted((r for r in rows if r.get("is_complete") is True), key=lambda r: str(r["quarter_start"]))
            if done:
                last = done[-1]
                prev = done[-2] if len(done) >= 2 else None
                usable = lambda r: r is not None and r.get("too_few") is not True and dec(r.get("ratio")) is not None
                return {
                    "source": "quarterly",
                    "flag": last.get("flag") is True,
                    "too_few": not usable(last),
                    "score": num(last.get("ratio")),
                    "low_n": num(last.get("n_130_139")),
                    "high_n": num(last.get("n_140_149")),
                    "period": str(last.get("quarter_label") or ""),
                    "previous_score": num(prev.get("ratio")) if usable(prev) else None,
                    "previous_period": str(prev.get("quarter_label") or "") if usable(prev) else None,
                    "quarters": [{
                        "month": str(r["quarter_start"])[:10],
                        "label": str(r.get("quarter_label") or ""),
                        "value": num(r.get("ratio")) if usable(r) else None,
                        "num": num(r.get("n_130_139")),
                        "den": num(r.get("n_140_149")),
                    } for r in done[-4:]],
                }
        if "fudging_score" not in self.live:
            return None
        row = next((r for r in self.fetch.rows("fudging_score", node)
                    if int(r.get("org_unit_id") or -1) == oid), None)
        if row is None:
            return None
        return {
            "source": "window",
            "flag": row.get("flag") is True,
            "too_few": row.get("too_few") is True or dec(row.get("score")) is None,
            "score": num(row.get("score")),
            "low_n": num(row.get("band_135_139_n")),
            "high_n": num(row.get("band_140_144_n")),
            "period": None,
            "previous_score": None,
            "previous_period": None,
            "control_pct": num(row.get("control_pct")),
            "looks_fine_check": row.get("looks_fine_check") is True,
        }

    def control(self) -> dict | None:
        row = self._sel("control_summary")
        if row is None:
            return None
        return {
            "too_few": row.get("too_few") is True,
            "under_care_n": num(row.get("under_care_n")),
            "controlled_n": num(row.get("controlled_n")),
            "controlled_pct": num(row.get("controlled_pct")),
            "uncontrolled_n": num(row.get("uncontrolled_n")),
            "uncontrolled_pct": num(row.get("uncontrolled_pct")),
            "missed_visit_pct": num(row.get("missed_visit_pct")),
            "ltfu_pct": num(row.get("ltfu_pct")),
        }

    def stock_rows(self) -> list[dict]:
        return [{"category": str(r.get("category") or ""), "patient_days": num(r.get("patient_days")),
                 "low": r.get("low") is True} for r in self._rows("drug_stock_gate")]

    def stock(self) -> list[dict]:
        return [{"category": r["category"], "patient_days": r["patient_days"]}
                for r in self.stock_rows() if r["low"]]

    def plan(self) -> dict | None:
        rows = self._rows("call_plan")
        if not rows:
            return None
        return {"total": num(rows[0].get("overdue_with_phone_n")) or 0}

    # ------------------------------------------------------------------ levers (AD-31)
    def levers(self) -> list[dict]:
        """Every lever with data, each marked triggered or not."""
        out: list[dict] = []
        np_row = self._sel("new_patient_return")
        if _usable(np_row, "new_loss_pct"):
            loss = dec(np_row["new_loss_pct"])
            values = {
                "new_loss_pct": num(np_row["new_loss_pct"]),
                "new_patients_n": num(np_row.get("new_patients_n")),
                "new_returned_n": num(np_row.get("new_returned_n")),
            }
            triggered = loss > THRESHOLDS["chat.new_loss_above_pct"]
            if triggered and values["new_patients_n"] is not None and values["new_returned_n"] is not None:
                values["new_lost_n"] = derive(self.derived, "sub", values["new_patients_n"], values["new_returned_n"])
            out.append(self._lever("new_patient_return", triggered, values))
        ph_row = self._sel("phone_capture")
        if _usable(ph_row, "new_usable_phone_pct"):
            pct = dec(ph_row["new_usable_phone_pct"])
            out.append(self._lever("phone_capture", pct < THRESHOLDS["chat.usable_phone_below_pct"], {
                "new_usable_phone_pct": num(ph_row["new_usable_phone_pct"]),
                "new_patients_n": num(ph_row.get("new_patients_n")),
                "new_usable_phone_n": num(ph_row.get("new_usable_phone_n")),
            }))
        ca_row = self._sel("overdue_calling")
        if _usable(ca_row, "called_pct"):
            called = dec(ca_row["called_pct"])
            early = dec(ca_row.get("early_pct"))
            called_low = called < THRESHOLDS["chat.called_below_pct"]
            early_low = early is not None and early < THRESHOLDS["chat.early_below_pct"]
            out.append(self._lever("overdue_calling", called_low or early_low, dict(self._calling_values(ca_row),
                                   called_low=called_low, early_low=early_low)))
        ti_row = self._sel("titration_rate")
        if _usable(ti_row, "titration_pct"):
            pct = dec(ti_row["titration_pct"])
            out.append(self._lever("titration_rate", pct < THRESHOLDS["chat.titration_below_pct"],
                                   self._titration_values(ti_row)))
        return out

    def _calling_values(self, row: dict, overdue_with_phone_n: Any = None) -> dict:
        """`overdue_with_phone_n`, when given, replaces the row's (the call plan's total)."""
        values = {
            "called_pct": num(row["called_pct"]),
            "called_n": num(row.get("called_n")),
            "overdue_with_phone_n": num(row.get("overdue_with_phone_n")) if overdue_with_phone_n is None
            else overdue_with_phone_n,
            "early_pct": num(row.get("early_pct")),
            "early_n": num(row.get("early_n")),
            "returned_n": num(row.get("returned_n")),
            "return_known_n": num(row.get("return_known_n")),
            "returned_pct": num(row.get("returned_pct")),
        }
        # UX-11: the return share the Reports tab and the HTN row now share, when it is live.
        ret = self._sel("calling_return", int(row["org_unit_id"]) if row.get("org_unit_id") is not None else None)
        if ret is not None and ret.get("too_few") is not True and ret.get("returned_month_pct") is not None:
            values["returned_n"] = num(ret.get("returned_month_n"))
            values["return_known_n"] = num(ret.get("called_month_n"))
            values["returned_pct"] = num(ret.get("returned_month_pct"))
        values.update(self._call_sizing(values))
        return values

    def _call_sizing(self, values: dict) -> dict:
        """A plan a facility can do (UX-08): one nurse's 25 calls a week, for four weeks.

        At a district, one nurse per facility in view. The expected returns use the share of
        called patients who came back here (report_calling.returned_pct), when it is known.
        """
        per_nurse = CONSTANTS["calls_per_nurse_week"]
        facilities = 1
        if self.place.scope == "district":
            facilities = len(self.fetch.facilities("overdue_calling", self.node)) or 1
        per_week = str(per_nurse) if facilities == 1 else derive(self.derived, "mul", per_nurse, facilities)
        four_weeks = derive(self.derived, "mul", per_week, CONSTANTS["plan_weeks"])
        out = {"per_week": per_week, "facilities_n": facilities, "plan_calls": four_weeks}
        overdue = values.get("overdue_with_phone_n")
        if overdue is not None and dec(overdue) < dec(four_weeks):
            out["plan_calls"] = derive(self.derived, "min", four_weeks, overdue)
        if values.get("returned_pct") is not None and dec(values.get("return_known_n") or 0):
            out["returning_n"] = derive(self.derived, "pct_of", out["plan_calls"], values["returned_pct"])
        return out

    def _titration_values(self, row: dict) -> dict:
        values = {
            "titration_pct": num(row["titration_pct"]),
            "stepped_up_n": num(row.get("stepped_up_n")),
            "uncontrolled_visits_n": num(row.get("uncontrolled_visits_n")),
        }
        if values["stepped_up_n"] is not None and values["uncontrolled_visits_n"] is not None:
            values["not_stepped_up_n"] = derive(self.derived, "sub", values["uncontrolled_visits_n"],
                                                values["stepped_up_n"])
        return values

    @staticmethod
    def _fudging_values(view: dict) -> dict:
        return {k: view[k] for k in ("source", "score", "low_n", "high_n", "period", "previous_score",
                                     "previous_period")}

    @staticmethod
    def _lever(lever: str, triggered: bool, values: dict) -> dict:
        return {"lever": lever, "triggered": bool(triggered), "values": values}

    # ------------------------------------------------------------------ flags for the place
    def place_flags(self) -> list[dict]:
        """Flagged fudging and titration rows for the place (PD-11), fudging first."""
        out = []
        fu = self.fudging_view()
        if fu is not None and fu["flag"]:
            out.append({"lever": "fudging_score", "kind": "flag", "values": self._fudging_values(fu)})
        ti = self._sel("titration_rate")
        if ti is not None and ti.get("flag") is True:
            out.append({"lever": "titration_rate", "kind": "flag", "values": self._titration_values(ti)})
        return out

    def _readings_flagged_rows(self) -> list[dict]:
        """Facility rows in scope flagged on readings, shaped like report_fudging rows.

        With the quarterly function live, the flag is the last completed quarter's and the control
        line is chat_control_summary's (the HTN tab formula, A36).
        """
        if "fudging_quarterly" not in self.live:
            return self._rows("fudging_score")
        control = {int(r["org_unit_id"]): r for r in self._rows("control_summary")}
        out = []
        for oid, c in control.items():
            if c.get("is_selected"):
                continue
            view = self.fudging_view(self.node, oid)
            pct = dec(c.get("controlled_pct"))
            out.append({
                "org_unit_id": oid, "org_unit_name": c.get("org_unit_name"), "is_selected": False,
                "flag": bool(view and view["flag"]),
                "control_pct": c.get("controlled_pct"),
                "looks_fine_check": bool(view and view["flag"] and pct is not None
                                         and pct >= THRESHOLDS["common.high_control_pct"]),
            })
        return out

    def looks_fine_facilities(self) -> list[dict]:
        """Facilities in scope (not the place itself) with looks_fine_check on fudging or titration."""
        found: dict[int, dict] = {}
        for key, tab in FLAG_REPORTS:
            rows = self._readings_flagged_rows() if key == "fudging_score" else self._rows(key)
            for row in rows:
                if row.get("is_selected") or row.get("looks_fine_check") is not True:
                    continue
                oid = int(row["org_unit_id"])
                item = found.setdefault(oid, {
                    "org_unit_id": oid,
                    "name": str(row.get("org_unit_name") or ""),
                    "controlled_pct": num(row.get("control_pct")),
                    "tabs": [],
                })
                item["tabs"].append(tab)
        # Most flags first, then name, then id: stable on every run.
        return sorted(found.values(), key=lambda f: (-len(f["tabs"]), f["name"], f["org_unit_id"]))

    # ------------------------------------------------------------------ answers
    def base(self, chip: str) -> dict:
        control = self.control()
        return {
            "chip": chip,
            "place": self.place.as_dict(),
            "month": self.fetch.month.isoformat(),
            "month_label": month_label(self.fetch.month),
            "window": self.window(),
            "state": "ok",
            "control": control,
            "control_series": [],
            "high_control": bool(
                control and not control["too_few"] and dec(control["controlled_pct"]) is not None
                and dec(control["controlled_pct"]) >= THRESHOLDS["common.high_control_pct"]
            ),
            "reasons": [],
            "also_check": None,
            "stock": [],
            "stock_rows": [],
            "plan": None,
            "nudge": None,
            "thresholds": {k: str(v) for k, v in THRESHOLDS.items()},
            "constants": dict(CONSTANTS),
            "derived": self.derived,
        }

    def _no_data(self, facts: dict) -> bool:
        c = facts["control"]
        if c is None or c["too_few"]:
            facts["state"] = "no_data"
            return True
        return False

    def _apply_stock(self, facts: dict) -> None:
        """Stock first (UX-09): a low category gates calling and stepping up; fine stock is said."""
        facts["stock_rows"] = self.stock_rows()
        facts["stock"] = self.stock()
        for r in facts["reasons"]:
            if r["lever"] in STOCK_SENSITIVE:
                if facts["stock"]:
                    r["stock_first"] = True
                elif facts["stock_rows"] and r["lever"] == "titration_rate":
                    r["stock_ok"] = True

    def _attach_series(self, facts: dict) -> None:
        for r in facts["reasons"]:
            if r["lever"] in SERIES and "series" not in r:
                r["series"] = self.series(r["lever"])

    def _control_series(self, facts: dict) -> None:
        facts["control_series"] = self.series("control")

    def why_control_low(self) -> dict:
        facts = self.base("why_control_low")
        if self._no_data(facts):
            return facts
        levers = self.levers()
        flags = self.place_flags()[:2] if facts["high_control"] else []
        if len(levers) < 2 and not flags:
            # Too few to rank: one plain sentence, no ranking.
            facts["state"] = "too_few"
            return facts
        reasons: list[dict] = list(flags)
        taken = {r["lever"] for r in reasons}
        by_name = {lv["lever"]: lv for lv in levers}
        for name in LEVER_ORDER:
            lv = by_name.get(name)
            if len(reasons) >= 3:
                break
            # UX-07: a lever that meets its line is never a reason.
            if lv is None or not lv["triggered"] or name in taken:
                continue
            reasons.append({"lever": name, "kind": "triggered", "values": lv["values"]})
            taken.add(name)
        if not reasons:
            facts["state"] = "no_clear_reason"
            self._control_series(facts)
            return facts
        facts["reasons"] = reasons[:3]
        self._also_check(facts)
        self._apply_stock(facts)
        self._attach_series(facts)
        self._control_series(facts)
        # The calling reason already carries the sized plan; offer the plan only when it does not.
        if "call_plan" in self.live and "overdue_calling" in self.live and "overdue_calling" not in taken:
            facts["nudge"] = {"chip_id": "call_plan", "kind": "call_plan"}
        return facts

    def _also_check(self, facts: dict) -> None:
        if facts["high_control"] and self.place.scope == "facility":
            flags = self.place_flags()
            if flags:
                facts["also_check"] = {
                    "kind": "self",
                    "name": self.place.name,
                    "controlled_pct": facts["control"]["controlled_pct"],
                    "tabs": [tab for key, tab in FLAG_REPORTS if any(f["lever"] == key for f in flags)],
                }
            return
        if self.place.scope == "district":
            others = self.looks_fine_facilities()
            if others:
                facts["also_check"] = dict(others[0], kind="other")

    def who_to_call(self, follow_up: bool = False) -> dict:
        facts = self.base("call_plan" if follow_up else "who_to_call")
        plan = self.plan()
        calling = self._sel("overdue_calling")
        if plan is None or calling is None or calling.get("too_few") is True or calling.get("called_pct") is None:
            facts["state"] = "no_data"
            return facts
        values = self._calling_values(calling, plan["total"])
        weeks_n = CONSTANTS["plan_weeks"]
        per_week = dec(values["per_week"])
        remaining = dec(plan["total"]) or Decimal(0)
        weeks = []
        for _ in range(weeks_n):
            w = min(per_week, max(remaining, Decimal(0)))
            weeks.append(int(w))
            remaining -= w
        facts["plan"] = {
            "total": plan["total"],
            "weeks": weeks,
            "per_week": values["per_week"],
            "plan_calls": values["plan_calls"],
            "facilities_n": values["facilities_n"],
            "returning_n": values.get("returning_n"),
        }
        facts["reasons"] = [{"lever": "overdue_calling", "kind": "plan", "values": values}]
        if not follow_up:
            facts["nudge"] = {"chip_id": "overdue_list", "kind": "overdue_list"}
        self._apply_stock(facts)
        self._attach_series(facts)
        return facts

    def medicines_adjusted(self) -> dict:
        facts = self.base("medicines_adjusted")
        row = self._sel("titration_rate")
        facts["nudge"] = {"chip_id": "step_up_least" if self.place.scope == "district" else "open_stepping_up",
                          "kind": "tab", "slug": "Stepping-up"}
        if row is None or not _usable(row, "titration_pct"):
            facts["state"] = "too_few"
            facts["too_few_kind"] = "titration"
            return facts
        facts["reasons"] = [{
            "lever": "titration_rate",
            "kind": "triggered" if row.get("flag") is True else "on_target",
            "values": self._titration_values(row),
        }]
        self._apply_stock(facts)
        self._attach_series(facts)
        return facts

    def readings_reliable(self) -> dict:
        facts = self.base("readings_reliable")
        facts["nudge"] = {"chip_id": "open_bp_readings_check", "kind": "tab", "slug": "BP-readings-check"}
        view = self.fudging_view()
        if view is None:
            facts["state"] = "too_few"
            facts["too_few_kind"] = "readings"
            return facts
        if view["flag"]:
            facts["reasons"] = [{"lever": "fudging_score", "kind": "flag", "values": self._fudging_values(view)}]
            self._attach_series(facts)
            return facts
        if view["too_few"]:
            facts["state"] = "too_few"
            facts["too_few_kind"] = "readings"
            return facts
        facts["reasons"] = [{"lever": "fudging_score", "kind": "no_sign", "values": self._fudging_values(view)}]
        self._attach_series(facts)
        return facts

    def statin_gap(self) -> dict:
        facts = self.base("statin_gap")
        if self.place.scope == "facility":
            facts["nudge"] = {"chip_id": "patient_list", "kind": "tab", "slug": "Statins"}
        row = self._sel("statin_gap")
        if row is None or row.get("too_few") is True or row.get("eligible_n") in (None, 0):
            facts["state"] = "too_few"
            facts["too_few_kind"] = "statins"
            return facts
        facts["reasons"] = [{"lever": "statin_gap", "kind": "count", "values": {
            "not_on_statin_n": num(row.get("not_on_statin_n")),
            "eligible_n": num(row.get("eligible_n")),
            "on_statin_pct": num(row.get("on_statin_pct")),
        }}]
        self._attach_series(facts)
        return facts

    # ------------------------------------------------------------------ district (story 6.7)
    def facility_flags(self) -> dict[int, list[str]]:
        """Report tabs each facility in the district is flagged on, in the Reports tab order."""
        out: dict[int, list[str]] = {}
        for key, slug in FACILITY_FLAGS:
            rows = self._readings_flagged_rows() if key == "fudging_score" else self._rows(key)
            for row in rows:
                if row.get("is_selected") or row.get("flag") is not True:
                    continue
                out.setdefault(int(row["org_unit_id"]), []).append(slug)
        return out

    def facility_table(self, flags: dict[int, list[str]]) -> list[dict]:
        rows = []
        for r in self.fetch.facilities("control_summary", self.node):
            oid = int(r["org_unit_id"])
            rows.append({
                "org_unit_id": oid,
                "name": str(r.get("org_unit_name") or ""),
                "controlled_pct": num(r.get("controlled_pct")),
                "missed_visit_pct": num(r.get("missed_visit_pct")),
                "uncontrolled_n": num(r.get("uncontrolled_n")),
                "under_care_n": num(r.get("under_care_n")),
                "flags": list(flags.get(oid, [])),
            })
        rows.sort(key=lambda r: (-(dec(r["uncontrolled_n"]) or 0), r["name"], r["org_unit_id"]))
        return rows

    def visit_first(self) -> dict:
        facts = self.base("visit_first")
        ranked = self._rows("facility_rank_district")
        control = {int(r["org_unit_id"]): r for r in self.fetch.facilities("control_summary", self.node)}
        breached = [r for r in ranked if r.get("breaches")]
        also = [r for r in ranked if r.get("also_check") is True]
        picks = breached[:3]
        if also:
            head = breached[:2]
            head_ids = {int(r["org_unit_id"]) for r in head}
            extra = next((r for r in also if int(r["org_unit_id"]) not in head_ids), None)
            if extra is not None:
                picks = head + [extra]
        if not picks:
            facts["state"] = "none"
            return facts
        flags = self.facility_flags()
        facts["facility_table"] = self.facility_table(flags)
        looks_fine = {f["org_unit_id"]: f for f in self.looks_fine_facilities()}
        reasons = []
        for r in picks:
            oid = int(r["org_unit_id"])
            c = control.get(oid, {})
            breaches = [str(b) for b in (r.get("breaches") or [])]
            tabs = [TABS[s] for s in flags.get(oid, [])]
            if breaches:
                reasons.append({"lever": "facility_rank_district", "kind": "visit", "org_unit_id": oid, "values": {
                    "name": str(r.get("org_unit_name") or ""),
                    "uncontrolled_n": num(r.get("uncontrolled_n")),
                    "under_care_n": num(c.get("under_care_n")),
                    "breaches": breaches,
                    "controlled_pct": num(c.get("controlled_pct")),
                    "uncontrolled_pct": num(c.get("uncontrolled_pct")),
                    "missed_visit_pct": num(c.get("missed_visit_pct")),
                    "ltfu_pct": num(c.get("ltfu_pct")),
                    "flag_slugs": list(flags.get(oid, [])),
                    "tabs": tabs,
                }})
            else:
                lf = looks_fine.get(oid, {})
                lf_tabs = list(lf.get("tabs") or [])
                reasons.append({"lever": "facility_rank_district", "kind": "visit_also", "org_unit_id": oid, "values": {
                    "name": str(r.get("org_unit_name") or ""),
                    "uncontrolled_n": num(r.get("uncontrolled_n")),
                    "controlled_pct": num(c.get("controlled_pct")),
                    "tabs": lf_tabs,
                    "flag_slugs": [s for key, t in FLAG_REPORTS for s in [LEVER_SLUG[key]] if t in lf_tabs]
                    or ["BP-readings-check"],
                }})
        if reasons and reasons[0]["kind"] == "visit":
            reasons[0]["rank_first"] = True  # chat_facility_rank_district puts it first
        facts["reasons"] = reasons
        self._control_series(facts)
        first = reasons[0]
        if "control_summary" in self.live:
            facts["nudge"] = {"chip_id": "why_control_low", "kind": "facility_question",
                              "org_unit_id": first["org_unit_id"], "name": first["values"]["name"]}
        return facts


def build_facts(chip_id: str, place: Place, fetch: Fetcher, live: frozenset[str]) -> dict:
    ranker = Ranker(fetch, place, live)
    if chip_id == "why_control_low":
        return ranker.why_control_low()
    if chip_id == "who_to_call":
        return ranker.who_to_call()
    if chip_id == "call_plan":
        return ranker.who_to_call(follow_up=True)
    if chip_id == "medicines_adjusted":
        return ranker.medicines_adjusted()
    if chip_id == "readings_reliable":
        return ranker.readings_reliable()
    if chip_id == "statin_gap":
        return ranker.statin_gap()
    if chip_id == "visit_first":
        return ranker.visit_first()
    raise KeyError(chip_id)
