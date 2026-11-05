"""Deterministic evidence ranker (stories 6.4 and 6.7, AD-31, PD-11).

Turns registry rows into a facts dict: which reasons, in which order, with which numbers. The
offline sentences are written from these facts by wording.py; Claude may reword them, but never
changes the order or a number. The same rows always give the same facts.

Thresholds. Where a stored function already applies a threshold, the ranker uses its result and
holds no number of its own: `low` (chat.stock_days_below), `breaches` (chattogram.*), `also_check`
and `looks_fine_check` (common.high_control_pct), and the report `flag` columns. h360_api has no
privilege on report_flag_thresholds or h360_threshold, so the five lever lines and the PD-11
control line are mirrored in THRESHOLDS below, keyed exactly as the report_flag_thresholds rows.
Keep them equal to that table (CLINICAL-RULES section 2).
"""

from __future__ import annotations

import datetime as dt
from decimal import Decimal
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
}

# Plain constants the sentences use. They are part of the facts, so the number check covers them.
CONSTANTS = {"bp_line": 140, "per_one": 1}

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

# Report tab slugs (PD-4) and visible names.
TABS = {
    "Right-medicines": "Right medicines",
    "Stepping-up": "Stepping up",
    "BP-readings-check": "BP readings check",
    "Statins": "Statins",
    "Overdue-calls": "Overdue calls",
}

LEVER_TIER = {"new_patient_return": 1, "phone_capture": 2, "overdue_calling": 3, "titration_rate": 4}
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


def month_label(month: dt.date) -> str:
    return f"{MONTHS[month.month - 1]}-{month.year}"


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
        return Decimal(str(value))
    except Exception:
        return None


def _usable(row: dict | None, column: str) -> bool:
    return row is not None and row.get("too_few") is not True and dec(row.get(column)) is not None


class Ranker:
    def __init__(self, fetch: Fetcher, place: Place, live: frozenset[str]) -> None:
        self.fetch = fetch
        self.place = place
        self.live = live
        self.node = place.org_unit_id

    # ------------------------------------------------------------------ helpers
    def _sel(self, key: str, node: int | None = None) -> dict | None:
        if key not in self.live:
            return None
        return self.fetch.selected(key, self.node if node is None else node)

    def _rows(self, key: str, node: int | None = None) -> list[dict]:
        if key not in self.live:
            return []
        return self.fetch.rows(key, self.node if node is None else node)

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

    def stock(self) -> list[dict]:
        out = []
        for row in self._rows("drug_stock_gate"):
            if row.get("low") is True:
                out.append({"category": str(row.get("category") or ""), "patient_days": num(row.get("patient_days"))})
        return out

    def plan(self) -> dict | None:
        rows = self._rows("call_plan")
        if not rows:
            return None
        row = rows[0]
        weeks = [num(row.get(f"week_{i}")) or 0 for i in range(1, 5)]
        return {"total": num(row.get("overdue_with_phone_n")) or 0, "weeks": weeks}

    # ------------------------------------------------------------------ levers (AD-31)
    def levers(self) -> list[dict]:
        """Every lever with data, each marked triggered or not, with its gap to the line."""
        out: list[dict] = []
        np_row = self._sel("new_patient_return")
        if _usable(np_row, "new_loss_pct"):
            loss = dec(np_row["new_loss_pct"])
            line = THRESHOLDS["chat.new_loss_above_pct"]
            out.append(self._lever("new_patient_return", loss > line, loss - line, {
                "new_loss_pct": num(np_row["new_loss_pct"]),
                "new_patients_n": num(np_row.get("new_patients_n")),
                "new_returned_n": num(np_row.get("new_returned_n")),
            }))
        ph_row = self._sel("phone_capture")
        if _usable(ph_row, "new_usable_phone_pct"):
            pct = dec(ph_row["new_usable_phone_pct"])
            line = THRESHOLDS["chat.usable_phone_below_pct"]
            out.append(self._lever("phone_capture", pct < line, line - pct, {
                "new_usable_phone_pct": num(ph_row["new_usable_phone_pct"]),
                "new_patients_n": num(ph_row.get("new_patients_n")),
                "new_usable_phone_n": num(ph_row.get("new_usable_phone_n")),
            }))
        ca_row = self._sel("overdue_calling")
        if _usable(ca_row, "called_pct"):
            called = dec(ca_row["called_pct"])
            early = dec(ca_row.get("early_pct"))
            called_line = THRESHOLDS["chat.called_below_pct"]
            early_line = THRESHOLDS["chat.early_below_pct"]
            called_low = called < called_line
            early_low = early is not None and early < early_line
            gaps = [called_line - called] + ([early_line - early] if early is not None else [])
            out.append(self._lever("overdue_calling", called_low or early_low, max(gaps), {
                "called_pct": num(ca_row["called_pct"]),
                "called_n": num(ca_row.get("called_n")),
                "overdue_with_phone_n": num(ca_row.get("overdue_with_phone_n")),
                "early_pct": num(ca_row.get("early_pct")),
                "early_n": num(ca_row.get("early_n")),
                "calls_per_week": num(ca_row.get("calls_per_week")),
                "called_low": called_low,
                "early_low": early_low,
            }))
        ti_row = self._sel("titration_rate")
        if _usable(ti_row, "titration_pct"):
            pct = dec(ti_row["titration_pct"])
            line = THRESHOLDS["chat.titration_below_pct"]
            out.append(self._lever("titration_rate", pct < line, line - pct, {
                "titration_pct": num(ti_row["titration_pct"]),
                "stepped_up_n": num(ti_row.get("stepped_up_n")),
                "uncontrolled_visits_n": num(ti_row.get("uncontrolled_visits_n")),
            }))
        return out

    @staticmethod
    def _lever(lever: str, triggered: bool, gap: Decimal, values: dict) -> dict:
        return {"lever": lever, "tier": LEVER_TIER[lever], "triggered": bool(triggered), "gap": gap, "values": values}

    # ------------------------------------------------------------------ flags for the place
    def place_flags(self, node: int | None = None) -> list[dict]:
        """Flagged fudging and titration rows for one place (PD-11), fudging first."""
        out = []
        fu = self._sel("fudging_score", node)
        if fu is not None and fu.get("flag") is True:
            out.append({"lever": "fudging_score", "kind": "flag", "values": {
                "score": num(fu.get("score")),
                "readings_n": num(fu.get("readings_n")),
                "band_135_139_n": num(fu.get("band_135_139_n")),
                "band_140_144_n": num(fu.get("band_140_144_n")),
                "flag_reason": fu.get("flag_reason"),
            }})
        ti = self._sel("titration_rate", node)
        if ti is not None and ti.get("flag") is True:
            out.append({"lever": "titration_rate", "kind": "flag", "values": {
                "titration_pct": num(ti.get("titration_pct")),
                "stepped_up_n": num(ti.get("stepped_up_n")),
                "uncontrolled_visits_n": num(ti.get("uncontrolled_visits_n")),
            }})
        return out

    def looks_fine_facilities(self) -> list[dict]:
        """Facilities in scope (not the place itself) with looks_fine_check on fudging or titration."""
        found: dict[int, dict] = {}
        for key, tab in FLAG_REPORTS:
            for row in self._rows(key):
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
            "state": "ok",
            "control": control,
            "high_control": bool(
                control and not control["too_few"] and dec(control["controlled_pct"]) is not None
                and dec(control["controlled_pct"]) >= THRESHOLDS["common.high_control_pct"]
            ),
            "reasons": [],
            "also_check": None,
            "stock": [],
            "plan": None,
            "nudge": None,
            "thresholds": {k: str(v) for k, v in THRESHOLDS.items()},
            "constants": dict(CONSTANTS),
        }

    def _no_data(self, facts: dict) -> bool:
        c = facts["control"]
        if c is None or c["too_few"]:
            facts["state"] = "no_data"
            return True
        return False

    def _apply_stock(self, facts: dict) -> None:
        facts["stock"] = self.stock()
        if facts["stock"]:
            for r in facts["reasons"]:
                if r["lever"] in STOCK_SENSITIVE:
                    r["stock_first"] = True

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
        triggered = sorted((lv for lv in levers if lv["triggered"]), key=lambda lv: (lv["tier"], -lv["gap"]))
        for lv in triggered:
            if len(reasons) >= 3:
                break
            if lv["lever"] not in taken:
                reasons.append({"lever": lv["lever"], "kind": "triggered", "values": lv["values"]})
                taken.add(lv["lever"])
        # Fewer than two: pad with the untriggered lever of the lowest tier number, worded as on target.
        pad = sorted((lv for lv in levers if not lv["triggered"] and lv["lever"] not in taken), key=lambda lv: lv["tier"])
        for lv in pad:
            if len(reasons) >= 2:
                break
            reasons.append({"lever": lv["lever"], "kind": "on_target", "values": lv["values"]})
        facts["reasons"] = reasons[:3]
        self._also_check(facts)
        self._apply_stock(facts)
        if "call_plan" in self.live and "overdue_calling" in self.live:
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
        if plan is None or calling is None:
            facts["state"] = "no_data"
            return facts
        facts["plan"] = plan
        facts["reasons"] = [{"lever": "overdue_calling", "kind": "plan", "values": {
            "overdue_with_phone_n": plan["total"],
            "called_pct": num(calling.get("called_pct")),
            "called_n": num(calling.get("called_n")),
            "week_1": plan["weeks"][0],
        }}]
        if not follow_up:
            facts["nudge"] = {"chip_id": "overdue_list", "kind": "overdue_list"}
        self._apply_stock(facts)
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
            "values": {"titration_pct": num(row["titration_pct"]),
                       "stepped_up_n": num(row.get("stepped_up_n")),
                       "uncontrolled_visits_n": num(row.get("uncontrolled_visits_n"))},
        }]
        self._apply_stock(facts)
        return facts

    def readings_reliable(self) -> dict:
        facts = self.base("readings_reliable")
        facts["nudge"] = {"chip_id": "open_bp_readings_check", "kind": "tab", "slug": "BP-readings-check"}
        row = self._sel("fudging_score")
        if row is None:
            facts["state"] = "too_few"
            facts["too_few_kind"] = "readings"
            return facts
        if row.get("flag") is True:
            facts["reasons"] = self.place_flags()[:1]
            return facts
        if row.get("too_few") is True or dec(row.get("score")) is None:
            facts["state"] = "too_few"
            facts["too_few_kind"] = "readings"
            return facts
        facts["reasons"] = [{"lever": "fudging_score", "kind": "no_sign", "values": {
            "score": num(row.get("score")), "readings_n": num(row.get("readings_n")),
            "band_135_139_n": num(row.get("band_135_139_n")), "band_140_144_n": num(row.get("band_140_144_n"))}}]
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
        return facts

    # ------------------------------------------------------------------ district (story 6.7)
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
        looks_fine = {f["org_unit_id"]: f for f in self.looks_fine_facilities()}
        reasons = []
        for r in picks:
            oid = int(r["org_unit_id"])
            c = control.get(oid, {})
            breaches = [str(b) for b in (r.get("breaches") or [])]
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
                }})
            else:
                lf = looks_fine.get(oid, {})
                reasons.append({"lever": "facility_rank_district", "kind": "visit_also", "org_unit_id": oid, "values": {
                    "name": str(r.get("org_unit_name") or ""),
                    "uncontrolled_n": num(r.get("uncontrolled_n")),
                    "controlled_pct": num(c.get("controlled_pct")),
                    "tabs": list(lf.get("tabs") or []),
                }})
        facts["reasons"] = reasons
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
