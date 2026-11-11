"""Offline wording, plan and honesty line (story 6.5, AD-32, PD-13, PD-5)."""

from __future__ import annotations

import json
import re
import unittest

from h360_api import registry, wording
from h360_api.tests.test_registry import ALL_KEYS
from h360_api.tests.test_ranker import facts_for

HONESTY = (
    "These actions explain only 2% to 12% of why one facility does better than another. "
    "Treat them as the best next steps, not a promise."
)
AD30_FIELDS = {"mode", "place", "month", "reasons", "also_check", "stock_line", "nudge", "plan", "honesty", "links"}
BANNED = re.compile(r"\bwill\b|guarantee|fudg", re.IGNORECASE)


def every_answer():
    """(chip, org, facts, answer) for every live chip at PHC-E, PHC-A, PHC-B and District-D."""
    out = []
    for org, scope in ((11, "facility"), (3, "facility"), (87, "facility"), (10, "district")):
        ids = [c["id"] for c in registry.chips_for(scope, ALL_KEYS)] + ["call_plan"]
        for chip in ids:
            facts = facts_for(chip, org)
            out.append((chip, org, facts, wording.compose(facts, "", "m")))
    return out


def all_strings(value):
    """Displayed strings. `lever` and `chip_id` are ids (registry keys), never drawn by the widget."""
    if isinstance(value, dict):
        for k, v in value.items():
            if k not in ("lever", "chip_id"):
                yield from all_strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from all_strings(v)
    elif isinstance(value, str):
        yield value


class OfflineShapeTests(unittest.TestCase):
    def test_every_chip_has_the_shape_and_passes_the_checks(self):
        for chip, org, facts, answer in every_answer():
            with self.subTest(chip=chip, org=org):
                self.assertTrue(AD30_FIELDS <= set(answer))
                self.assertEqual(answer["mode"], "offline")
                self.assertLessEqual(len(answer["reasons"]), 3)
                self.assertGreaterEqual(len(answer["reasons"]), 1)
                self.assertEqual(answer["honesty"], HONESTY)
                self.assertEqual(wording.check_answer(answer, facts), [])
                for r in answer["reasons"]:
                    self.assertEqual(set(r), {"lever", "tag", "text", "number", "figure", "what_to_do", "link",
                                              "evidence"})
                    if r["figure"]:
                        self.assertIn(r["figure"], r["text"])
                self.assertEqual(set(answer["place"]), {"org_unit_id", "name", "level", "scope"})
                self.assertEqual(answer["month"], "2026-10-01")
                self.assertIsInstance(answer["title"], str)

    def test_sentences_and_word_budget(self):
        for chip, org, _facts, answer in every_answer():
            with self.subTest(chip=chip, org=org):
                texts = wording.visible_texts(answer)
                total = 0
                for t in texts:
                    for s in wording.sentences(t):
                        self.assertLessEqual(len(s.split()), 20, s)
                        total += len(s.split())
                self.assertLessEqual(total, 150)

    def test_no_banned_word_in_any_user_visible_string(self):
        for chip, org, _facts, answer in every_answer():
            body = dict(answer)
            body.pop("honesty")
            for s in all_strings(body):
                if s.startswith("/d/"):
                    continue
                self.assertIsNone(BANNED.search(s), (chip, org, s))
        for s in (wording.NO_MATCH, wording.PICK_DISTRICT_LINE, wording.PLAN_TEXT, HONESTY,
                  *wording.TOO_FEW.values(), *wording.NUDGE_LABELS.values()):
            self.assertIsNone(BANNED.search(s), s)

    def test_what_to_do_is_a_specific_action_with_a_number_or_cadence(self):
        cadence = re.compile(r"\d|\b(each|every|weekly|monthly|this month|once a month|one|two|next visit)\b", re.I)
        for chip, org, _facts, answer in every_answer():
            for r in answer["reasons"]:
                if r["what_to_do"]:
                    self.assertRegex(r["what_to_do"], cadence, (chip, org))

    def test_percentages_carry_their_counts_for_the_group_they_name(self):
        # UX-24: the counts are for the patients who did not come back. UX-23: whole percents, commas.
        answer = wording.compose(facts_for("why_control_low", 3), "", "m")
        self.assertEqual(answer["reasons"][0]["text"],
                         "Many new patients do not come back. 110 of 368 missed their second visit (30%).")
        plan = wording.compose(facts_for("who_to_call", 3), "", "m")["reasons"][0]
        self.assertEqual(plan["text"], "In Oct, 156 of 1,421 overdue patients with a phone were called (11%).")

    def test_number_format(self):
        fmt = wording.Fmt([])
        self.assertEqual(fmt.pct("75.0"), "75%")
        self.assertEqual(fmt.pct("27.9"), "28%")
        self.assertEqual(fmt.pct("4.0"), "4.0%")
        self.assertEqual(fmt.pct("6.45"), "6.5%")
        self.assertEqual(fmt.pct("0.0"), "0%")
        self.assertEqual(fmt.count(1421), "1,421")
        self.assertEqual(fmt.ratio("5.40"), "5.4")
        self.assertEqual(fmt.derived, [{"value": "28", "rule": "round0", "inputs": ["27.9"]},
                                       {"value": "6.5", "rule": "round1", "inputs": ["6.45"]}])

    def test_every_number_is_in_the_facts_or_derived_from_them(self):
        for chip, org, facts, answer in every_answer():
            allowed, problems = wording.derived_numbers(answer, wording.fact_numbers(facts))
            self.assertEqual(problems, [], (chip, org))
            for t in wording.visible_texts(answer):
                for tok in wording.number_tokens(t):
                    self.assertIn(tok, allowed, (chip, org, t))

    def test_a_forged_derivation_fails_the_check(self):
        facts = facts_for("why_control_low", 11)
        answer = wording.render_offline(facts)
        answer["derived"].append({"value": "999", "rule": "sub", "inputs": ["283", "79"]})
        self.assertTrue(wording.check_answer(answer, facts))


class PlainWordsTests(unittest.TestCase):
    """The owner's clear-writing rules (story 7.9): no stacked facts, labels or report jargon."""

    def test_no_answer_sentence_uses_semicolons_labels_or_jargon(self):
        bad = re.compile(r";|Reason |Past the line|Flagged on|\u2014|\b(ensure|key|leverage|robust|specifically|notably)\b",
                         re.IGNORECASE)
        for chip, org, _facts, answer in every_answer():
            for text in wording.visible_texts(answer):
                self.assertIsNone(bad.search(text), (chip, org, text))
        for text in (*wording.TOO_FEW.values(), *wording.NUDGE_LABELS.values(), wording.PLAN_TEXT,
                     wording.NO_MATCH, wording.PICK_DISTRICT_LINE):
            self.assertIsNone(bad.search(text), text)

    def test_counts_sit_inside_the_sentence_as_n_of_n(self):
        answer = wording.compose(facts_for("why_control_low", 11), "", "m")
        self.assertIn("1,019 of 1,358 patients", answer["control_line"])
        self.assertIn("79 of 283 high BP visits", answer["reasons"][1]["text"])


class PlanTests(unittest.TestCase):
    def test_who_to_call_has_one_reason_the_plan_and_the_overdue_nudge(self):
        answer = wording.compose(facts_for("who_to_call", 3), "", "m")
        self.assertEqual(len(answer["reasons"]), 1)
        plan = answer["plan"]
        self.assertEqual(plan["total"], 1421)
        self.assertEqual(plan["weeks"], [25, 25, 25, 25])
        self.assertEqual(plan["text"],
                         "One nurse can call about 25 a week, so 100 in 4 weeks. "
                         "About 33 may come back, as 33% did here. "
                         "The Dr Rai action plan gives one nurse 25 calls a week. "
                         "Start at the top of the overdue list, with patients not called yet.")
        self.assertNotIn("longest", json.dumps(answer))  # UX-30: the list keeps its own order
        self.assertEqual(answer["nudge"], {"chip_id": "overdue_list", "label": "Open the overdue list",
                                           "url": "/d/heart360_showcase?var-org_unit=3&var-reporting_month=2026-10-01"
                                                  "&-dtab=Overdue-list"})

    def test_district_overdue_link_goes_to_the_calls_table(self):
        # UX-12: the overdue list works at facility level only.
        answer = wording.compose(facts_for("who_to_call", 10), "", "m")
        self.assertEqual(answer["nudge"]["label"], "Pick a facility to open its overdue list")
        self.assertEqual(answer["nudge"]["url"],
                         "/d/heart360_reports?var-org_unit=10&var-reporting_month=2026-10-01&-dtab=Overdue-calls")
        self.assertEqual(answer["plan"]["list_link"]["url"], answer["nudge"]["url"])
        self.assertTrue(answer["plan"]["text"].startswith(
            "One nurse per facility can call about 25 a week, so 200 in 4 weeks across 2 facilities."))

    def test_plan_total_is_overdue_with_phone_n(self):
        facts = facts_for("call_plan", 11)
        answer = wording.compose(facts, "", "m")
        self.assertEqual(answer["plan"]["total"], 1401)  # report_calling.overdue_with_phone_n
        self.assertTrue(answer["plan"]["text"].endswith("Start at the top of the overdue list, with patients not called yet."))
        self.assertIsNone(answer["nudge"])

    def test_why_control_low_nudges_to_the_plan(self):
        answer = wording.compose(facts_for("why_control_low", 3), "", "m")
        self.assertEqual(answer["nudge"], {"chip_id": "call_plan", "label": "How many patients should I call?"})


class LinkTests(unittest.TestCase):
    def test_report_links_use_pd4_slugs_and_the_scope_node(self):
        answer = wording.compose(facts_for("why_control_low", 11), "", "m")
        urls = [l["url"] for l in answer["links"]]
        self.assertIn("/d/heart360_reports?var-org_unit=11&var-reporting_month=2026-10-01&-dtab=BP-readings-check",
                      urls)
        self.assertIn("/d/heart360_reports?var-org_unit=11&var-reporting_month=2026-10-01&-dtab=Stepping-up", urls)
        slugs = {re.search(r"dtab=([^&]+)", u).group(1) for u in urls}
        self.assertTrue(slugs <= {"Right-medicines", "Stepping-up", "BP-readings-check", "Statins", "Overdue-calls"})

    def test_sub_facility_links_use_the_facility(self):
        answer = wording.compose(facts_for("why_control_low", 12), "", "m")
        self.assertTrue(all("var-org_unit=11&" in l["url"] for l in answer["links"]))

    def test_link_nudges_carry_a_url(self):
        cases = {
            "medicines_adjusted": ("Open Stepping up", "Stepping-up"),
            "readings_reliable": ("Open BP readings check", "BP-readings-check"),
            "statin_gap": ("Open the patient list", "Statins"),
        }
        for chip, (label, slug) in cases.items():
            with self.subTest(chip=chip):
                nudge = wording.compose(facts_for(chip, 11), "", "m")["nudge"]
                self.assertEqual(nudge["label"], label)
                self.assertTrue(nudge["url"].endswith("-dtab=" + slug))
        self.assertIsNone(wording.compose(facts_for("statin_gap", 10), "", "m")["nudge"])
        self.assertEqual(wording.compose(facts_for("medicines_adjusted", 10), "", "m")["nudge"]["label"],
                         "Which facilities step up least?")


class ReadingsTests(unittest.TestCase):
    def test_flagged_readings_are_a_reason_to_check_not_proof(self):
        # UX-09, UX-25: "may", and watch BP being measured; never "retrain" or "check every cuff".
        answer = wording.compose(facts_for("readings_reliable", 11), "", "m")
        r = answer["reasons"][0]
        self.assertEqual(r["text"], "Many BP readings sit just under 140: 308 of 130–139 against 131 of 140–149 "
                                    "in Q3 2026. That is 2.35 to 1, up from 2.12 in Q2. "
                                    "This may mean readings are rounded down.")
        self.assertEqual(r["what_to_do"],
                         "On your next visit, watch BP being measured and recorded.")
        self.assertNotRegex(json.dumps(answer), r"(?i)retrain|every BP cuff")
        self.assertEqual(r["figure"], "2.35")
        self.assertEqual(r["evidence"]["target"], "2.0")

    def test_unflagged_readings_say_no_sign_of_rounding_down(self):
        answer = wording.compose(facts_for("readings_reliable", 3), "", "m")
        self.assertEqual(answer["reasons"][0]["text"],
                         "No sign that readings are rounded down: 156 of 130–139 against 95 of 140–149 in Q3 2026. "
                         "That is 1.64 to 1.")


class EvidenceTests(unittest.TestCase):
    def test_each_reason_has_its_evidence_with_place_month_and_tab(self):
        answer = wording.compose(facts_for("why_control_low", 11), "", "m")
        for r in answer["reasons"]:
            ev = r["evidence"]
            self.assertEqual(ev["kind"], "line")
            self.assertEqual(ev["place"], "PHC-E")
            self.assertEqual(len(ev["points"]), 4 if r["lever"] == "fudging_score" else 6)
            self.assertEqual(ev["points"][-1]["label"], "Q3 2026" if r["lever"] == "fudging_score" else "Oct-2026")
            self.assertTrue(ev["link"]["label"].startswith("See this in Reports: "))
            self.assertIn("var-org_unit=11&var-reporting_month=2026-10-01", ev["link"]["url"])
        titration = answer["reasons"][1]["evidence"]
        self.assertEqual(titration["title"], "Stepping up")
        self.assertEqual(titration["points"][-1]["num"], 79)
        self.assertEqual(titration["target"], "40")
        self.assertEqual(answer["control_evidence"]["link"]["url"],
                         "/d/heart360_showcase?var-org_unit=11&var-reporting_month=2026-10-01")

    def test_visit_first_evidence_is_the_facility_table(self):
        answer = wording.compose(facts_for("visit_first", 10), "", "m")
        ev = answer["reasons"][0]["evidence"]
        self.assertEqual(ev["kind"], "table")
        self.assertEqual(ev["columns"], ["Facility", "BP controlled", "Missed visits", "Flagged on"])
        self.assertEqual([row["cells"][0] for row in ev["rows"]], ["PHC-F", "PHC-E"])
        self.assertTrue(ev["rows"][0]["focus"])
        self.assertIn("var-org_unit=47&", ev["link"]["url"])


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.facts = facts_for("why_control_low", 3)
        self.answer = wording.render_offline(self.facts)

    def bad(self, text):
        answer = dict(self.answer, reasons=[dict(self.answer["reasons"][0], text=text)])
        return wording.check_answer(answer, self.facts)

    def test_checks_catch_each_rule(self):
        self.assertEqual(wording.check_answer(self.answer, self.facts), [])
        self.assertTrue(self.bad("This will help."))
        self.assertTrue(self.bad("Results are guaranteed."))
        self.assertTrue(self.bad("Possible fudging here."))
        self.assertTrue(self.bad("Calling 77.7% of patients helps."))
        self.assertTrue(self.bad(" ".join(["word"] * 21) + "."))
        long_answer = dict(self.answer, reasons=[dict(self.answer["reasons"][0], text="Fine words here. " * 60)])
        self.assertIn("over 150 words", wording.check_answer(long_answer, self.facts))


if __name__ == "__main__":
    unittest.main()
