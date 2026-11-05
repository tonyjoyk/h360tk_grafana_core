"""Answer wording (stories 6.5 and 6.6, AD-32, PD-13, PD-14).

Offline: fixed templates turn the ranker's facts into the answer. Always computed.
Claude: only when ANTHROPIC_API_KEY is set. One messages.create call rewrites the reason
sentences. Claude sees the sentences only, with place names masked: no rows, names or ids.
The reply must keep every number and placeholder, and pass the same checks as the offline
answer; anything else gives the offline answer with mode `offline_fallback`.

The server appends the honesty line after the checks. It never goes through Claude.
"""

from __future__ import annotations

import copy
import json
import logging
import re
from typing import Any

from h360_api.ranker import TABS

HONESTY = (
    "These actions explain only 2% to 12% of why one facility does better than another. "
    "Treat them as the best next steps, not a promise."
)
NO_MATCH = "I can only answer the questions above. Pick one."
PICK_DISTRICT_LINE = "Pick a district or a facility to ask a question."
PLAN_TEXT = "Start with the patients overdue longest."

MAX_SENTENCE_WORDS = 20
MAX_ANSWER_WORDS = 150
CLAUDE_TIMEOUT_S = 8.0
CLAUDE_MAX_TOKENS = 1024

_NUMBER = re.compile(r"\d+(?:\.\d+)?")
_BANNED = re.compile(r"\bwill\b|guarantee|fudg", re.IGNORECASE)
_SENTENCE_END = re.compile(r"(?<=[.?!])\s+")
_PLACEHOLDER = re.compile(r"\{p\d+\}")

LOG = logging.getLogger("h360_api.chat")

NUDGE_LABELS = {
    "call_plan": "How many patients should I call?",
    "overdue_list": "Who is overdue longest?",
    "open_stepping_up": "Open Stepping up",
    "step_up_least": "Which facilities step up least?",
    "open_bp_readings_check": "Open BP readings check",
    "patient_list": "Open the patient list",
}

TOO_FEW = {
    "why_control_low": "Too few patients here to rank reasons.",
    "titration": "Too few high BP visits here to count.",
    "readings": "Too few BP readings here to check.",
    "statins": "Too few eligible patients here to count.",
}

BREACH_WORDS = {
    "control_below_pct": ("BP controlled", "controlled_pct"),
    "uncontrolled_above_pct": ("BP not controlled", "uncontrolled_pct"),
    "missed_visit_above_pct": ("missed visits", "missed_visit_pct"),
    "ltfu_above_pct": ("patients not coming back", "ltfu_pct"),
}


# ---------------------------------------------------------------------------- links


def report_url(slug: str, org_unit_id: Any, month: str) -> str:
    """AD-29 link with the PD-4 slug and the scope node id."""
    return f"/d/heart360_reports?var-org_unit={org_unit_id}&var-reporting_month={month}&-dtab={slug}"


def overdue_list_url(org_unit_id: Any) -> str:
    return f"/d/heart360_showcase?var-org_unit={org_unit_id}&-dtab=Overdue-list"


def _link(slug: str, org_unit_id: Any, month: str) -> dict:
    return {"label": TABS[slug], "url": report_url(slug, org_unit_id, month)}


def _join(items: list[str]) -> str:
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


# ---------------------------------------------------------------------------- offline templates


def _title(facts: dict) -> str:
    name = facts["place"]["name"]
    chip = facts["chip"]
    if chip == "why_control_low":
        if facts["high_control"]:
            return f"What to check at {name}? {facts['control']['controlled_pct']}% controlled, looks fine."
        return f"Why is BP control low at {name}?"
    return {
        "who_to_call": f"Who should I call this week at {name}?",
        "call_plan": f"Calling plan for {name}",
        "medicines_adjusted": f"Are medicines being adjusted at {name}?",
        "readings_reliable": f"Are BP readings reliable at {name}?",
        "statin_gap": f"Who needs a statin at {name}?",
        "visit_first": f"Which facilities should I visit first in {name}?",
    }.get(chip, name)


def _control_line(facts: dict) -> str | None:
    c = facts.get("control")
    if not c or c.get("too_few") or c.get("controlled_pct") is None:
        return None
    return f"{c['controlled_pct']}% controlled in {facts['month_label']}"


def _reason(r: dict, facts: dict) -> dict:
    v = r["values"]
    lever, kind = r["lever"], r["kind"]
    const = facts["constants"]
    month = facts["month"]
    node = facts["place"]["org_unit_id"]
    text, todo, number, link = "", None, None, None
    # What to do: one specific action with a number or a cadence (Dr Rai action plans), <= 20 words.
    if lever == "new_patient_return":
        number = v["new_loss_pct"]
        counts = f"({v['new_returned_n']} of {v['new_patients_n']} came back)"
        if kind == "on_target":
            text = f"On target: {v['new_loss_pct']}% of new patients did not come back for a second visit {counts}."
            todo = "Each week, keep calling new patients who miss their second visit."
        else:
            text = f"{v['new_loss_pct']}% of new patients did not come back for a second visit {counts}."
            todo = "Each week, call every new patient who missed a second visit and book a date."
        link = _link("Overdue-calls", node, month)
    elif lever == "phone_capture":
        number = v["new_usable_phone_pct"]
        counts = f"({v['new_usable_phone_n']} of {v['new_patients_n']})"
        if kind == "on_target":
            text = f"On target: {v['new_usable_phone_pct']}% of new patients have a usable phone number {counts}."
            todo = "Keep checking the phone number at every first visit."
        else:
            text = f"Only {v['new_usable_phone_pct']}% of new patients have a usable phone number {counts}."
            todo = "Record and check a phone number at every first visit; review the gaps each month."
        link = _link("Overdue-calls", node, month)
    elif lever == "overdue_calling":
        link = _link("Overdue-calls", node, month)
        called = f"{v['called_pct']}% of overdue patients with a phone were called ({v['called_n']} of {v['overdue_with_phone_n']})."
        if kind == "plan":
            number = v["overdue_with_phone_n"]
            if not v["overdue_with_phone_n"]:
                text = "No overdue patients with a phone this month."
            else:
                number = v["called_pct"]
                text = called[0].upper() + called[1:]
                todo = f"Assign one nurse to call {v['week_1']} overdue patients each week, longest overdue first."
        elif kind == "on_target":
            number = v["called_pct"]
            text = "On target: " + called
            todo = f"Keep one nurse calling {v['calls_per_week']} overdue patients each week."
        else:
            if v.get("called_low") or v.get("early_pct") is None:
                number = v["called_pct"]
                text = "Only " + called
            else:
                number = v["early_pct"]
                text = (f"Only {v['early_pct']}% of calls were early, soon after the patient became overdue "
                        f"({v['early_n']} of {v['called_n']}).")
            todo = f"Assign one nurse to call {v['calls_per_week']} overdue patients each week, longest overdue first."
    elif lever == "titration_rate":
        number = v["titration_pct"]
        link = _link("Stepping-up", node, month)
        counts = f"({v['stepped_up_n']} of {v['uncontrolled_visits_n']})"
        if kind == "on_target":
            text = f"On target: medicine was stepped up at {v['titration_pct']}% of high BP visits {counts}."
            todo = "Review the stepped-up share in the monthly facility meeting."
        else:
            text = f"Medicine was stepped up at only {v['titration_pct']}% of high BP visits {counts}."
            todo = "Run one case-based review of patients not stepped up each month."
    elif lever == "fudging_score":
        number = v["score"]
        link = _link("BP-readings-check", node, month)
        counts = f"({v['band_135_139_n']} against {v['band_140_144_n']})"
        if kind == "no_sign":
            text = (f"No sign of rounding down: {v['score']} readings just under {const['bp_line']} "
                    f"for every {const['per_one']} just over {counts}.")
            todo = "Keep checking every BP cuff once a month."
        else:
            text = (f"{v['score']} readings just under {const['bp_line']} for every {const['per_one']} "
                    f"just over {counts}.")
            todo = "Check every BP cuff and retrain staff on measuring BP this month."
    elif lever == "statin_gap":
        number = v["not_on_statin_n"]
        link = _link("Statins", node, month)
        text = (f"{v['not_on_statin_n']} of {v['eligible_n']} eligible patients are not on a statin "
                f"({v['on_statin_pct']}% are).")
        todo = "Each week, review listed patients due a visit and start a statin if suitable."
    elif lever == "facility_rank_district":
        name = v["name"]
        number = v["uncontrolled_n"]
        if kind == "visit_also":
            number = v["controlled_pct"]
            tabs = _join(v["tabs"]) or "a report"
            text = f"{name} looks fine at {v['controlled_pct']}% controlled, but is flagged on {tabs}."
            todo = "Visit this month to check BP cuffs and review patients not stepped up."
            link = _link("BP-readings-check", r["org_unit_id"], month)
        else:
            parts = []
            for key in v["breaches"]:
                words, column = BREACH_WORDS.get(key, (None, None))
                if words and v.get(column) is not None:
                    parts.append(f"{words} ({v[column]}%)")
            of_n = f" of {v['under_care_n']}" if v.get("under_care_n") is not None else ""
            text = f"{name} has {v['uncontrolled_n']}{of_n} patients with BP not controlled."
            if parts:
                text += f" Past the line on {_join(parts)}."
            todo = "Visit this month and agree two actions with the team, with a weekly check."
    if r.get("stock_first") and todo:
        todo = "Fix stock first. " + todo
    elif r.get("stock_first"):
        todo = "Fix stock first."
    return {
        "lever": lever,
        "text": text,
        "number": None if number is None else str(number),
        "what_to_do": todo,
        "link": link,
    }


def _plain_sentence(facts: dict) -> str:
    name = facts["place"]["name"]
    state = facts["state"]
    if state == "no_data":
        if facts["chip"] == "why_control_low":
            return f"There is no data for {name} in {facts['month_label']}, so I can't rank reasons."
        return f"There is no data for {name} in {facts['month_label']}."
    if state == "none":
        return f"No facility in {name} is past the lines for BP control, missed visits or patients not coming back."
    return TOO_FEW.get(facts.get("too_few_kind") or facts["chip"], TOO_FEW["why_control_low"])


def _also_check(facts: dict) -> str | None:
    a = facts.get("also_check")
    if not a:
        return None
    tabs = _join(list(a.get("tabs") or [])) or "a report"
    return f"{a['name']} looks fine at {a['controlled_pct']}% controlled, but is flagged on {tabs}."


def _stock_line(facts: dict) -> str | None:
    stock = facts.get("stock") or []
    if not stock:
        return None
    parts = [f"{s['category']} has {s['patient_days']} patient-days left" for s in stock]
    return "Fix drug stock first: " + ", ".join(parts) + ". Check stock weekly and order before two weeks are left."


def _nudge(facts: dict) -> dict | None:
    n = facts.get("nudge")
    if not n:
        return None
    node = facts["place"]["org_unit_id"]
    kind = n["kind"]
    if kind == "call_plan":
        return {"chip_id": "call_plan", "label": NUDGE_LABELS["call_plan"]}
    if kind == "overdue_list":
        return {"chip_id": "overdue_list", "label": NUDGE_LABELS["overdue_list"], "url": overdue_list_url(node)}
    if kind == "tab":
        return {"chip_id": n["chip_id"], "label": NUDGE_LABELS[n["chip_id"]],
                "url": report_url(n["slug"], node, facts["month"])}
    if kind == "facility_question":
        return {"chip_id": "why_control_low", "label": f"Why is control low at {n['name']}?",
                "org_unit_id": n["org_unit_id"]}
    return None


def render_offline(facts: dict) -> dict:
    """The offline answer, without the honesty line (the server appends it last)."""
    answer: dict[str, Any] = {
        "mode": "offline",
        "place": dict(facts["place"]),
        "month": facts["month"],
        "title": _title(facts),
        "control_line": _control_line(facts),
        "reasons": [],
        "also_check": None,
        "stock_line": None,
        "nudge": None,
        "plan": None,
        "links": [],
    }
    if facts["state"] != "ok":
        answer["reasons"] = [{"lever": None, "text": _plain_sentence(facts), "number": None,
                              "what_to_do": None, "link": None}]
        return answer
    answer["reasons"] = [_reason(r, facts) for r in facts["reasons"][:3]]
    answer["also_check"] = _also_check(facts)
    answer["stock_line"] = _stock_line(facts)
    answer["nudge"] = _nudge(facts)
    if facts.get("plan"):
        answer["plan"] = {"total": facts["plan"]["total"], "weeks": list(facts["plan"]["weeks"]), "text": PLAN_TEXT}
    seen = set()
    for r in answer["reasons"]:
        if r["link"] and r["link"]["url"] not in seen:
            seen.add(r["link"]["url"])
            answer["links"].append(r["link"])
    return answer


def national_answer(place: dict, month: str) -> dict:
    return {
        "mode": "offline", "place": place, "month": month,
        "title": PICK_DISTRICT_LINE, "control_line": None,
        "reasons": [{"lever": None, "text": PICK_DISTRICT_LINE, "number": None, "what_to_do": None, "link": None}],
        "also_check": None, "stock_line": None, "nudge": None, "plan": None, "links": [],
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


def fact_numbers(facts: dict) -> set[str]:
    """Every number token in the facts' values (keys are not facts)."""
    tokens: set[str] = set()
    for s in _leaf_strings(facts):
        tokens.update(_NUMBER.findall(s))
    return tokens


def visible_texts(answer: dict) -> list[str]:
    """User-visible strings before the honesty line, in card order."""
    out = [answer.get("title"), answer.get("control_line")]
    for r in answer.get("reasons") or []:
        out += [r.get("text"), r.get("what_to_do")]
    out += [answer.get("also_check"), answer.get("stock_line")]
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
    allowed = fact_numbers(facts) if facts is not None else None
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
            for tok in _NUMBER.findall(text):
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
            timeout=CLAUDE_TIMEOUT_S,
        )
    except Exception as exc:  # timeout, network, auth, rate limit: never log the message or the key
        LOG.warning("chat claude fallback: %s", type(exc).__name__)
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
        if sorted(_NUMBER.findall(new)) != sorted(_NUMBER.findall(old)):
            LOG.warning("chat claude fallback: numbers changed")
            return None
        rewritten[key] = _unmask(new, pairs)
    out = copy.deepcopy(answer)
    for i, r in enumerate(out["reasons"]):
        r["text"] = rewritten.get(f"r{i}_text", r["text"])
        r["what_to_do"] = rewritten.get(f"r{i}_what_to_do", r["what_to_do"])
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
