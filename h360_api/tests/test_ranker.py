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
    def test_triggered_levers_in_prototype_order_at_most_three(self):
        data = low_control_facility(
            new={"new_loss_pct": D("30.0")},
            calling={"called_pct": D("5.0")},
            titration={"titration_pct": D("30.0")},
        )
        data[3]["new"]["new_usable_phone_pct"] = D("80.0")
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual(facts["state"], "ok")
        self.assertEqual([r["lever"] for r in facts["reasons"]],
                         ["overdue_calling", "titration_rate", "new_patient_return"])
        self.assertTrue(all(r["kind"] == "triggered" for r in facts["reasons"]))

    def test_calling_triggers_on_early_share_alone(self):
        data = low_control_facility(new={"new_loss_pct": D("10.0")}, calling={"early_pct": D("40.0")})
        facts = facts_for("why_control_low", 3, data)
        calling = [r for r in facts["reasons"] if r["lever"] == "overdue_calling"][0]
        self.assertEqual(calling["kind"], "triggered")
        self.assertTrue(calling["values"]["early_low"])
        self.assertFalse(calling["values"]["called_low"])

    def test_a_met_target_is_never_a_reason(self):
        # UX-07: one problem gives one reason, never padded with an on-target lever.
        data = low_control_facility(new={"new_loss_pct": D("10.0")}, titration={"titration_pct": D("30.0")})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual([(r["lever"], r["kind"]) for r in facts["reasons"]], [("titration_rate", "triggered")])
        answer = wording.render_offline(facts)
        self.assertEqual(len(answer["reasons"]), 1)
        for r in answer["reasons"]:
            self.assertNotIn("On target", r["text"])
            self.assertNotIn("usable phone", r["text"])

    def test_nothing_triggered_says_no_clear_reason(self):
        data = low_control_facility(new={"new_loss_pct": D("10.0")})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual(facts["state"], "no_clear_reason")
        answer = wording.render_offline(facts)
        self.assertEqual([r["text"] for r in answer["reasons"]], [
            "No clear reason shows in these reports. Calling, stepping up and new patients' return are all on target."])
        self.assertIsNone(answer["nudge"])

    def test_too_few_gives_one_plain_sentence(self):
        data = low_control_facility(new={"too_few": True}, calling={"too_few": True}, titration={"too_few": True})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual(facts["state"], "too_few")
        answer = wording.render_offline(facts)
        self.assertEqual([r["text"] for r in answer["reasons"]], ["There are too few patients here to find a clear reason."])
        self.assertIsNone(answer["nudge"])

    def test_no_data_gives_one_plain_sentence(self):
        data = low_control_facility(control={"under_care_n": 0, "controlled_pct": None})
        facts = facts_for("why_control_low", 3, data)
        self.assertEqual(facts["state"], "no_data")
        answer = wording.render_offline(facts)
        self.assertEqual(answer["reasons"][0]["text"],
                         "There is no data for PHC-A in Oct-2026, so I can't look for reasons.")
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
        self.assertTrue(by_lever["overdue_calling"]["what_to_do"].startswith("Fix medicine stock first. "))
        self.assertTrue(by_lever["titration_rate"]["what_to_do"].startswith("Fix medicine stock first. "))
        self.assertFalse(by_lever["new_patient_return"]["what_to_do"].startswith("Fix medicine stock first."))
        self.assertNotIn("days of stock", by_lever["titration_rate"]["text"])
        self.assertEqual(answer["stock_line"], "Fix medicine stock first. Only 18 patient days of CCB are left. "
                                               "Check stock weekly and order before two weeks are left.")
        self.assertEqual(answer["stock_evidence"]["kind"], "table")
        self.assertEqual(answer["stock_evidence"]["rows"][0], {"cells": ["CCB", "18"], "flag": True})
        self.assertTrue(answer["stock_evidence"]["link"]["url"].startswith(
            "/d/heart360_drug_stock?var-org_unit=3&var-reporting_month=2026-10-01"))
        # The stock line is read before any reason (UX-09).
        texts = wording.visible_texts(answer)
        self.assertLess(texts.index(answer["stock_line"]), texts.index(answer["reasons"][0]["text"]))

    def test_out_of_stock(self):
        data = low_control_facility(calling={"called_pct": D("5.0")}, stock=[("ARB", D("0"), True)])
        answer = wording.render_offline(facts_for("why_control_low", 3, data))
        self.assertTrue(answer["stock_line"].startswith("Fix medicine stock first. ARB is out of stock."))

    def test_phc_b_low_ccb(self):
        answer = wording.render_offline(facts_for("why_control_low", 87))
        self.assertEqual(answer["stock_line"], "Fix medicine stock first. Only 18 patient days of CCB are left. "
                                               "Check stock weekly and order before two weeks are left.")

    def test_fine_stock_is_said_before_stepping_up_advice(self):
        answer = wording.render_offline(facts_for("why_control_low", 11))
        self.assertIsNone(answer["stock_line"])
        titration = [r for r in answer["reasons"] if r["lever"] == "titration_rate"][0]
        self.assertTrue(titration["text"].endswith(", with over 30 days of stock."))


class HighControlTests(unittest.TestCase):
    def test_pd11_title_flags_first_then_levers(self):
        facts = facts_for("why_control_low", 11)
        self.assertTrue(facts["high_control"])
        answer = wording.render_offline(facts)
        self.assertEqual(answer["title"], "What to check at PHC-E? Control looks good.")
        self.assertEqual(answer["control_line"], "In Oct-2026, 1,019 of 1,358 patients had BP controlled (75%).")
        self.assertEqual([r["lever"] for r in answer["reasons"]],
                         ["fudging_score", "titration_rate", "overdue_calling"])
        self.assertEqual(answer["reasons"][0]["text"],
                         "Many BP readings sit just under 140: 308 of 130–139 against 131 of 140–149 in Q3 2026. "
                         "That is 2.35 to 1. This may mean readings are rounded down.")
        self.assertEqual(answer["also_check"],
                         "Check these before you use PHC-E as an example.")

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
            "chat.stock_days_below": D("30"),
            "fudging.flag_score": D("2.0"),
            "fudging.min_readings": D("20"),
            "fudging.flag_ratio": D("2.0"),
            "statins.flag_below_pct": D("25"),
            "chattogram.control_below_pct": D("50"),
            "chattogram.missed_visit_above_pct": D("25"),
        })


class SeriesTests(unittest.TestCase):
    def test_each_reason_carries_six_months_from_the_same_function(self):
        db = FakeChatDb()
        fetch = registry.Fetcher(db, MONTH)
        place = registry.resolve_place(db, fetch, ADMIN, 11)
        facts = ranker.build_facts("why_control_low", place, fetch, ALL_KEYS)
        series = {r["lever"]: r["series"] for r in facts["reasons"]}
        six = ["2026-05-01", "2026-06-01", "2026-07-01", "2026-08-01", "2026-09-01", "2026-10-01"]
        self.assertEqual([p["month"] for p in series["titration_rate"]], six)  # report_titration_monthly
        self.assertEqual([p["month"] for p in series["overdue_calling"]], six)  # report_calling, month by month
        # Readings: the completed quarters of report_fudging_quarterly, never the quarter in progress.
        self.assertEqual([p["label"] for p in series["fudging_score"]], ["Q4 2025", "Q1 2026", "Q2 2026", "Q3 2026"])
        months = {e[3] for e in db.log if e[0] == "call" and e[1] == "report_calling"}
        self.assertEqual(len(months), 6)
        # Only registry functions, for the node that access was checked for.
        self.assertTrue({e[2] for e in db.log if e[0] == "call"} <= {11})

    def test_series_point_has_value_and_counts(self):
        facts = facts_for("medicines_adjusted", 11)
        point = facts["reasons"][0]["series"][-1]
        self.assertEqual(point, {"month": "2026-10-01", "value": "27.9", "num": 79, "den": 283, "average": "42.8"})

    def test_without_the_new_functions_the_old_ones_are_used(self):
        live = ALL_KEYS - {"titration_monthly", "statins_monthly", "fudging_quarterly"}
        facts = facts_for("why_control_low", 11, live=live)
        self.assertEqual([r["lever"] for r in facts["reasons"]][:2], ["fudging_score", "titration_rate"])
        answer = wording.render_offline(facts)
        self.assertEqual(answer["reasons"][0]["text"],
                         "Many BP readings sit just under 140: 367 of 130–139 against 68 of 140–149 in Aug–Oct 2026. "
                         "That is 5.4 to 1. This may mean readings are rounded down.")
        self.assertEqual(len(facts["reasons"][1]["series"]), 6)
        self.assertEqual(wording.check_answer(answer, facts), [])

    def test_derived_numbers_name_their_inputs(self):
        facts = facts_for("why_control_low", 11)
        self.assertIn({"value": "204", "rule": "sub", "inputs": ["283", "79"]}, facts["derived"])
        self.assertIn({"value": "100", "rule": "mul", "inputs": ["25", "4"]}, facts["derived"])
        self.assertIn({"value": "30", "rule": "pct_of", "inputs": ["100", "29.9"]}, facts["derived"])


class CallSizingTests(unittest.TestCase):
    def test_plan_is_one_nurse_a_week_not_the_whole_list(self):
        facts = facts_for("who_to_call", 3)
        self.assertEqual(facts["plan"]["weeks"], [25, 25, 25, 25])
        self.assertEqual(facts["plan"]["total"], 1421)

    def test_district_plan_is_one_nurse_per_facility(self):
        facts = facts_for("who_to_call", 10)
        self.assertEqual(facts["plan"]["per_week"], "50")
        self.assertEqual(facts["plan"]["facilities_n"], 2)

    def test_short_list_caps_the_plan(self):
        data = low_control_facility(calling={"overdue_with_phone_n": 30})
        data[3]["plan"] = (30, 8, 8, 8, 6)
        facts = facts_for("who_to_call", 3, data)
        self.assertEqual(facts["plan"]["weeks"], [25, 5, 0, 0])
        self.assertEqual(facts["plan"]["plan_calls"], "30")


if __name__ == "__main__":
    unittest.main()
