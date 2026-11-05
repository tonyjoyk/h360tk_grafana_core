"""Evidence ranker (story 6.4, AD-31, PD-11). Fixed facts, no database."""

from __future__ import annotations

import copy
import unittest
from decimal import Decimal as D

from h360_api import ranker, registry, wording
from h360_api.tests.test_registry import ALL_KEYS, FACILITY, MONTH, FakeChatDb, actor_for

ADMIN = actor_for(login="admin", teams=(), admin=True)


def facts_for(chip: str, org: int, data=None, live=ALL_KEYS) -> dict:
    db = FakeChatDb(data=data)
    fetch = registry.Fetcher(db, MONTH)
    place = registry.resolve_place(db, fetch, ADMIN, org)
    return ranker.build_facts(chip, place, fetch, frozenset(live))


def low_control_facility(**changes) -> dict:
    """PHC-A (3) with chosen lever values. Control 53.1%: below the PD-11 line."""
    data = copy.deepcopy(FACILITY)
    sec = data[3]
    for section, values in changes.items():
        if section == "stock":
            sec["stock"] = values
        else:
            sec[section].update(values)
    return data


class LeverOrderTests(unittest.TestCase):
    def test_triggered_levers_by_tier_at_most_three(self):
        data = low_control_facility(
            new={"new_loss_pct": D("30.0")},
            calling={"called_pct": D("5.0")},
            titration={"titration_pct": D("30.0")},
        )
        data[3]["new"]["new_usable_phone_pct"] = D("80.0")
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual(facts["state"], "ok")
        self.assertEqual([r["lever"] for r in facts["reasons"]],
                         ["new_patient_return", "phone_capture", "overdue_calling"])
        self.assertTrue(all(r["kind"] == "triggered" for r in facts["reasons"]))

    def test_calling_triggers_on_early_share_alone(self):
        data = low_control_facility(new={"new_loss_pct": D("10.0")}, calling={"early_pct": D("40.0")})
        facts = facts_for("why_control_low", 3, data)
        calling = [r for r in facts["reasons"] if r["lever"] == "overdue_calling"][0]
        self.assertEqual(calling["kind"], "triggered")
        self.assertTrue(calling["values"]["early_low"])
        self.assertFalse(calling["values"]["called_low"])

    def test_one_triggered_pads_to_two_with_the_lowest_tier_on_target(self):
        data = low_control_facility(new={"new_loss_pct": D("10.0")}, titration={"titration_pct": D("30.0")})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual([(r["lever"], r["kind"]) for r in facts["reasons"]],
                         [("titration_rate", "triggered"), ("new_patient_return", "on_target")])
        answer = wording.render_offline(facts)
        self.assertTrue(answer["reasons"][1]["text"].startswith("On target: "))

    def test_none_triggered_pads_to_two(self):
        data = low_control_facility(new={"new_loss_pct": D("10.0")})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual([(r["lever"], r["kind"]) for r in facts["reasons"]],
                         [("new_patient_return", "on_target"), ("phone_capture", "on_target")])

    def test_too_few_gives_one_plain_sentence(self):
        data = low_control_facility(new={"too_few": True}, calling={"too_few": True}, titration={"too_few": True})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual(facts["state"], "too_few")
        answer = wording.render_offline(facts)
        self.assertEqual([r["text"] for r in answer["reasons"]], ["Too few patients here to rank reasons."])
        self.assertIsNone(answer["nudge"])

    def test_no_data_gives_one_plain_sentence(self):
        data = low_control_facility(control={"under_care_n": 0, "controlled_pct": None})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual(facts["state"], "no_data")
        answer = wording.render_offline(facts)
        self.assertEqual(answer["reasons"][0]["text"],
                         "There is no data for PHC-A in Oct-2026, so I can't rank reasons.")
        self.assertIsNone(answer["control_line"])

    def test_stub_lever_is_skipped_not_failed(self):
        live = ALL_KEYS - {"titration_rate"}
        data = low_control_facility(titration={"titration_pct": D("10.0")})
        facts = facts_for("why_control_low", 3, data, live=live)
        self.assertNotIn("titration_rate", [r["lever"] for r in facts["reasons"]])


class StockGateTests(unittest.TestCase):
    def test_low_stock_marks_calling_and_titration_and_adds_a_line(self):
        data = low_control_facility(
            calling={"called_pct": D("5.0")},
            titration={"titration_pct": D("30.0")},
            stock=[("CCB", D("18.0"), True), ("ARB", D("90.0"), False)],
        )
        facts = facts_for("why_control_low", 3, data)
        answer = wording.render_offline(facts)
        by_lever = {r["lever"]: r for r in answer["reasons"]}
        self.assertTrue(by_lever["overdue_calling"]["what_to_do"].startswith("Fix stock first. "))
        self.assertTrue(by_lever["titration_rate"]["what_to_do"].startswith("Fix stock first. "))
        self.assertFalse(by_lever["new_patient_return"]["what_to_do"].startswith("Fix stock first."))
        self.assertEqual(answer["stock_line"], "Fix drug stock first: CCB has 18.0 patient-days left. Check stock weekly and order before two weeks are left.")

    def test_phc_b_low_ccb(self):
        answer = wording.render_offline(facts_for("why_control_low", 87))
        self.assertEqual(answer["stock_line"], "Fix drug stock first: CCB has 18.0 patient-days left. Check stock weekly and order before two weeks are left.")

    def test_no_line_when_stock_is_fine(self):
        self.assertIsNone(wording.render_offline(facts_for("why_control_low", 3))["stock_line"])


class HighControlTests(unittest.TestCase):
    def test_pd11_title_flags_first_then_levers(self):
        facts = facts_for("why_control_low", 11)
        self.assertTrue(facts["high_control"])
        answer = wording.render_offline(facts)
        self.assertEqual(answer["title"], "What to check at PHC-E? 75.0% controlled, looks fine.")
        self.assertEqual(answer["control_line"], "75.0% controlled in Oct-2026")
        self.assertEqual([r["lever"] for r in answer["reasons"]],
                         ["fudging_score", "titration_rate", "new_patient_return"])
        self.assertEqual(answer["reasons"][0]["text"], "5.40 readings just under 140 for every 1 just over (367 against 68).")
        self.assertEqual(answer["also_check"],
                         "PHC-E looks fine at 75.0% controlled, but is flagged on BP readings check and Stepping up.")

    def test_pd11_at_most_two_flags_and_three_reasons(self):
        data = copy.deepcopy(FACILITY)
        data[11]["new"]["new_usable_phone_pct"] = D("50.0")
        facts = facts_for("why_control_low", 11, data)
        self.assertEqual(len(facts["reasons"]), 3)
        self.assertEqual([r["kind"] for r in facts["reasons"]][:2], ["flag", "flag"])

    def test_below_60_title(self):
        answer = wording.render_offline(facts_for("why_control_low", 3))
        self.assertEqual(answer["title"], "Why is BP control low at PHC-A?")
        self.assertIsNone(answer["also_check"])

    def test_district_below_60_names_one_looks_fine_facility(self):
        from h360_api.tests.test_registry import DISTRICT

        district = copy.deepcopy(DISTRICT)
        district[10]["control"]["controlled_pct"] = D("55.0")
        db = FakeChatDb(district=district)
        fetch = registry.Fetcher(db, MONTH)
        place = registry.resolve_place(db, fetch, ADMIN, 10)
        facts = ranker.build_facts("why_control_low", place, fetch, ALL_KEYS)
        self.assertFalse(facts["high_control"])
        self.assertEqual(facts["also_check"]["name"], "PHC-E")
        self.assertEqual(facts["also_check"]["kind"], "other")


class DeterminismTests(unittest.TestCase):
    def test_same_inputs_same_output(self):
        for chip, org in (("why_control_low", 11), ("why_control_low", 3), ("visit_first", 10),
                          ("who_to_call", 3), ("why_control_low", 10)):
            with self.subTest(chip=chip, org=org):
                a = wording.compose(facts_for(chip, org), "", "m")
                b = wording.compose(facts_for(chip, org), "", "m")
                self.assertEqual(a, b)

    def test_control_comes_from_chat_control_summary(self):
        db = FakeChatDb()
        fetch = registry.Fetcher(db, MONTH)
        place = registry.resolve_place(db, fetch, ADMIN, 11)
        ranker.build_facts("why_control_low", place, fetch, ALL_KEYS)
        self.assertIn(("call", "chat_control_summary", 11, MONTH), db.log)

    def test_thresholds_mirror_the_seed_rows(self):
        self.assertEqual(ranker.THRESHOLDS, {
            "common.high_control_pct": D("60"),
            "chat.new_loss_above_pct": D("25"),
            "chat.usable_phone_below_pct": D("90"),
            "chat.called_below_pct": D("10"),
            "chat.early_below_pct": D("50"),
            "chat.titration_below_pct": D("40"),
        })


if __name__ == "__main__":
    unittest.main()
