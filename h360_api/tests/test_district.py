"""District answers: visit_first (story 6.7, AD-31). Fixed facts, no database."""

from __future__ import annotations

import copy
import unittest
from decimal import Decimal as D

from h360_api import ranker, registry, wording
from h360_api.tests.test_ranker import ADMIN
from h360_api.tests.test_registry import (
    ALL_KEYS, ALL_LIVE, DISTRICT, FACILITY, MONTH, UNITS, FakeChatDb, ask, chat_client, chips,
)


def district_with(rank: dict[int, dict], extra: dict[int, str] | None = None):
    """District 10 with facilities 11, 47 and any extra ids (copied from PHC-A) with given rank rows."""
    data = copy.deepcopy(FACILITY)
    district = copy.deepcopy(DISTRICT)
    for oid, name in (extra or {}).items():
        UNITS.setdefault(oid, (name, 3, 10))
        data[oid] = copy.deepcopy(FACILITY[3])
        district[10]["children"].append(oid)
    for oid, row in rank.items():
        data[oid]["rank"] = row
    return data, district


def visit_facts(data=None, district=None, live=ALL_KEYS):
    db = FakeChatDb(data=data, district=district)
    fetch = registry.Fetcher(db, MONTH)
    place = registry.resolve_place(db, fetch, ADMIN, 10)
    return ranker.build_facts("visit_first", place, fetch, frozenset(live))


class VisitFirstTests(unittest.TestCase):
    def test_demo_district(self):
        facts = visit_facts()
        answer = wording.compose(facts, "", "m")
        self.assertEqual(answer["title"], "Which facilities should I visit first in District-D?")
        self.assertEqual([r["text"] for r in answer["reasons"]], [
            "PHC-F has the most patients with high BP: 286 of 1,334. Many patients miss visits (27%). "
            "Few overdue patients are called. Few eligible patients are on a statin.",
            "PHC-E looks good, with 75% of patients controlled. "
            "But many BP readings sit just under 140 and medicine is rarely stepped up.",
        ])
        self.assertEqual(answer["reasons"][0]["what_to_do"],
                         "Visit this month. Start with the overdue list. "
                         "Agree two actions with the team and check them weekly.")
        self.assertEqual(answer["reasons"][1]["what_to_do"],
                         "Visit this month and watch BP being measured before you use PHC-E as an example.")
        self.assertEqual(answer["reasons"][0]["link"]["url"],
                         "/d/heart360_reports?var-org_unit=47&var-reporting_month=2026-10-01&-dtab=Overdue-calls")
        self.assertEqual(answer["nudge"], {"chip_id": "why_control_low", "label": "Why is control low at PHC-F?",
                                           "org_unit_id": 47})
        self.assertEqual(wording.check_answer(answer, facts), [])

    def test_breached_by_uncontrolled_count_top_three(self):
        breach = ["control_below_pct"]
        data, district = district_with(
            {
                11: dict(uncontrolled_n=166, breaches=[], also_check=False),
                47: dict(uncontrolled_n=286, breaches=breach, also_check=False),
                501: dict(uncontrolled_n=400, breaches=breach, also_check=False),
                502: dict(uncontrolled_n=100, breaches=breach, also_check=False),
                503: dict(uncontrolled_n=350, breaches=breach, also_check=False),
            },
            extra={501: "PHC-W", 502: "PHC-X", 503: "PHC-Y"},
        )
        facts = visit_facts(data, district)
        self.assertEqual([r["values"]["name"] for r in facts["reasons"]], ["PHC-W", "PHC-Y", "PHC-F"])
        self.assertEqual(facts["nudge"]["org_unit_id"], 501)

    def test_third_slot_is_reserved_for_also_check(self):
        breach = ["uncontrolled_above_pct"]
        data, district = district_with(
            {
                11: dict(uncontrolled_n=166, breaches=[], also_check=True),
                47: dict(uncontrolled_n=286, breaches=breach, also_check=False),
                501: dict(uncontrolled_n=400, breaches=breach, also_check=False),
                503: dict(uncontrolled_n=350, breaches=breach, also_check=False),
            },
            extra={501: "PHC-W", 503: "PHC-Y"},
        )
        facts = visit_facts(data, district)
        self.assertEqual([r["values"]["name"] for r in facts["reasons"]], ["PHC-W", "PHC-Y", "PHC-E"])
        self.assertEqual([r["kind"] for r in facts["reasons"]], ["visit", "visit", "visit_also"])

    def test_no_breach_gives_one_sentence(self):
        data, district = district_with({
            11: dict(uncontrolled_n=166, breaches=[], also_check=False),
            47: dict(uncontrolled_n=286, breaches=[], also_check=False),
        })
        answer = wording.compose(visit_facts(data, district), "", "m")
        self.assertEqual(len(answer["reasons"]), 1)
        self.assertTrue(answer["reasons"][0]["text"].startswith("No facility in District-D stands out"))
        self.assertIsNone(answer["nudge"])

    def test_breach_words_are_plain(self):
        data, district = district_with({
            11: dict(uncontrolled_n=166, breaches=[], also_check=False),
            47: dict(uncontrolled_n=286, breaches=["control_below_pct", "uncontrolled_above_pct",
                                                   "missed_visit_above_pct", "ltfu_above_pct"], also_check=False),
        })
        data[47]["control"]["ltfu_pct"] = D("22.5")
        answer = wording.compose(visit_facts(data, district), "", "m")
        todo = answer["reasons"][0]["text"]
        self.assertIn("Only 51% of patients have BP controlled. Many patients miss visits (27%). "
                      "Many patients have stopped coming (23%).", todo)
        self.assertNotIn("LTFU", todo)


class DistrictChipsTests(unittest.TestCase):
    def test_district_chips_order(self):
        client, _db = chat_client()
        self.assertEqual([c["label"] for c in chips(client, 10).json()["chips"]], [
            "Why is my BP control low?",
            "Which facilities should I visit first?",
            "Who should I call this week?",
            "Are medicines being adjusted?",
            "Are my BP readings reliable?",
            "Who needs a statin?",
        ])

    def test_cut_9_drops_visit_first(self):
        client, _db = chat_client(FakeChatDb(live=ALL_LIVE - {"chat_facility_rank_district"}))
        ids = [c["id"] for c in chips(client, 10).json()["chips"]]
        self.assertEqual(ids, ["why_control_low", "who_to_call", "medicines_adjusted", "readings_reliable",
                               "statin_gap"])
        res = ask(client, {"chip_id": "visit_first", "org_unit_id": "10", "reporting_month": "2026-10-01"})
        self.assertEqual(res.status_code, 400)

    def test_visit_first_is_not_a_facility_chip(self):
        client, _db = chat_client()
        res = ask(client, {"chip_id": "visit_first", "org_unit_id": "11", "reporting_month": "2026-10-01"})
        self.assertEqual(res.status_code, 400)

    def test_visit_first_over_http_then_the_nudge(self):
        client, db = chat_client()
        res = ask(client, {"chip_id": "visit_first", "org_unit_id": "10", "reporting_month": "2026-10-01"})
        self.assertEqual(res.status_code, 200)
        nudge = res.json()["nudge"]
        follow = ask(client, {"chip_id": nudge["chip_id"], "org_unit_id": str(nudge["org_unit_id"]),
                              "reporting_month": "2026-10-01"})
        self.assertEqual(follow.status_code, 200)
        self.assertEqual(follow.json()["title"], "Why is BP control low at PHC-F?")
        self.assertIn(("allows", 47), db.log)

    def test_district_why_control_low_also_check_names_a_facility(self):
        client, _db = chat_client()
        body = ask(client, {"chip_id": "why_control_low", "org_unit_id": "10",
                            "reporting_month": "2026-10-01"}).json()
        self.assertEqual(body["title"], "What to check at District-D? Control looks good.")
        self.assertEqual(body["also_check"], "PHC-E looks good at 75% controlled, but check its BP readings and stepping up.")


if __name__ == "__main__":
    unittest.main()
