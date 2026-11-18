"""POST /write/drug-stock maps save_drug_stock_entry. The database is a fake; Grafana is a fake."""

from __future__ import annotations

import datetime as dt
import unittest

from h360_api.routes.stock import parse_entries
from h360_api.tests.fakes import FakeGrafana, make_client, route_paths, sign_in, write_headers

SESSION = "session-token-abc"
PATH = "/write/drug-stock"
GOOD = {
    "org_unit_id": 3,
    "month": "2026-10-01",
    "entries": [
        {"drug_code": "329528", "stock": 120},
        {"drug_code": "329526", "stock": None},
        {"drug_code": "331132", "stock": 0},
    ],
}
SAVED = {
    "ok": True,
    "org_unit_id": 3,
    "month": "2026-10-01",
    "accepted": 3,
    "rejected": 0,
    "stored": 3,
    "kept_newer": 0,
    "rejects": [],
}


class FakeStockWriter:
    def __init__(self, result=None):
        self.calls = []
        self.result = dict(SAVED) if result is None else result

    def __call__(self, actor, email, org_unit_id, month, entries):
        self.calls.append((actor, email, org_unit_id, month, entries))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def nurse(email="Nurse.PHC-A@localhost"):
    user = {"id": 7, "login": "nurse.phc-a", "isGrafanaAdmin": False}
    if email is not None:
        user["email"] = email
    return FakeGrafana(user=user)


def stock_client(writer=None, grafana=None):
    client, grafana, _ = make_client(grafana=grafana or nurse())
    writer = writer or FakeStockWriter()
    client.app.state.stock_writer = writer
    return client, grafana, writer


def post(client, body, session=SESSION, headers=None):
    sign_in(client, session)
    return client.post(PATH, headers=headers or write_headers(), json=body)


class StockRouteTests(unittest.TestCase):
    def test_route_is_mounted(self):
        client, _grafana, _writer = stock_client()
        self.assertIn((PATH, frozenset({"POST"})), route_paths(client.app))

    def test_save_passes_session_identity_and_returns_the_sql_object(self):
        client, grafana, writer = stock_client()
        response = post(client, dict(GOOD, org_unit_id="3"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), SAVED)
        actor, email, org_unit_id, month, entries = writer.calls[0]
        self.assertEqual(actor.login, "nurse.phc-a")
        self.assertEqual(actor.teams, ("heart360tk_facility_view_patients_phc-a",))
        self.assertFalse(actor.is_admin)
        self.assertEqual(email, "Nurse.PHC-A@localhost")
        self.assertEqual(org_unit_id, 3)
        self.assertEqual(month, dt.date(2026, 10, 1))
        self.assertEqual(entries, GOOD["entries"])
        # One /api/user and one /api/user/teams call: the email comes from the gate's lookup.
        self.assertEqual([r.url.path for r in grafana.requests], ["/api/user", "/api/user/teams"])
        # Only the session cookie went to Grafana, and only to /api/user*.
        for req in grafana.requests:
            self.assertTrue(req.url.path.startswith("/api/user"))
            self.assertEqual(req.headers.get("cookie"), f"grafana_session={SESSION}")

    def test_identity_in_the_body_is_ignored(self):
        client, _grafana, writer = stock_client()
        body = dict(GOOD, login="admin", isGrafanaAdmin=True, teams=["heart360tk_region_view_patients_ALL"],
                    email="boss@example.org")
        response = post(client, body)
        self.assertEqual(response.status_code, 200)
        actor, email, *_ = writer.calls[0]
        self.assertEqual(actor.login, "nurse.phc-a")
        self.assertFalse(actor.is_admin)
        self.assertEqual(email, "Nurse.PHC-A@localhost")

    def test_missing_email_passes_none(self):
        for email in (None, "", "   ", "a\nb@example.org"):
            with self.subTest(email=email):
                client, _grafana, writer = stock_client(grafana=nurse(email=email))
                response = post(client, GOOD)
                self.assertEqual(response.status_code, 200)
                self.assertIsNone(writer.calls[0][1])

    def test_bad_values_are_400_and_do_not_call_sql(self):
        cases = {
            "org text": dict(GOOD, org_unit_id="3a"),
            "org zero": dict(GOOD, org_unit_id=0),
            "org bool": dict(GOOD, org_unit_id=True),
            "org too big": dict(GOOD, org_unit_id=2147483648),
            "month mid": dict(GOOD, month="2026-10-15"),
            "month short": dict(GOOD, month="2026-10"),
            "month bad": dict(GOOD, month="2026-13-01"),
            "month year 1": dict(GOOD, month="0001-01-01"),
            "no month": {k: v for k, v in GOOD.items() if k != "month"},
            "no entries": dict(GOOD, entries=[]),
            "entries not list": dict(GOOD, entries={"329528": 1}),
            "fraction": dict(GOOD, entries=[{"drug_code": "329528", "stock": 1.5}]),
            "negative": dict(GOOD, entries=[{"drug_code": "329528", "stock": -1}]),
            "over max": dict(GOOD, entries=[{"drug_code": "329528", "stock": 1_000_001}]),
            "string stock": dict(GOOD, entries=[{"drug_code": "329528", "stock": "12"}]),
            "bool stock": dict(GOOD, entries=[{"drug_code": "329528", "stock": True}]),
            "no code": dict(GOOD, entries=[{"stock": 1}]),
            "code with space": dict(GOOD, entries=[{"drug_code": "32 9528", "stock": 1}]),
            "too many": dict(GOOD, entries=[{"drug_code": "329528", "stock": 1}] * 101),
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                client, _grafana, writer = stock_client()
                response = post(client, body)
                self.assertEqual(response.status_code, 400)
                self.assertEqual(response.json()["ok"], False)
                self.assertEqual(response.json()["error"], "bad_request")
                self.assertEqual(writer.calls, [])

    def test_bounds_are_accepted(self):
        client, _grafana, writer = stock_client()
        body = dict(GOOD, entries=[{"drug_code": "329528", "stock": 0}, {"drug_code": "329526", "stock": 1_000_000},
                                   {"drug_code": "331132"}])
        response = post(client, body)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(writer.calls[0][4], [
            {"drug_code": "329528", "stock": 0},
            {"drug_code": "329526", "stock": 1_000_000},
            {"drug_code": "331132", "stock": None},
        ])

    def test_sql_error_codes_map_to_http(self):
        cases = (
            ("bad_request", 400, "The request is missing the user, the place, the month or the stock."),
            ("bad_month", 400, "The month must be the first day of this month or an earlier one."),
            ("not_facility", 400, "Pick one facility to enter stock."),
            ("forbidden", 403, "You do not have access to this place."),
            ("not_found", 404, "No place has this ID."),
        )
        for code, http_status, message in cases:
            with self.subTest(code=code):
                writer = FakeStockWriter(result={"ok": False, "error": code, "message": message})
                client, _grafana, writer = stock_client(writer=writer)
                response = post(client, dict(GOOD, org_unit_id=87))
                self.assertEqual(response.status_code, http_status)
                self.assertEqual(response.json(), {"ok": False, "error": code, "message": message})
                self.assertEqual(len(writer.calls), 1)

    def test_database_failure_is_500_without_detail(self):
        writer = FakeStockWriter(result=RuntimeError("connection to postgres:5432 password=secret failed"))
        client, _grafana, writer = stock_client(writer=writer)
        response = post(client, GOOD)
        self.assertEqual(response.status_code, 500)
        self.assertNotIn("secret", response.text)
        self.assertEqual(response.json()["ok"], False)

    def test_gate_applies(self):
        client, _grafana, writer = stock_client()
        self.assertEqual(post(client, GOOD, session="").status_code, 401)
        self.assertEqual(post(client, GOOD, headers=write_headers(csrf=None)).status_code, 403)
        self.assertEqual(post(client, GOOD, headers=write_headers(content_type="text/plain")).status_code, 403)
        self.assertEqual(post(client, GOOD, headers=write_headers(origin="https://evil.example")).status_code, 403)
        self.assertEqual(writer.calls, [])

    def test_cors_for_the_grafana_origin(self):
        client, _grafana, _writer = stock_client()
        sign_in(client, SESSION)
        preflight = client.options(PATH, headers={
            "Origin": "http://localhost:3000",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type, x-h360-request",
        })
        self.assertEqual(preflight.status_code, 204)
        self.assertEqual(preflight.headers["access-control-allow-origin"], "http://localhost:3000")
        self.assertEqual(preflight.headers["access-control-allow-credentials"], "true")
        response = post(client, GOOD)
        self.assertEqual(response.headers["access-control-allow-origin"], "http://localhost:3000")

    def test_one_log_line_without_cookie_or_values(self):
        client, _grafana, _writer = stock_client()
        with self.assertLogs("h360_api.access", level="INFO") as captured:
            post(client, GOOD)
        self.assertEqual(len(captured.records), 1)
        line = captured.records[0].getMessage()
        self.assertTrue(line.startswith("POST /write/drug-stock 200 nurse.phc-a "))
        self.assertNotIn(SESSION, line)
        self.assertNotIn("329528", line)
        self.assertNotIn("Nurse.PHC-A@localhost", line)


class ParseTests(unittest.TestCase):
    def test_parse_entries(self):
        self.assertIsNone(parse_entries(None))
        self.assertIsNone(parse_entries([1]))
        self.assertEqual(parse_entries([{"drug_code": "1", "stock": None}]), [{"drug_code": "1", "stock": None}])


if __name__ == "__main__":
    unittest.main()
