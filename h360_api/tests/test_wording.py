"""Offline wording, plan and honesty line (story 6.5, AD-32, PD-13, PD-5)."""

from __future__ import annotations

import re
import time
import unittest

from h360_api import registry, wording
from h360_api.tests.test_registry import ALL_KEYS, ask, chat_client
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
                    self.assertEqual(set(r), {"lever", "text", "number", "what_to_do", "link"})
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
        cadence = re.compile(r"\d|\b(each|every|weekly|monthly|this month|once a month|one|two)\b", re.I)
        for chip, org, _facts, answer in every_answer():
            for r in answer["reasons"]:
                if r["what_to_do"]:
                    self.assertRegex(r["what_to_do"], cadence, (chip, org))

    def test_percentages_carry_their_counts(self):
        answer = wording.compose(facts_for("why_control_low", 3), "", "m")
        self.assertEqual(answer["reasons"][0]["text"],
                         "29.9% of new patients did not come back for a second visit (258 of 368 came back).")
        plan = wording.compose(facts_for("who_to_call", 3), "", "m")["reasons"][0]
        self.assertEqual(plan["text"], "11.0% of overdue patients with a phone were called (156 of 1421).")
        self.assertEqual(plan["what_to_do"],
                         "Assign one nurse to call 356 overdue patients each week, longest overdue first.")

    def test_every_number_is_in_the_facts(self):
        for chip, org, facts, answer in every_answer():
            allowed = wording.fact_numbers(facts)
            for t in wording.visible_texts(answer):
                for tok in re.findall(r"\d+(?:\.\d+)?", t):
                    self.assertIn(tok, allowed, (chip, org, t))


class PlanTests(unittest.TestCase):
    def test_who_to_call_has_one_reason_the_plan_and_the_overdue_nudge(self):
        answer = wording.compose(facts_for("who_to_call", 3), "", "m")
        self.assertEqual(len(answer["reasons"]), 1)
        self.assertEqual(answer["plan"], {"total": 1421, "weeks": [356, 356, 356, 353],
                                          "text": "Start with the patients overdue longest."})
        self.assertEqual(sum(answer["plan"]["weeks"]), answer["plan"]["total"])
        self.assertEqual(answer["nudge"], {"chip_id": "overdue_list", "label": "Who is overdue longest?",
                                           "url": "/d/heart360_showcase?var-org_unit=3&-dtab=Overdue-list"})

    def test_plan_total_is_overdue_with_phone_n(self):
        facts = facts_for("call_plan", 11)
        answer = wording.compose(facts, "", "m")
        self.assertEqual(answer["plan"]["total"], 1401)  # report_calling.overdue_with_phone_n
        self.assertTrue(answer["plan"]["text"].startswith("Start with the patients overdue longest"))
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
    def test_flagged_readings_use_the_pd5_sentence(self):
        answer = wording.compose(facts_for("readings_reliable", 11), "", "m")
        self.assertEqual(answer["reasons"][0]["text"], "5.40 readings just under 140 for every 1 just over (367 against 68).")
        self.assertEqual(answer["reasons"][0]["what_to_do"],
                         "Check every BP cuff and retrain staff on measuring BP this month.")

    def test_unflagged_readings_say_no_sign_of_rounding_down(self):
        answer = wording.compose(facts_for("readings_reliable", 3), "", "m")
        self.assertTrue(answer["reasons"][0]["text"].startswith("No sign of rounding down: 1.19 readings"))


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


class TimingTests(unittest.TestCase):
    def test_answers_return_quickly_over_http(self):
        client, _db = chat_client()
        for chip in ("why_control_low", "who_to_call", "visit_first"):
            started = time.perf_counter()
            res = ask(client, {"chip_id": chip, "org_unit_id": "10", "reporting_month": "2026-10-01"})
            self.assertEqual(res.status_code, 200)
            self.assertLess(time.perf_counter() - started, 3.0)
            self.assertEqual(res.json()["honesty"], HONESTY)


if __name__ == "__main__":
    unittest.main()
