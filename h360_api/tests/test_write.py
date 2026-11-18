"""POST /write/call-result maps save_call_result. The database is a fake; Grafana is a fake."""

from __future__ import annotations

import unittest

from h360_api.routes.write import parse_patient_id
from h360_api.tests.fakes import FakeWriter, make_client, sign_in, write_headers

SESSION = "session-token-abc"


def post(client, body, session=SESSION, headers=None):
    sign_in(client, session)
    return client.post("/write/call-result", headers=headers or write_headers(), json=body)


class WriteTests(unittest.TestCase):
    def test_allowed_patient_returns_the_sql_object(self):
        saved = {
            "ok": True,
            "patient_id": "42",
            "call_date": "2026-11-04",
            "status": "Agreed to visit",
            "result_type": None,
            "org_unit_id": 10,
            "call_id": 9,
            "audit_id": 4,
        }
        client, _grafana, writer = make_client(writer=FakeWriter(result=saved))
        response = post(client, {"patient_id": "42", "status": "Agreed to visit"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), saved)
        _actor, patient_id, status = writer.calls[0]
        self.assertEqual(patient_id, 42)
        self.assertEqual(status, "Agreed to visit")

    def test_numeric_patient_id_is_accepted(self):
        client, _grafana, writer = make_client()
        response = post(client, {"patient_id": 42, "status": "Pending to call"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(writer.calls[0][1], 42)
        self.assertEqual(writer.calls[0][2], "Pending to call")

    def test_non_digit_id_is_400_and_does_not_call_sql(self):
        for patient_id in ("12x", "", "12.0", None, True, -3, 1.5, " 42", "42 "):
            with self.subTest(patient_id=patient_id):
                client, _grafana, writer = make_client()
                response = post(client, {"patient_id": patient_id, "status": "Agreed to visit"})
                self.assertEqual(response.status_code, 400)
                self.assertEqual(response.json()["error"], "bad_request")
                self.assertEqual(writer.calls, [])

    def test_status_must_be_text(self):
        client, _grafana, writer = make_client()
        response = post(client, {"patient_id": "42", "status": None})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"], "bad_request")
        self.assertEqual(writer.calls, [])

    def test_sql_error_codes_map_to_http(self):
        cases = (
            ("bad_request", 400, "The request is missing the user or the patient."),
            ("bad_status", 400, "This call result is not one of the overdue list options."),
            ("forbidden", 403, "You do not have access to this patient's place."),
            ("not_found", 404, "No patient has this ID."),
        )
        for code, http_status, message in cases:
            with self.subTest(code=code):
                writer = FakeWriter(result={"ok": False, "error": code, "message": message})
                client, _grafana, writer = make_client(writer=writer)
                response = post(client, {"patient_id": "99", "status": "Not a real status"})
                self.assertEqual(response.status_code, http_status)
                body = response.json()
                self.assertEqual(body["ok"], False)
                self.assertEqual(body["error"], code)
                self.assertEqual(body["message"], message)
                self.assertEqual(len(writer.calls), 1)

    def test_unknown_status_is_passed_to_sql_and_returned_as_400(self):
        message = "This call result is not one of the overdue list options."
        writer = FakeWriter(result={"ok": False, "error": "bad_status", "message": message})
        client, _grafana, writer = make_client(writer=writer)
        response = post(client, {"patient_id": "00042", "status": "Died today"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"], "bad_status")
        self.assertEqual(writer.calls[0][1], 42)
        self.assertEqual(writer.calls[0][2], "Died today")

    def test_invalid_json_is_400(self):
        client, _grafana, writer = make_client()
        sign_in(client, SESSION)
        response = client.post(
            "/write/call-result",
            headers=write_headers(),
            content=b"not-json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"], "bad_request")
        self.assertEqual(writer.calls, [])

    def test_no_session_is_401(self):
        client, _grafana, writer = make_client()
        response = post(client, {"patient_id": "42", "status": "Agreed to visit"}, session="")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(writer.calls, [])

    def test_parse_patient_id_bounds(self):
        self.assertEqual(parse_patient_id("42"), 42)
        self.assertEqual(parse_patient_id(0), 0)
        self.assertIsNone(parse_patient_id("9223372036854775808"))
        self.assertEqual(parse_patient_id("9223372036854775807"), 9223372036854775807)


if __name__ == "__main__":
    unittest.main()
