"""Answer wording (stories 6.5, 6.6 and 7.9, AD-32, PD-13, PD-14).

Offline: fixed templates turn the ranker's facts into the answer. Always computed.
Claude: only when ANTHROPIC_API_KEY is set. One messages.create call rewrites the reason
sentences. Claude sees the sentences only, with place names masked: no rows, names or ids.
The reply must keep every number and placeholder, and pass the same checks as the offline
answer; anything else gives the offline answer with mode `offline_fallback`.

The answer copies the hearts360ai supervision prototype (story 7.9): each reason names the
problem with its numbers, a sized next step, and the evidence behind it (`evidence`: the monthly
series or a small table, a definition, the place and month, and `See this in Reports: <tab>`),
which the widget opens on hover or focus. Numbers are shown as DESIGN asks (whole percents, one
decimal under 10%, thousands commas); each rounding is recorded in `derived` with its input, so
the number check still traces every figure to a registry function.

The server appends the honesty line after the checks. It never goes through Claude.
"""

from __future__ import annotations

import copy
import json
import logging
import re
from decimal import Decimal
from typing import Any

from h360_api.ranker import MONTHS, TABS, apply_rule, dec, derive, plain

HONESTY = (
    "These actions explain only 2% to 12% of why one facility does better than another. "
    "Treat them as the best next steps, not a promise."
)
NO_MATCH = "I can only answer the questions above. Pick one."
PICK_DISTRICT_LINE = "Pick a district or a facility to ask a question."
# UX-30: the overdue list keeps its own order, so the plan never says "longest overdue first".
PLAN_TEXT = "Start at the top of the overdue list, with patients not called yet."

MAX_SENTENCE_WORDS = 20
MAX_ANSWER_WORDS = 150
CLAUDE_TIMEOUT_S = 8.0
CLAUDE_MAX_TOKENS = 1024

# A number token: 1,401 or 27.9 or 5. Commas are thousands separators (UX-23).
_NUMBER = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?")
_BANNED = re.compile(r"\bwill\b|guarantee|fudg", re.IGNORECASE)
_SENTENCE_END = re.compile(r"(?<=[.?!])\s+")
_PLACEHOLDER = re.compile(r"\{p\d+\}")

LOG = logging.getLogger("h360_api.chat")

NUDGE_LABELS = {
    "call_plan": "How many patients should I call?",
    "overdue_list": "Open the overdue list",
    "overdue_pick": "Pick a facility to open its overdue list",
    "open_stepping_up": "Open Stepping up",
    "step_up_least": "Which facilities step up least?",
    "open_bp_readings_check": "Open BP readings check",
    "patient_list": "Open the patient list",
}

TOO_FEW = {
    "why_control_low": "There are too few patients here to find a clear reason.",
    "titration": "There are too few high BP visits here to count.",
    "readings": "There are too few BP readings here to check.",
    "statins": "There are too few eligible patients here to count.",
}

# A district breach as a plain sentence (owner's clear-writing rules: lead with the fact, no jargon).
BREACH_SENTENCES = {
    "control_below_pct": ("Only {pct} of patients have BP controlled.", "controlled_pct"),
    "missed_visit_above_pct": ("Many patients miss visits ({pct}).", "missed_visit_pct"),
    "ltfu_above_pct": ("Many patients have stopped coming ({pct}).", "ltfu_pct"),
}

# What each flagged report means, in everyday words.
FLAG_SENTENCES = {
    "Overdue-calls": "Few overdue patients are called.",
    "Stepping-up": "Medicine is rarely stepped up.",
    "BP-readings-check": "Many BP readings sit just under 140.",
    "Statins": "Few eligible patients are on a statin.",
}
FLAG_SHORT = {"BP readings check": "BP readings", "Stepping up": "stepping up"}
# The same sentences inside another one, by tab name: "many BP readings sit just under 140".
FLAG_PHRASES = {TABS[slug]: s[0].lower() + s[1:-1] for slug, s in FLAG_SENTENCES.items()}

# The tag on each reason, as the prototype's issue chips.
TAGS = {
    "overdue_calling": "Overdue calling",
    "titration_rate": "Stepping up",
    "new_patient_return": "New patients",
    "phone_capture": "Phone numbers",
    "fudging_score": "BP readings",
    "statin_gap": "Statins",
}

# Where a district manager starts on a visit, by the first report a facility is flagged on.
VISIT_ACTION = {
    "Overdue-calls": "Start with the overdue list.",
    "Stepping-up": "Start with the patients whose medicine was not stepped up.",
    "BP-readings-check": "Start by watching BP being measured.",
    "Statins": "Start with the statin patient list.",
}

WINDOW_NOTE = "Each month counts the 3 months to that month, as the Reports tab does."


# ---------------------------------------------------------------------------- links


def report_url(slug: str, org_unit_id: Any, month: str) -> str:
    """AD-29 link with the PD-4 slug, the scope node id and the month (UX-20)."""
    return f"/d/heart360_reports?var-org_unit={org_unit_id}&var-reporting_month={month}&-dtab={slug}"


def overdue_list_url(org_unit_id: Any, month: str | None = None) -> str:
    tail = f"&var-reporting_month={month}" if month else ""
    return f"/d/heart360_showcase?var-org_unit={org_unit_id}{tail}&-dtab=Overdue-list"


def dashboard_url(org_unit_id: Any, month: str) -> str:
    return f"/d/heart360_showcase?var-org_unit={org_unit_id}&var-reporting_month={month}"


def stock_url(org_unit_id: Any, month: str) -> str:
    return f"/d/heart360_drug_stock?var-org_unit={org_unit_id}&var-reporting_month={month}"


def _link(slug: str, org_unit_id: Any, month: str) -> dict:
    return {"label": TABS[slug], "url": report_url(slug, org_unit_id, month)}


def _see(slug: str, org_unit_id: Any, month: str) -> dict:
    return {"label": "See this in Reports: " + TABS[slug], "url": report_url(slug, org_unit_id, month)}


def _join(items: list[str]) -> str:
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


# ---------------------------------------------------------------------------- number format (UX-23)


class Fmt:
    """Formats numbers as DESIGN asks and records each rounding in `derived`."""

    def __init__(self, derived: list[dict]) -> None:
        self.derived = derived

    def _record(self, rule: str, value: Any) -> str:
        return derive(self.derived, rule, value)

    def _shown(self, value: Any, rule: str) -> str:
        d = dec(value)
        rounded = plain(apply_rule(rule, [d]))
        return rounded if rounded == plain(d) else self._record(rule, value)

    def pct(self, value: Any) -> str:
        """Whole percents, one decimal under 10% (DESIGN)."""
        d = dec(value)
        if d is None:
            return "?"
        if abs(d) < 10 and d != 0:
            shown = self._shown(value, "round1")
            return (shown if "." in shown else shown + ".0") + "%"
        return self._shown(value, "round0") + "%"

    def ratio(self, value: Any) -> str:
        d = dec(value)
        if d is None:
            return "?"
        shown = self._shown(value, "round1")
        return shown if "." in shown else shown + ".0"

    def whole(self, value: Any) -> str:
        if dec(value) is None:
            return "?"
        return self.count(self._shown(value, "round0"))

    @staticmethod
    def count(value: Any) -> str:
        d = dec(value)
        if d is None:
            return "?"
        if d == d.to_integral_value():
            return f"{int(d):,}"
        return plain(d)


def _month_name(iso: str) -> str:
    return MONTHS[int(iso[5:7]) - 1]


def _window_label(facts: dict, fmt: Fmt) -> str:
    w = facts["window"]
    start, end = w["start"], w["end"]
    if w["start_year"] == w["end_year"]:
        return f"{_month_name(start)}–{_month_name(end)} {w['end_year']}"
    year = derive(fmt.derived, "sub", w["end_year"], 1)
    return f"{_month_name(start)} {year}–{_month_name(end)} {w['end_year']}"


def _short_month(iso: str) -> str:
    return f"{_month_name(iso)}-{iso[:4]}"


# ---------------------------------------------------------------------------- evidence (UX-10)

LINE_SPECS = {
    "control": {
        "title": "BP controlled",
        "definition": "Patients registered before the last 3 months whose last BP, in the last 3 months, "
                      "was below 140/90.",
        "num_label": "patients with BP controlled", "den_label": "patients under care",
        "unit": "%", "monthly": True,
    },
    "overdue_calling": {
        "title": "Overdue patients called",
        "definition": "Overdue patients with a phone who were called.",
        "num_label": "patients called", "den_label": "overdue with a phone",
        "unit": "%", "target_key": "chat.called_below_pct", "lower_is_better": False,
    },
    "titration_rate": {
        "title": "Stepping up",
        "definition": "High BP visits where medicine was stepped up.",
        "num_label": "visits stepped up", "den_label": "high BP visits",
        "unit": "%", "target_key": "chat.titration_below_pct", "lower_is_better": False,
    },
    "new_patient_return": {
        "title": "New patients not coming back",
        "definition": "New patients with no second visit.",
        "num_label": "did not come back", "den_label": "new patients",
        "unit": "%", "target_key": "chat.new_loss_above_pct", "lower_is_better": True,
    },
    "phone_capture": {
        "title": "Usable phone numbers",
        "definition": "New patients with a usable phone number.",
        "num_label": "with a usable phone", "den_label": "new patients",
        "unit": "%", "target_key": "chat.usable_phone_below_pct", "lower_is_better": False,
    },
    "fudging_score": {
        "title": "BP readings check",
        "definition": "Readings of 130–139 for every reading of 140–149, per quarter. 2.0 or more is a reason "
                      "to check how BP is measured, not proof. Quarters with under 20 readings are not drawn.",
        "num_label": "readings of 130–139", "den_label": "readings of 140–149",
        "unit": "", "decimals": 1, "target_key": "fudging.flag_ratio", "lower_is_better": True,
    },
    "statin_gap": {
        "title": "Statins",
        "definition": "Eligible patients who are on a statin.",
        "num_label": "on a statin", "den_label": "eligible patients",
        "unit": "%", "target_key": "statins.flag_below_pct", "lower_is_better": False,
    },
}


QUARTER_SPEC = {
    "title": "BP readings check",
    "definition": "Readings of 130–139 for every reading of 140–149, by completed quarter. 2.0 or more "
                  "is a reason to check how BP is measured, not proof.",
    "num_label": "readings of 130–139", "den_label": "readings of 140–149",
    "unit": "", "decimals": 2, "target_key": "fudging.flag_ratio", "lower_is_better": True, "monthly": True,
}
MONTHLY_NOTE = "The grey line is the average of all facilities."


def _line_evidence(name: str, points: list[dict], facts: dict, link: dict | None, place: str | None = None) -> dict | None:
    if not points or all(p.get("value") is None for p in points):
        return None
    spec = dict(LINE_SPECS[name])
    quarterly = any("label" in p for p in points)
    averaged = any(p.get("average") is not None for p in points)
    if name == "fudging_score" and quarterly:
        spec = QUARTER_SPEC
    if averaged:
        spec["monthly"] = True
        spec["definition"] = spec["definition"] + " " + MONTHLY_NOTE
    target = None
    target_label = None
    if spec.get("target_key"):
        target = facts["thresholds"].get(spec["target_key"])
        target_label = ("Flag above " if spec.get("lower_is_better") else "Flag below ") + target + spec["unit"]
    definition = spec["definition"]
    if not spec.get("monthly"):
        definition += " " + WINDOW_NOTE
    return {
        "kind": "line",
        "title": spec["title"],
        "definition": definition,
        "place": place or facts["place"]["name"],
        "unit": spec["unit"],
        "decimals": spec.get("decimals", 0),
        "points": [dict(p, label=p.get("label") or _short_month(p["month"])) for p in points],
        "num_label": spec["num_label"],
        "den_label": spec["den_label"],
        "target": target,
        "target_label": target_label,
        "lower_is_better": bool(spec.get("lower_is_better")),
        "link": link,
    }


def _stock_evidence(facts: dict) -> dict | None:
    rows = facts.get("stock_rows") or []
    if not rows:
        return None
    node, month = facts["place"]["org_unit_id"], facts["month"]
    return {
        "kind": "table",
        "title": "Medicine stock",
        "definition": "Patient days of stock for each protocol medicine group. Under "
                      + facts["thresholds"]["chat.stock_days_below"] + " days is low.",
        "place": facts["place"]["name"],
        "columns": ["Medicine group", "Patient days"],
        "rows": [{"cells": [r["category"], "out of stock" if dec(r["patient_days"]) == 0 else
                            Fmt.count(apply_rule("round0", [dec(r["patient_days"])]))],
                  "flag": bool(r["low"])} for r in rows if dec(r["patient_days"]) is not None],
        "link": {"label": "See this in Medicine stock", "url": stock_url(node, month)},
    }


def _facility_table_evidence(facts: dict, focus: int, slug: str) -> dict | None:
    rows = facts.get("facility_table") or []
    if not rows:
        return None
    t = facts["thresholds"]
    month = facts["month"]
    return {
        "kind": "table",
        "title": "Facilities in " + facts["place"]["name"],
        "definition": "BP controlled and missed visits in " + facts["month_label"]
                      + ", and the reports each facility is flagged on.",
        "place": facts["place"]["name"],
        "columns": ["Facility", "BP controlled", "Missed visits", "Flagged on"],
        "target": ["Line", t["chattogram.control_below_pct"] + "% or more",
                   t["chattogram.missed_visit_above_pct"] + "% or less", ""],
        "rows": [{"cells": [r["name"],
                            _plain_pct(r["controlled_pct"]),
                            _plain_pct(r["missed_visit_pct"]),
                            ", ".join(TABS[s] for s in r["flags"]) or "None"],
                  "focus": r["org_unit_id"] == focus} for r in rows],
        "link": _see(slug, focus, month),
    }


def _plain_pct(value: Any) -> str:
    d = dec(value)
    if d is None:
        return "–"
    if abs(d) < 10 and d != 0:
        return plain(apply_rule("round1", [d])) + "%"
    return plain(apply_rule("round0", [d])) + "%"


# ---------------------------------------------------------------------------- offline templates


def _title(facts: dict) -> str:
    name = facts["place"]["name"]
    chip = facts["chip"]
    if chip == "why_control_low":
        if facts["high_control"]:
            return f"What to check at {name}? Control looks good."
        return f"Why is BP control low at {name}?"
    return {
        "who_to_call": f"Who should I call this week at {name}?",
        "call_plan": f"Calling plan for {name}",
        "medicines_adjusted": f"Are medicines being adjusted at {name}?",
        "readings_reliable": f"Are BP readings reliable at {name}?",
        "statin_gap": f"Who needs a statin at {name}?",
        "visit_first": f"Which facilities should I visit first in {name}?",
    }.get(chip, name)


def _control_line(facts: dict, fmt: Fmt) -> tuple[str | None, str | None]:
    """`In Oct-2026, 1,019 of 1,358 patients had BP controlled (75%), up from 48% in May-2026.`"""
    c = facts.get("control")
    if not c or c.get("too_few") or c.get("controlled_pct") is None:
        return None, None
    figure = fmt.pct(c["controlled_pct"])
    if c.get("controlled_n") is not None and c.get("under_care_n") is not None:
        line = (f"In {facts['month_label']}, {fmt.count(c['controlled_n'])} of {fmt.count(c['under_care_n'])} "
                f"patients had BP controlled ({figure})")
    else:
        line = f"In {facts['month_label']}, {figure} of patients had BP controlled"
    points = [p for p in facts.get("control_series") or [] if p.get("value") is not None]
    if len(points) >= 2 and points[0]["month"] != facts["month"]:
        first = points[0]
        then = fmt.pct(first["value"])
        a, b = dec(apply_rule("round0", [dec(first["value"])])), dec(apply_rule("round0", [dec(c["controlled_pct"])]))
        if b != a:
            word = "up from" if b > a else "down from"
            line += f", {word} {then} in {_short_month(first['month'])}"
    return line + ".", figure


def _calling_sizing(v: dict, fmt: Fmt, facts: dict) -> list[str]:
    const = facts["constants"]
    out = []
    if v.get("facilities_n", 1) > 1:
        out.append(f"One nurse per facility can call about {const['calls_per_nurse_week']} a week, "
                   f"so {fmt.count(v['plan_calls'])} in {const['plan_weeks']} weeks across {v['facilities_n']} facilities.")
    else:
        out.append(f"One nurse can call about {v['per_week']} a week, "
                   f"so {fmt.count(v['plan_calls'])} in {const['plan_weeks']} weeks.")
    if v.get("returning_n") is not None:
        out.append(f"About {fmt.count(v['returning_n'])} may come back, as {fmt.pct(v['returned_pct'])} did here.")
    return out


def _readings(v: dict, kind: str, fmt: Fmt, facts: dict, win: str) -> tuple[str, str]:
    """The readings sentences and their figure. A pattern to check, never proof (UX-09, UX-25)."""
    const = facts["constants"]
    low = f"{const['band_low_from']}–{const['band_low_to']}"
    high = f"{const['band_high_from']}–{const['band_high_to']}"
    if v.get("source") == "quarterly":
        figure = plain(dec(v["score"]))
        period = f"in {v['period']}"
    else:
        figure = fmt.ratio(v["score"])
        period = f"in {win}"
    counts = f"{fmt.count(v['low_n'])} of {low} against {fmt.count(v['high_n'])} of {high} {period}"
    ratio = f"That is {figure} to {const['per_one']}"
    prev = v.get("previous_score")
    # The trend is said where the question is about readings; elsewhere the chart shows it.
    if kind != "no_sign" and facts["chip"] == "readings_reliable" and prev is not None and dec(prev) != dec(v["score"]):
        word = "up" if dec(v["score"]) > dec(prev) else "down"
        # The quarter before, named without its year to keep the sentence short.
        ratio += f", {word} from {plain(dec(prev))} in {v['previous_period'].split(' ')[0]}"
    if kind == "no_sign":
        return f"No sign that readings are rounded down: {counts}. {ratio}.", figure
    return f"Many BP readings sit just under 140: {counts}. {ratio}. This may mean readings are rounded down.", figure


def _reason(r: dict, facts: dict, fmt: Fmt) -> dict:
    v = r["values"]
    lever, kind = r["lever"], r["kind"]
    month = facts["month"]
    node = facts["place"]["org_unit_id"]
    win = _window_label(facts, fmt)
    text, todo, number, figure, link, evidence, tag = "", None, None, None, None, None, TAGS.get(lever)
    if lever == "new_patient_return":
        number = v["new_loss_pct"]
        figure = fmt.pct(v["new_loss_pct"])
        lost = v.get("new_lost_n")
        if lost is not None:
            text = (f"Many new patients do not come back. {fmt.count(lost)} of {fmt.count(v['new_patients_n'])} "
                    f"missed their second visit ({figure}).")
        else:
            text = f"Many new patients do not come back: {figure} missed their second visit."
        todo = "Each week, call new patients who missed their second visit and book a date."
        link = _link("Overdue-calls", node, month)
    elif lever == "phone_capture":
        number = v["new_usable_phone_pct"]
        figure = fmt.pct(number)
        text = (f"Many new patients have no usable phone number. Only {fmt.count(v['new_usable_phone_n'])} "
                f"of {fmt.count(v['new_patients_n'])} do ({figure}).")
        todo = "Check the phone number at every first visit, and look at the gaps each month."
        link = _link("Overdue-calls", node, month)
    elif lever == "overdue_calling":
        link = _link("Overdue-calls", node, month)
        number = v["called_pct"]
        figure = fmt.pct(v["called_pct"])
        counts = f"{fmt.count(v['called_n'])} of {fmt.count(v['overdue_with_phone_n'])}"
        if kind == "plan":
            if not v["overdue_with_phone_n"]:
                number, figure = None, None
                text = "No overdue patients have a phone number this month."
            else:
                # called_n counts first calls in the reporting month only (report_calling), not the window.
                text = f"In {_month_name(month)}, {counts} overdue patients with a phone were called ({figure})."
        elif v.get("called_low") or v.get("early_pct") is None:
            text = f"Only {fmt.count(v['called_n'])} of {fmt.count(v['overdue_with_phone_n'])} overdue patients were called ({figure})."
            todo = " ".join(_calling_sizing(v, fmt, facts))
        else:
            number = v["early_pct"]
            figure = fmt.pct(v["early_pct"])
            text = (f"Most calls come late. Only {fmt.count(v['early_n'])} of {fmt.count(v['called_n'])} "
                    f"came soon after the patient became overdue ({figure}).")
            todo = " ".join(_calling_sizing(v, fmt, facts))
    elif lever == "titration_rate":
        number = v["titration_pct"]
        figure = fmt.pct(v["titration_pct"])
        link = _link("Stepping-up", node, month)
        counts = f"{fmt.count(v['stepped_up_n'])} of {fmt.count(v['uncontrolled_visits_n'])}"
        if kind == "on_target":
            text = (f"Medicine is stepped up often enough. It was stepped up at {counts} high BP visits "
                    f"({figure}).")
            todo = "Keep going through patients not stepped up at the monthly meeting."
        else:
            text = f"Medicine was stepped up at only {counts} high BP visits ({figure})"
            if not r.get("stock_ok"):
                text += "."
            if v.get("not_stepped_up_n") is not None:
                todo = (f"At the monthly meeting, go through the {fmt.count(v['not_stepped_up_n'])} "
                        "high BP visits without a step up.")
            else:
                todo = "At the monthly meeting, go through the high BP visits without a step up."
        if r.get("stock_ok"):
            days = plain(dec(facts["thresholds"]["chat.stock_days_below"]))
            text += f", with over {days} days of stock." if kind != "on_target" else f" Every medicine has over {days} days of stock."
    elif lever == "fudging_score":
        number = v["score"]
        link = _link("BP-readings-check", node, month)
        text, figure = _readings(v, kind, fmt, facts, win)
        if kind == "no_sign":
            todo = "Keep watching BP being measured on each supervision visit."
        else:
            todo = "On your next visit, watch BP being measured and recorded."
    elif lever == "statin_gap":
        number = v["not_on_statin_n"]
        figure = fmt.pct(v["on_statin_pct"])
        link = _link("Statins", node, month)
        text = (f"{fmt.count(v['not_on_statin_n'])} of {fmt.count(v['eligible_n'])} eligible patients are not "
                f"on a statin yet. Only {figure} are.")
        todo = "Each week, check the listed patients due a visit and start a statin if suitable."
    elif lever == "facility_rank_district":
        name = v["name"]
        tag = None  # the sentence starts with the facility's name
        slug = (v.get("flag_slugs") or ["Overdue-calls"])[0]
        link = _link(slug, r["org_unit_id"], month)
        if kind == "visit_also":
            number = v["controlled_pct"]
            figure = fmt.pct(v["controlled_pct"])
            phrases = [FLAG_PHRASES[t] for t in v["tabs"] if t in FLAG_PHRASES]
            text = f"{name} looks good, with {figure} of patients controlled."
            if phrases:
                text += " But " + _join(phrases) + "."
            todo = f"Visit this month and watch BP being measured before you use {name} as an example."
        else:
            number = v["uncontrolled_n"]
            figure = f"{fmt.count(v['uncontrolled_n'])} of {fmt.count(v['under_care_n'])}" \
                if v.get("under_care_n") is not None else fmt.count(v["uncontrolled_n"])
            lead = "the most patients" if r.get("rank_first") else "many patients"
            text = f"{name} has {lead} with high BP: {figure}."
            for key in v["breaches"]:
                sentence, column = BREACH_SENTENCES.get(key, (None, None))
                if sentence and v.get(column) is not None:
                    text += " " + sentence.format(pct=fmt.pct(v[column]))
            for s_ in v.get("flag_slugs") or []:
                if s_ in FLAG_SENTENCES:
                    text += " " + FLAG_SENTENCES[s_]
            todo = f"Visit this month. {VISIT_ACTION.get(slug, 'Start with the reports for this facility.')} " \
                   "Agree two actions with the team and check them weekly."
        evidence = _facility_table_evidence(facts, r["org_unit_id"], slug)
    if r.get("stock_first") and todo:
        todo = "Fix medicine stock first. " + todo
    elif r.get("stock_first"):
        todo = "Fix medicine stock first, then call each week from the top of the overdue list."
    if evidence is None and lever in LINE_SPECS and link is not None:
        evidence = _line_evidence(lever, r.get("series") or [], facts,
                                  {"label": "See this in Reports: " + link["label"], "url": link["url"]})
    return {
        "lever": lever,
        "tag": tag,
        "text": text,
        "number": None if number is None else str(number),
        "figure": figure if figure and figure in text else None,
        "what_to_do": todo,
        "link": link,
        "evidence": evidence,
    }


def _plain_sentence(facts: dict) -> str:
    name = facts["place"]["name"]
    state = facts["state"]
    if state == "no_data":
        if facts["chip"] == "why_control_low":
            return f"There is no data for {name} in {facts['month_label']}, so I can't look for reasons."
        return f"There is no data for {name} in {facts['month_label']}."
    if state == "none":
        return f"No facility in {name} stands out on BP control, missed visits or patients who stopped coming."
    if state == "no_clear_reason":
        return ("No clear reason shows in these reports. Calling, stepping up and new patients' return "
                "are all on target.")
    return TOO_FEW.get(facts.get("too_few_kind") or facts["chip"], TOO_FEW["why_control_low"])


def _also_check(facts: dict, fmt: Fmt) -> str | None:
    a = facts.get("also_check")
    if not a:
        return None
    if a.get("kind") == "self":
        return f"Check these before you use {a['name']} as an example."
    short = [FLAG_SHORT[t] for t in a.get("tabs") or [] if t in FLAG_SHORT] or ["reports"]
    return f"{a['name']} looks good at {fmt.pct(a['controlled_pct'])} controlled, but check its {_join(short)}."


def _stock_line(facts: dict, fmt: Fmt) -> str | None:
    stock = facts.get("stock") or []
    if not stock:
        return None
    parts = []
    for s in stock:
        if dec(s["patient_days"]) == 0:
            parts.append(f"{s['category']} is out of stock.")
        else:
            parts.append(f"Only {fmt.whole(s['patient_days'])} patient days of {s['category']} are left.")
    return ("Fix medicine stock first. " + " ".join(parts)
            + " Check stock weekly and order before two weeks are left.")


def _nudge(facts: dict) -> dict | None:
    n = facts.get("nudge")
    if not n:
        return None
    node = facts["place"]["org_unit_id"]
    kind = n["kind"]
    if kind == "call_plan":
        return {"chip_id": "call_plan", "label": NUDGE_LABELS["call_plan"]}
    if kind == "overdue_list":
        if facts["place"]["scope"] == "facility":
            return {"chip_id": "overdue_list", "label": NUDGE_LABELS["overdue_list"],
                    "url": overdue_list_url(node, facts["month"])}
        # UX-12: above facility level the list is not available; the Overdue calls table is.
        return {"chip_id": "overdue_list", "label": NUDGE_LABELS["overdue_pick"],
                "url": report_url("Overdue-calls", node, facts["month"])}
    if kind == "tab":
        return {"chip_id": n["chip_id"], "label": NUDGE_LABELS[n["chip_id"]],
                "url": report_url(n["slug"], node, facts["month"])}
    if kind == "facility_question":
        return {"chip_id": "why_control_low", "label": f"Why is control low at {n['name']}?",
                "org_unit_id": n["org_unit_id"]}
    return None


def _plan(facts: dict, fmt: Fmt) -> dict | None:
    p = facts.get("plan")
    if not p:
        return None
    v = facts["reasons"][0]["values"] if facts.get("reasons") else {}
    lines = _calling_sizing(dict(v, **p), fmt, facts)
    lines.append(f"The Dr Rai action plan gives one nurse {facts['constants']['calls_per_nurse_week']} calls a week.")
    lines.append(PLAN_TEXT)
    node = facts["place"]["org_unit_id"]
    if facts["place"]["scope"] == "facility":
        list_link = {"label": "Open the overdue list", "url": overdue_list_url(node, facts["month"])}
    else:
        list_link = {"label": NUDGE_LABELS["overdue_pick"], "url": report_url("Overdue-calls", node, facts["month"])}
    return {
        "total": p["total"],
        "weeks": list(p["weeks"]),
        "per_week": p["per_week"],
        "text": " ".join(lines),
        "list_link": list_link,
    }


def render_offline(facts: dict) -> dict:
    """The offline answer, without the honesty line (the server appends it last)."""
    derived = copy.deepcopy(facts.get("derived") or [])
    fmt = Fmt(derived)
    control_line, control_figure = _control_line(facts, fmt)
    node, month = facts["place"]["org_unit_id"], facts["month"]
    answer: dict[str, Any] = {
        "mode": "offline",
        "place": dict(facts["place"]),
        "month": facts["month"],
        "title": _title(facts),
        "control_line": control_line,
        "control_figure": control_figure,
        "control_evidence": None,
        "reasons": [],
        "also_check": None,
        "stock_line": None,
        "stock_evidence": None,
        "nudge": None,
        "plan": None,
        "links": [],
        "derived": derived,
    }
    if control_line and facts.get("control_series"):
        answer["control_evidence"] = _line_evidence(
            "control", facts["control_series"], facts,
            {"label": "See this on the Hypertension dashboard", "url": dashboard_url(node, month)})
    if facts["state"] != "ok":
        answer["reasons"] = [{"lever": None, "tag": None, "text": _plain_sentence(facts), "number": None,
                              "figure": None, "what_to_do": None, "link": None, "evidence": None}]
        return answer
    answer["stock_line"] = _stock_line(facts, fmt)
    if answer["stock_line"]:
        answer["stock_evidence"] = _stock_evidence(facts)
    answer["reasons"] = [_reason(r, facts, fmt) for r in facts["reasons"][:3]]
    answer["also_check"] = _also_check(facts, fmt)
    answer["nudge"] = _nudge(facts)
    answer["plan"] = _plan(facts, fmt)
    seen = set()
    for r in answer["reasons"]:
        if r["link"] and r["link"]["url"] not in seen:
            seen.add(r["link"]["url"])
            answer["links"].append(r["link"])
    return answer


def national_answer(place: dict, month: str) -> dict:
    return {
        "mode": "offline", "place": place, "month": month,
        "title": PICK_DISTRICT_LINE, "control_line": None, "control_figure": None, "control_evidence": None,
        "reasons": [{"lever": None, "tag": None, "text": PICK_DISTRICT_LINE, "number": None, "figure": None,
                     "what_to_do": None, "link": None, "evidence": None}],
        "also_check": None, "stock_line": None, "stock_evidence": None, "nudge": None, "plan": None,
        "links": [], "derived": [],
        "honesty": HONESTY,
    }


# ---------------------------------------------------------------------------- checks (AD-32)


def _leaf_strings(value: Any):
    if isinstance(value, dict):
        for v in value.values():
            yield from _leaf_strings(v)
    elif isinstance(value, (list, tuple)):
        for v in value:
            yield from _leaf_strings(v)
    elif value is not None and not isinstance(value, bool):
        yield str(value)


def norm_number(token: str) -> str:
    """`1,401` -> `1401`, `75.0` -> `75`, `5.40` -> `5.4`."""
    try:
        return plain(Decimal(token.replace(",", "")))
    except Exception:
        return token


def number_tokens(text: str) -> list[str]:
    return [norm_number(t) for t in _NUMBER.findall(text)]


def fact_numbers(facts: dict) -> set[str]:
    """Every number token in the facts' values (keys are not facts), normalised."""
    tokens: set[str] = set()
    for s in _leaf_strings(facts):
        tokens.update(number_tokens(s))
    return tokens


def derived_numbers(answer: dict, allowed: set[str]) -> tuple[set[str], list[str]]:
    """Values in `derived` whose inputs are allowed and whose rule recomputes them."""
    known = set(allowed)
    problems = []
    for d in answer.get("derived") or []:
        inputs = [norm_number(str(i)) for i in d.get("inputs") or []]
        try:
            value = plain(apply_rule(d.get("rule"), [Decimal(i) for i in inputs]))
        except Exception:
            problems.append(f"derived rule failed: {d}")
            continue
        if not all(i in known for i in inputs):
            problems.append(f"derived input not in facts: {d}")
            continue
        if value != norm_number(str(d.get("value"))):
            problems.append(f"derived value does not recompute: {d}")
            continue
        known.add(value)
    return known, problems


def visible_texts(answer: dict) -> list[str]:
    """User-visible strings before the honesty line, in card order."""
    out = [answer.get("title"), answer.get("control_line"), answer.get("stock_line")]
    for r in answer.get("reasons") or []:
        out += [r.get("text"), r.get("what_to_do")]
    out += [answer.get("also_check")]
    if answer.get("nudge"):
        out.append(answer["nudge"].get("label"))
    if answer.get("plan"):
        out.append(answer["plan"].get("text"))
    return [s for s in out if isinstance(s, str) and s]


def sentences(text: str) -> list[str]:
    return [s for s in _SENTENCE_END.split(text.strip()) if s]


def check_answer(answer: dict, facts: dict | None) -> list[str]:
    """Problems with an answer; empty when it passes every AD-32 check."""
    problems = []
    texts = visible_texts(answer)
    allowed = None
    if facts is not None:
        allowed, derived_problems = derived_numbers(answer, fact_numbers(facts))
        problems += derived_problems
    total = 0
    for text in texts:
        if _BANNED.search(text):
            problems.append("banned word")
        for s in sentences(text):
            words = len(s.split())
            total += words
            if words > MAX_SENTENCE_WORDS:
                problems.append("sentence over 20 words")
        if allowed is not None:
            for tok in number_tokens(text):
                if tok not in allowed:
                    problems.append(f"number not in facts: {tok}")
    if total > MAX_ANSWER_WORDS:
        problems.append("over 150 words")
    return problems


# ---------------------------------------------------------------------------- Claude (story 6.6)

SYSTEM_PROMPT = (
    "You reword short sentences for a busy district health manager reading a hypertension report. "
    "Rules: keep every number exactly as written, with no new, dropped, rounded or reformatted numbers. "
    "Keep every placeholder such as {p0} exactly as written. "
    "Use plain words and sentence case, at most 20 words in each sentence. "
    "Never use the words will, guarantee, guaranteed or guarantees; say may or could. "
    "Do not add facts, advice, names or abbreviations other than BP. "
    "Reply with only a JSON object that has exactly the same keys, each value one reworded sentence or two."
)


def _mask_names(facts: dict) -> list[tuple[str, str]]:
    names = [facts["place"]["name"]]
    for r in facts.get("reasons") or []:
        name = (r.get("values") or {}).get("name")
        if name:
            names.append(name)
    if facts.get("also_check"):
        names.append(facts["also_check"]["name"])
    unique = []
    for n in names:
        if n and n not in unique:
            unique.append(n)
    unique.sort(key=len, reverse=True)
    return [(n, "{p%d}" % i) for i, n in enumerate(unique)]


def _mask(text: str, pairs: list[tuple[str, str]]) -> str:
    for name, ph in pairs:
        text = text.replace(name, ph)
    return text


def _unmask(text: str, pairs: list[tuple[str, str]]) -> str:
    for name, ph in pairs:
        text = text.replace(ph, name)
    return text


def claude_sentences(answer: dict) -> dict[str, str]:
    out = {}
    for i, r in enumerate(answer.get("reasons") or []):
        if r.get("text"):
            out[f"r{i}_text"] = r["text"]
        if r.get("what_to_do"):
            out[f"r{i}_what_to_do"] = r["what_to_do"]
    if answer.get("also_check"):
        out["also_check"] = answer["also_check"]
    return out


def claude_payload(answer: dict, facts: dict) -> tuple[dict, list[tuple[str, str]]]:
    """The user message for Claude: masked sentences only."""
    pairs = _mask_names(facts)
    masked = {k: _mask(v, pairs) for k, v in claude_sentences(answer).items()}
    return {"sentences": masked}, pairs


def _reply_text(response: Any) -> str:
    parts = []
    for block in getattr(response, "content", None) or []:
        if getattr(block, "type", None) == "text":
            parts.append(getattr(block, "text", "") or "")
    return "".join(parts)


def _parse_reply(text: str) -> dict | None:
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(text[start:end + 1])
    except ValueError:
        return None
    if isinstance(data, dict) and isinstance(data.get("sentences"), dict):
        data = data["sentences"]
    return data if isinstance(data, dict) else None


def claude_rewrite(answer: dict, facts: dict, client: Any, model: str) -> dict | None:
    """One messages.create call. Returns the reworded answer, or None on any failure or check."""
    payload, pairs = claude_payload(answer, facts)
    original = payload["sentences"]
    if not original:
        return None
    try:
        response = client.messages.create(
            model=model,
            max_tokens=CLAUDE_MAX_TOKENS,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": json.dumps(payload, ensure_ascii=False)}],
            # Thinking off: on Sonnet 5.5 it is on by default and its tokens count against max_tokens.
            # between_tools is Sonnet 5.5's off switch ({"type": "disabled"} is a 400 there).
            thinking={"type": "between_tools"},
            timeout=CLAUDE_TIMEOUT_S,
        )
    except Exception as exc:  # timeout, network, auth, rate limit: never log the message or the key
        LOG.warning("chat claude fallback: %s", type(exc).__name__)
        return None
    if getattr(response, "stop_reason", None) == "refusal":
        LOG.warning("chat claude fallback: refusal")
        return None
    reply = _parse_reply(_reply_text(response))
    if reply is None or set(reply) != set(original):
        LOG.warning("chat claude fallback: reply shape")
        return None
    rewritten = {}
    for key, old in original.items():
        new = reply.get(key)
        if not isinstance(new, str) or not new.strip():
            LOG.warning("chat claude fallback: empty sentence")
            return None
        new = " ".join(new.split())
        if sorted(_PLACEHOLDER.findall(new)) != sorted(_PLACEHOLDER.findall(old)) or "{" in _PLACEHOLDER.sub("", new):
            LOG.warning("chat claude fallback: placeholder")
            return None
        if sorted(number_tokens(new)) != sorted(number_tokens(old)):
            LOG.warning("chat claude fallback: numbers changed")
            return None
        rewritten[key] = _unmask(new, pairs)
    out = copy.deepcopy(answer)
    for i, r in enumerate(out["reasons"]):
        r["text"] = rewritten.get(f"r{i}_text", r["text"])
        r["what_to_do"] = rewritten.get(f"r{i}_what_to_do", r["what_to_do"])
        if r.get("figure") and r["figure"] not in (r["text"] or ""):
            r["figure"] = None  # the widget then offers the evidence as a button
    if out.get("also_check"):
        out["also_check"] = rewritten.get("also_check", out["also_check"])
    if check_answer(out, facts):
        LOG.warning("chat claude fallback: checks")
        return None
    out["mode"] = "claude"
    return out


def make_claude_client(api_key: str) -> Any:
    import anthropic

    return anthropic.Anthropic(api_key=api_key, timeout=CLAUDE_TIMEOUT_S, max_retries=0)


def compose(facts: dict, api_key: str, model: str, client_factory=make_claude_client) -> dict:
    """Offline answer, or Claude's wording when a key is set; honesty appended last."""
    answer = render_offline(facts)
    if api_key and facts["state"] == "ok" and claude_sentences(answer):
        try:
            client = client_factory(api_key)
        except Exception as exc:
            LOG.warning("chat claude fallback: %s", type(exc).__name__)
            client = None
        worded = claude_rewrite(answer, facts, client, model) if client is not None else None
        if worded is not None:
            answer = worded
        else:
            answer["mode"] = "offline_fallback"
    answer["honesty"] = HONESTY
    return answer
