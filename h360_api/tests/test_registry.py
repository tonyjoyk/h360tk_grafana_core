"""Registry, chips, scope and access (story 6.3). The database and Grafana are fakes; no network.

FakeChatDb and the demo rows below are shared by test_ranker, test_wording, test_claude and
test_district.
"""

from __future__ import annotations

import copy
import datetime as dt
import unittest
from decimal import Decimal as D

from h360_api import registry
from h360_api.auth import Actor
from h360_api.config import Settings
from h360_api.tests.fakes import FakeGrafana, make_client, sign_in, write_headers

MONTH = dt.date(2026, 10, 1)
SESSION = "session-token-abc"

ALL_LIVE = frozenset(registry.REGISTRY_FUNCTIONS)
ALL_KEYS = frozenset(registry.REGISTRY)

# --------------------------------------------------------------------------- demo rows
# Shaped like the 2026-10-01 demo data: District-D (10) holds PHC-E (11, high control,
# readings and step-up flags) and PHC-F (47). PHC-A (3) sits in District-A (2). PHC-B (87) has
# low CCB stock. SHC-S (12) is a sub-facility of PHC-E. Region-B (9) is level 1.
UNITS = {
    9: ("Region-B", 1, None),
    10: ("District-D", 2, 9),
    2: ("District-A", 2, None),
    11: ("PHC-E", 3, 10),
    47: ("PHC-F", 3, 10),
    3: ("PHC-A", 3, 2),
    87: ("PHC-B", 3, 2),
    12: ("SHC-S", 4, 11),
}

FACILITY = {
    11: {
        "control": dict(under_care_n=1358, controlled_n=1019, controlled_pct=D("75.0"), uncontrolled_n=166,
                        uncontrolled_pct=D("12.2"), missed_visit_pct=D("12.7"), ltfu_pct=D("0.0")),
        "new": dict(too_few=False, flag=False, flag_reason=None, new_patients_n=303, new_returned_n=223,
                    new_loss_pct=D("26.4"), new_usable_phone_n=303, new_usable_phone_pct=D("100.0")),
        "calling": dict(too_few=False, flag=True, flag_reason="Few overdue patients are called: 4.0%.",
                        overdue_n=1401, overdue_with_phone_n=1401, called_n=56, called_pct=D("4.0"), early_n=21,
                        early_pct=D("37.5"), calls_per_week=351),
        "titration": dict(too_few=False, flag=True,
                          flag_reason="Medicine rarely stepped up: 27.9% of 283 high BP visits.",
                          uncontrolled_visits_n=283, stepped_up_n=79, titration_pct=D("27.9"),
                          control_pct=D("75.0"), looks_fine_check=True),
        "fudging": dict(too_few=False, flag=True,
                        flag_reason="5.40 readings just under 140 for every 1 just over. Check how BP is measured.",
                        readings_n=1841, band_135_139_n=367, band_140_144_n=68, score=D("5.40"),
                        control_pct=D("75.0"), looks_fine_check=True),
        "statins": dict(too_few=False, flag=False, flag_reason=None, eligible_n=354, on_statin_n=113,
                        on_statin_pct=D("31.9"), not_on_statin_n=241),
        "stock": [("CCB", D("90.0"), False), ("ARB", D("90.0"), False), ("Diuretic", D("90.0"), False)],
        "plan": (1401, 351, 351, 351, 348),
        "rank": dict(uncontrolled_n=166, breaches=[], also_check=True),
    },
    47: {
        "control": dict(under_care_n=1334, controlled_n=683, controlled_pct=D("51.2"), uncontrolled_n=286,
                        uncontrolled_pct=D("21.4"), missed_visit_pct=D("27.3"), ltfu_pct=D("0.0")),
        "new": dict(too_few=False, flag=False, flag_reason=None, new_patients_n=325, new_returned_n=228,
                    new_loss_pct=D("29.8"), new_usable_phone_n=325, new_usable_phone_pct=D("100.0")),
        "calling": dict(too_few=False, flag=True, flag_reason="Few overdue patients are called: 9.0%.",
                        overdue_n=1413, overdue_with_phone_n=1413, called_n=127, called_pct=D("9.0"), early_n=57,
                        early_pct=D("44.9"), calls_per_week=354),
        "titration": dict(too_few=False, flag=False, flag_reason=None, uncontrolled_visits_n=252, stepped_up_n=116,
                          titration_pct=D("46.0"), control_pct=D("51.2"), looks_fine_check=False),
        "fudging": dict(too_few=False, flag=False, flag_reason=None, readings_n=1427, band_135_139_n=24,
                        band_140_144_n=20, score=D("1.20"), control_pct=D("51.2"), looks_fine_check=False),
        "statins": dict(too_few=False, flag=True, flag_reason="Few eligible patients are on a statin: 22.0%.",
                        eligible_n=341, on_statin_n=75, on_statin_pct=D("22.0"), not_on_statin_n=266),
        "stock": [("CCB", D("90.0"), False), ("ARB", D("90.0"), False), ("Diuretic", D("90.0"), False)],
        "plan": (1413, 354, 354, 354, 351),
        "rank": dict(uncontrolled_n=286, breaches=["uncontrolled_above_pct", "missed_visit_above_pct"],
                     also_check=False),
    },
    3: {
        "control": dict(under_care_n=1403, controlled_n=745, controlled_pct=D("53.1"), uncontrolled_n=306,
                        uncontrolled_pct=D("21.8"), missed_visit_pct=D("25.0"), ltfu_pct=D("0.0")),
        "new": dict(too_few=False, flag=False, flag_reason=None, new_patients_n=368, new_returned_n=258,
                    new_loss_pct=D("29.9"), new_usable_phone_n=368, new_usable_phone_pct=D("100.0")),
        "calling": dict(too_few=False, flag=False, flag_reason=None, overdue_n=1421, overdue_with_phone_n=1421,
                        called_n=156, called_pct=D("11.0"), early_n=94, early_pct=D("60.3"), calls_per_week=356),
        "titration": dict(too_few=False, flag=False, flag_reason=None, uncontrolled_visits_n=266, stepped_up_n=122,
                          titration_pct=D("45.9"), control_pct=D("53.1"), looks_fine_check=False),
        "fudging": dict(too_few=False, flag=False, flag_reason=None, readings_n=1511, band_135_139_n=19,
                        band_140_144_n=16, score=D("1.19"), control_pct=D("53.1"), looks_fine_check=False),
        "statins": dict(too_few=False, flag=False, flag_reason=None, eligible_n=355, on_statin_n=114,
                        on_statin_pct=D("32.1"), not_on_statin_n=241),
        "stock": [("CCB", D("90.0"), False), ("ARB", D("90.0"), False), ("Diuretic", D("90.0"), False)],
        "plan": (1421, 356, 356, 356, 353),
        "rank": dict(uncontrolled_n=306, breaches=["uncontrolled_above_pct"], also_check=False),
    },
}
FACILITY[87] = copy.deepcopy(FACILITY[3])
FACILITY[87]["stock"] = [("CCB", D("18.0"), True), ("ARB", D("90.0"), False), ("Diuretic", D("90.0"), False)]
FACILITY[87]["calling"].update(called_pct=D("8.0"), called_n=115, overdue_with_phone_n=1436, calls_per_week=359)
FACILITY[87]["plan"] = (1436, 359, 359, 359, 359)
FACILITY[87]["control"]["controlled_pct"] = D("51.2")
FACILITY[12] = copy.deepcopy(FACILITY[11])

# District rows: the selection's own aggregate.
DISTRICT = {
    10: {
        "control": dict(under_care_n=2692, controlled_n=1702, controlled_pct=D("63.2"), uncontrolled_n=452,
                        uncontrolled_pct=D("16.8"), missed_visit_pct=D("19.9"), ltfu_pct=D("0.0")),
        "new": dict(too_few=False, flag=False, flag_reason=None, new_patients_n=628, new_returned_n=451,
                    new_loss_pct=D("28.2"), new_usable_phone_n=628, new_usable_phone_pct=D("100.0")),
        "calling": dict(too_few=False, flag=True, flag_reason="Few overdue patients are called: 6.5%.",
                        overdue_n=2814, overdue_with_phone_n=2814, called_n=183, called_pct=D("6.5"), early_n=78,
                        early_pct=D("42.6"), calls_per_week=704),
        "titration": dict(too_few=False, flag=True,
                          flag_reason="Medicine rarely stepped up: 36.4% of 535 high BP visits.",
                          uncontrolled_visits_n=535, stepped_up_n=195, titration_pct=D("36.4"),
                          control_pct=D("63.2"), looks_fine_check=True),
        "fudging": dict(too_few=False, flag=True,
                        flag_reason="4.44 readings just under 140 for every 1 just over. Check how BP is measured.",
                        readings_n=3268, band_135_139_n=391, band_140_144_n=88, score=D("4.44"),
                        control_pct=D("63.2"), looks_fine_check=True),
        "statins": dict(too_few=False, flag=False, flag_reason=None, eligible_n=695, on_statin_n=188,
                        on_statin_pct=D("27.1"), not_on_statin_n=507),
        "stock": [("CCB", D("90.0"), False), ("ARB", D("90.0"), False), ("Diuretic", D("90.0"), False)],
        "plan": (2814, 704, 704, 704, 702),
        "children": [11, 47],
    },
}

REPORT_KEYS = {
    "report_new_patients": "new",
    "report_calling": "calling",
    "report_titration": "titration",
    "report_fudging": "fudging",
    "report_statins": "statins",
}


def _std(oid: int, selected: bool) -> dict:
    name, level, _parent = UNITS[oid]
    return {"org_unit_id": oid, "org_unit_name": name, "level": level, "is_selected": selected}


def _facility_of(oid: int) -> int:
    return UNITS[oid][2] if UNITS[oid][1] > 3 else oid


class FakeChatDb:
    """In-memory registry functions. Records every call, in order."""

    def __init__(self, data=None, district=None, live=ALL_LIVE, allowed=None):
        self.data = copy.deepcopy(data if data is not None else FACILITY)
        self.district = copy.deepcopy(district if district is not None else DISTRICT)
        self.live = frozenset(live)
        self.allowed = allowed  # None: everything; else a set of node ids
        self.log: list[tuple] = []

    def allows(self, actor: Actor, org_unit_id):
        self.log.append(("allows", org_unit_id))
        if actor.is_admin or self.allowed is None:
            return True
        return org_unit_id in self.allowed

    def live_functions(self, functions):
        self.log.append(("live", None))
        return frozenset(f for f in functions if f in self.live)

    def _section(self, oid: int) -> dict | None:
        return self.data.get(oid) or self.district.get(oid)

    def call(self, function, month, org_unit_id):
        assert function in registry.REGISTRY_FUNCTIONS, function
        self.log.append(("call", function, org_unit_id, month))
        if function not in self.live:
            return []  # a stub returns zero rows
        oid = org_unit_id
        if oid not in UNITS:
            return []
        level = UNITS[oid][1]
        sec = self._section(oid)
        children = self.district.get(oid, {}).get("children", []) if level == 2 else []
        if function == "chat_control_summary":
            rows = []
            if sec is None and level <= 1:
                return [dict(_std(oid, True), too_few=False, **DISTRICT[10]["control"])]
            for o, sel in [(oid, True)] + [(c, False) for c in children]:
                s = self._section(o)
                rows.append(dict(_std(o, sel), too_few=s["control"]["under_care_n"] == 0, **s["control"]))
            return rows
        if function in REPORT_KEYS:
            key = REPORT_KEYS[function]
            rows = []
            for o, sel in [(oid, True)] + [(c, False) for c in children]:
                s = self._section(o)
                if s is None:
                    continue
                rows.append(dict(_std(o, sel), **s[key]))
            return rows
        if function == "chat_drug_stock_gate":
            fac = _facility_of(oid)
            return [{"org_unit_id": fac, "category": c, "patient_days": d, "low": low}
                    for c, d, low in self._section(fac)["stock"]]
        if function == "chat_call_plan":
            n, w1, w2, w3, w4 = sec["plan"]
            return [{"org_unit_id": oid, "overdue_with_phone_n": n, "week_1": w1, "week_2": w2,
                     "week_3": w3, "week_4": w4}]
        if function == "chat_facility_rank_district":
            facs = children if level == 2 else [oid]
            rows = [dict(org_unit_id=f, org_unit_name=UNITS[f][0], **self.data[f]["rank"]) for f in facs]
            rows.sort(key=lambda r: (-r["uncontrolled_n"], r["org_unit_name"]))
            for i, r in enumerate(rows, 1):
                r["rank"] = i
            return rows
        raise AssertionError(function)

    def functions_called(self) -> set[str]:
        return {entry[1] for entry in self.log if entry[0] == "call"}


DISTRICT_TEAM = "heart360tk_district_view_patients_district-d"


def actor_for(login="district.d", teams=(DISTRICT_TEAM,), admin=False) -> Actor:
    return Actor(login=login, actor_id=5, is_admin=admin, teams=tuple(teams))


def chat_client(db: FakeChatDb | None = None, api_key: str = "", claude_factory=None, user=None, teams=None):
    """TestClient with the fake chat db; Grafana says the caller is district.d unless told otherwise."""
    grafana = FakeGrafana(
        user=user or {"id": 5, "login": "district.d", "isGrafanaAdmin": False},
        teams=teams if teams is not None else [{"id": 9, "name": DISTRICT_TEAM, "orgId": 1}],
    )
    client, grafana, _writer = make_client(grafana=grafana)
    app = client.app
    if api_key:
        old = app.state.settings
        app.state.settings = Settings(
            database_url=old.database_url,
            grafana_url=old.grafana_url,
            allowed_origins=old.allowed_origins,
            anthropic_api_key=api_key,
            anthropic_model="claude-sonnet-5-5",
        )
    db = db or FakeChatDb()
    app.state.chat_db = db
    if claude_factory is not None:
        app.state.claude_client_factory = claude_factory
    registry.clear_stub_cache()
    sign_in(client, SESSION)
    return client, db


def ask(client, body):
    return client.post("/chat", headers=write_headers(), json=body)


def chips(client, org, month="2026-10-01"):
    params = {"org_unit_id": "" if org is None else str(org)}
    if month is not None:
        params["reporting_month"] = month
    return client.get("/chat/chips", params=params, headers={"Origin": "http://localhost:3000"})


# --------------------------------------------------------------------------- tests


class RegistryShapeTests(unittest.TestCase):
    def test_registry_keys_are_the_ad30_list(self):
        self.assertEqual(
            set(registry.REGISTRY),
            {"control_summary", "new_patient_return", "phone_capture", "overdue_calling", "titration_rate",
             "fudging_score", "statin_gap", "drug_stock_gate", "facility_rank_district", "call_plan"},
        )
        self.assertNotIn("first_appointment_gap", registry.REGISTRY)

    def test_each_entry_names_one_report_or_chat_function(self):
        for key, entry in registry.REGISTRY.items():
            with self.subTest(key=key):
                self.assertRegex(entry.function, r"^(report|chat)_[a-z_]+$")
        self.assertNotIn("report_statins_patients", registry.REGISTRY_FUNCTIONS)

    def test_chip_labels_are_the_ux_table(self):
        self.assertEqual(
            {c.id: c.label for c in registry.CHIPS.values()},
            {
                "why_control_low": "Why is my BP control low?",
                "who_to_call": "Who should I call this week?",
                "medicines_adjusted": "Are medicines being adjusted?",
                "readings_reliable": "Are my BP readings reliable?",
                "statin_gap": "Who needs a statin?",
                "visit_first": "Which facilities should I visit first?",
            },
        )
        self.assertEqual(registry.PICK_DISTRICT, {"id": "pick_district", "label": "Pick a district"})

    def test_pg_db_refuses_a_name_outside_the_registry(self):
        db = registry.PgChatDb("postgresql://unused")
        with self.assertRaises(ValueError):
            db.call("report_statins_patients", MONTH, 3)
        with self.assertRaises(ValueError):
            db.call("pg_sleep", MONTH, 3)

    def test_parse_helpers(self):
        self.assertIsNone(registry.parse_org_unit(""))
        self.assertIsNone(registry.parse_org_unit("0"))
        self.assertEqual(registry.parse_org_unit("11"), 11)
        for bad in ("1 1", "-3", "x", True, 1.5, "99999999999"):
            self.assertIs(registry.parse_org_unit(bad), False)
        self.assertEqual(registry.parse_month("2026-10-01"), MONTH)
        self.assertIsNone(registry.parse_month(None))
        for bad in ("2026-10-02", "2026-13-01", "Oct-2026", 20261001):
            self.assertIs(registry.parse_month(bad), False)
        self.assertEqual(registry.latest_completed_month(dt.date(2026, 11, 5)), MONTH)
        self.assertEqual(registry.latest_completed_month(dt.date(2026, 1, 31)), dt.date(2025, 12, 1))


class ChipsTests(unittest.TestCase):
    def test_facility_chips_in_ux_order(self):
        client, _db = chat_client()
        res = chips(client, 11)
        self.assertEqual(res.status_code, 200)
        body = res.json()
        self.assertEqual(body["scope"], "facility")
        self.assertEqual(body["place"], {"org_unit_id": 11, "name": "PHC-E", "level": 3, "scope": "facility"})
        self.assertEqual(body["month"], "2026-10-01")
        self.assertEqual(body["mode"], "offline")
        self.assertEqual([c["id"] for c in body["chips"]],
                         ["why_control_low", "who_to_call", "medicines_adjusted", "readings_reliable", "statin_gap"])
        self.assertEqual(body["chips"][0], {"id": "why_control_low", "label": "Why is my BP control low?"})

    def test_sub_facility_answers_for_its_level3_ancestor(self):
        client, db = chat_client()
        body = chips(client, 12).json()
        self.assertEqual(body["scope"], "facility")
        self.assertEqual(body["place"]["org_unit_id"], 11)
        self.assertEqual(body["place"]["name"], "PHC-E")
        # Both the selected node and the scope node were checked.
        self.assertIn(("allows", 12), db.log)
        self.assertIn(("allows", 11), db.log)

    def test_district_chips(self):
        client, _db = chat_client()
        body = chips(client, 10).json()
        self.assertEqual(body["scope"], "district")
        self.assertEqual([c["id"] for c in body["chips"]],
                         ["why_control_low", "visit_first", "who_to_call", "medicines_adjusted",
                          "readings_reliable", "statin_gap"])

    def test_national_or_empty_has_only_pick_a_district(self):
        client, db = chat_client()
        for org in (None, 0, 9):
            with self.subTest(org=org):
                body = chips(client, org).json()
                self.assertEqual(body["scope"], "national")
                self.assertEqual(body["chips"], [{"id": "pick_district", "label": "Pick a district"}])
        # Empty runs no query at all.
        client, db = chat_client()
        chips(client, None)
        self.assertEqual(db.log, [])

    def test_stub_hides_its_chip_and_the_floor_stays(self):
        live = ALL_LIVE - {"report_fudging", "report_statins"}
        client, _db = chat_client(FakeChatDb(live=live))
        ids = [c["id"] for c in chips(client, 11).json()["chips"]]
        self.assertEqual(ids, ["why_control_low", "who_to_call", "medicines_adjusted"])

    def test_stubbed_chip_cannot_be_asked(self):
        client, _db = chat_client(FakeChatDb(live=ALL_LIVE - {"report_statins"}))
        res = ask(client, {"chip_id": "statin_gap", "org_unit_id": "11", "reporting_month": "2026-10-01"})
        self.assertEqual(res.status_code, 400)

    def test_missing_month_is_the_latest_completed_month(self):
        client, db = chat_client()
        body = chips(client, 11, month=None).json()
        expected = registry.latest_completed_month()
        self.assertEqual(body["month"], expected.isoformat())
        months = {entry[3] for entry in db.log if entry[0] == "call"}
        self.assertEqual(months, {expected})

    def test_bad_params_are_400(self):
        client, db = chat_client()
        self.assertEqual(chips(client, "abc").status_code, 400)
        self.assertEqual(chips(client, 11, month="2026-10-15").status_code, 400)
        self.assertEqual(db.log, [])

    def test_unknown_place_is_404(self):
        client, _db = chat_client()
        res = chips(client, 999999)
        self.assertEqual(res.status_code, 404)
        self.assertEqual(res.json()["error"], "not_found")

    def test_signed_out_is_401(self):
        client, _db = chat_client()
        client.cookies.clear()
        self.assertEqual(chips(client, 11).status_code, 401)


class AccessTests(unittest.TestCase):
    def test_refusal_is_403_before_any_query(self):
        db = FakeChatDb(allowed={10, 11, 47, 12})
        client, db = chat_client(db)
        for path in ("chips", "chat"):
            with self.subTest(path=path):
                db.log.clear()
                if path == "chips":
                    res = chips(client, 3)
                else:
                    res = ask(client, {"chip_id": "why_control_low", "org_unit_id": "3"})
                self.assertEqual(res.status_code, 403)
                self.assertEqual(res.json(), {"ok": False, "error": "forbidden",
                                              "message": "You do not have access to this place."})
                self.assertEqual(db.log, [("allows", 3)])

    def test_access_uses_the_session_teams(self):
        db = FakeChatDb(allowed={3})
        client, db = chat_client(
            db, user={"id": 7, "login": "nurse.phc-a", "isGrafanaAdmin": False},
            teams=[{"id": 3, "name": "heart360tk_facility_view_patients_phc-a", "orgId": 1}],
        )
        self.assertEqual(chips(client, 3).status_code, 200)
        self.assertEqual(chips(client, 11).status_code, 403)

    def test_only_registry_functions_run(self):
        client, db = chat_client()
        for org in (11, 10):
            for chip in registry.chips_for("district" if org == 10 else "facility", ALL_KEYS):
                ask(client, {"chip_id": chip["id"], "org_unit_id": str(org), "reporting_month": "2026-10-01"})
        ask(client, {"chip_id": "call_plan", "org_unit_id": "11", "reporting_month": "2026-10-01"})
        self.assertTrue(db.functions_called() <= registry.REGISTRY_FUNCTIONS)

    def test_chat_is_read_only_no_get_on_chat(self):
        client, _db = chat_client()
        self.assertEqual(client.get("/chat").status_code, 405)

    def test_post_needs_the_csrf_header(self):
        client, db = chat_client()
        res = client.post("/chat", headers={"Content-Type": "application/json"},
                          json={"chip_id": "why_control_low", "org_unit_id": "11"})
        self.assertEqual(res.status_code, 403)
        self.assertEqual(db.log, [])


class TypedTextTests(unittest.TestCase):
    def test_keyword_table(self):
        facility = [c["id"] for c in registry.chips_for("facility", ALL_KEYS)]
        district = [c["id"] for c in registry.chips_for("district", ALL_KEYS)]
        cases = {
            "Why is my BP control low?": "why_control_low",
            "who should I call this week": "who_to_call",
            "Are we stepping up medicines?": "medicines_adjusted",
            "are the BP readings reliable": "readings_reliable",
            "who needs a statin": "statin_gap",
        }
        for text, chip in cases.items():
            with self.subTest(text=text):
                self.assertEqual(registry.match_text(text, facility), chip)
        self.assertEqual(registry.match_text("Which facilities should I visit first?", district), "visit_first")
        self.assertIsNone(registry.match_text("Which facilities should I visit first?", facility[2:]))
        self.assertIsNone(registry.match_text("what is the weather", facility))

    def test_typed_text_answers_the_matching_chip(self):
        client, _db = chat_client()
        res = ask(client, {"text": "Why is my BP control low?", "org_unit_id": "11", "reporting_month": "2026-10-01"})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.json()["title"].startswith("What to check at PHC-E?"))

    def test_no_match_reply(self):
        client, _db = chat_client()
        res = ask(client, {"text": "tell me a joke", "org_unit_id": "11"})
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json()["message"], "I can only answer the questions above. Pick one.")

    def test_text_over_200_characters_is_refused(self):
        client, db = chat_client()
        res = ask(client, {"text": "control " * 30, "org_unit_id": "11"})
        self.assertEqual(res.status_code, 400)
        self.assertEqual(db.log, [])
        ok = ask(client, {"text": ("why control low " * 13)[:200], "org_unit_id": "11"})
        self.assertEqual(ok.status_code, 200)

    def test_national_question_says_pick_a_district(self):
        client, _db = chat_client()
        res = ask(client, {"chip_id": "why_control_low", "org_unit_id": ""})
        self.assertEqual(res.status_code, 200)
        body = res.json()
        self.assertEqual(body["place"]["scope"], "national")
        self.assertEqual(body["reasons"][0]["text"], "Pick a district or a facility to ask a question.")


if __name__ == "__main__":
    unittest.main()
