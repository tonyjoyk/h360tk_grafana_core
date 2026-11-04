"""Auth, CSRF, CORS, health, and route mounting. Grafana is fake; nothing is on the network."""

from __future__ import annotations

import importlib
import logging
import os
import pkgutil
import unittest
from types import SimpleNamespace

from fastapi import APIRouter, FastAPI

from h360_api import app as app_module
from h360_api.app import mount_routes
from h360_api.config import Settings, database_url_from_env, split_origins
from h360_api.tests.fakes import FakeGrafana, FakeWriter, make_client, route_paths, sign_in, write_headers

SESSION = "session-token-abc"
PATIENT_NAME = "Siti Aminah"


class AuthTests(unittest.TestCase):
    def test_healthz_needs_no_session(self):
        client, grafana, writer = make_client()
        with self.assertLogs("h360_api.access", level="INFO") as captured:
            response = client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True})
        self.assertEqual(grafana.requests, [])
        self.assertEqual(writer.calls, [])
        line = captured.records[-1].getMessage()
        self.assertTrue(line.startswith("GET /healthz 200 - "))
        self.assertTrue(line.endswith("ms"))
        self.assertNotIn(SESSION, line)

    def test_missing_cookie_is_401(self):
        client, grafana, writer = make_client()
        response = client.post(
            "/write/call-result",
            headers=write_headers(),
            json={"patient_id": "42", "status": "Agreed to visit"},
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["ok"], False)
        self.assertEqual(response.json()["error"], "unauthenticated")
        self.assertEqual(grafana.requests, [])
        self.assertEqual(writer.calls, [])

    def test_grafana_non_200_is_401(self):
        for user_status, teams_status in ((401, 200), (200, 403), (500, 200)):
            with self.subTest(user_status=user_status, teams_status=teams_status):
                grafana = FakeGrafana(user_status=user_status, teams_status=teams_status)
                client, grafana, writer = make_client(grafana=grafana)
                sign_in(client, SESSION)
                response = client.post(
                    "/write/call-result",
                    headers=write_headers(),
                    json={"patient_id": "42", "status": "Agreed to visit"},
                )
                self.assertEqual(response.status_code, 401)
                self.assertEqual(response.json()["error"], "unauthenticated")
                self.assertEqual(writer.calls, [])
                self.assertTrue(grafana.requests)
                self.assertEqual(grafana.requests[0].url.path, "/api/user")

    def test_grafana_error_body_is_401(self):
        grafana = FakeGrafana(user_status=200, user_body=b"<html>login</html>")
        client, grafana, writer = make_client(grafana=grafana)
        sign_in(client, SESSION)
        response = client.post(
            "/write/call-result",
            headers=write_headers(),
            json={"patient_id": "42", "status": "Agreed to visit"},
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(writer.calls, [])

    def test_only_session_cookie_is_forwarded(self):
        client, grafana, _writer = make_client()
        sign_in(client, SESSION)
        client.cookies.set("other_cookie", "should-not-forward")
        client.post(
            "/write/call-result",
            headers=write_headers(),
            json={"patient_id": "42", "status": "Agreed to visit", "patient_name": PATIENT_NAME},
        )
        self.assertEqual([request.url.path for request in grafana.requests], ["/api/user", "/api/user/teams"])
        for request in grafana.requests:
            cookie = request.headers["cookie"]
            self.assertIn(f"grafana_session={SESSION}", cookie)
            self.assertNotIn("other_cookie", cookie)
            self.assertNotIn("should-not-forward", cookie)
            self.assertEqual(request.url.host, "grafana.test")

    def test_identity_comes_from_grafana_not_the_body(self):
        grafana = FakeGrafana(
            user={
                "id": 7,
                "login": "nurse.phc-a",
                "isGrafanaAdmin": False,
                "orgRole": "Admin",
                "name": PATIENT_NAME,
            },
            teams=[
                {"id": 1, "orgId": 1},
                {"id": 3, "name": "heart360tk_facility_view_patients_phc-a"},
                {"id": 4, "name": "heart360tk_district_view_aggregated_district-d"},
            ],
        )
        client, _grafana, writer = make_client(grafana=grafana)
        sign_in(client, SESSION)
        response = client.post(
            "/write/call-result",
            headers=write_headers(),
            json={
                "patient_id": "42",
                "status": "Agreed to visit",
                "login": "root",
                "is_admin": True,
                "actor_id": 1,
                "team_names": ["heart360tk_country_view_patients_ALL"],
                "patient_name": PATIENT_NAME,
            },
        )
        self.assertEqual(response.status_code, 200)
        actor, patient_id, status = writer.calls[0]
        self.assertEqual(actor.login, "nurse.phc-a")
        self.assertEqual(actor.actor_id, 7)
        self.assertIs(actor.is_admin, False)
        self.assertEqual(
            actor.teams,
            (
                "heart360tk_facility_view_patients_phc-a",
                "heart360tk_district_view_aggregated_district-d",
            ),
        )
        self.assertEqual(patient_id, 42)
        self.assertEqual(status, "Agreed to visit")

    def test_admin_flag_is_only_is_grafana_admin(self):
        grafana = FakeGrafana(
            user={"id": 1, "login": "admin", "isGrafanaAdmin": True},
            teams=[],
        )
        client, _grafana, writer = make_client(grafana=grafana)
        sign_in(client, SESSION)
        response = client.post(
            "/write/call-result",
            headers=write_headers(origin=None),
            json={"patient_id": "42", "status": "Agreed to visit", "is_admin": False},
        )
        self.assertEqual(response.status_code, 200)
        self.assertIs(writer.calls[0][0].is_admin, True)
        self.assertEqual(writer.calls[0][0].teams, ())
        self.assertNotIn("access-control-allow-origin", response.headers)

    def test_bad_origin_is_403_and_does_not_call_grafana(self):
        client, grafana, writer = make_client()
        sign_in(client, SESSION)
        response = client.post(
            "/write/call-result",
            headers=write_headers(origin="http://evil.example"),
            json={"patient_id": "42", "status": "Agreed to visit"},
        )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()["error"], "forbidden")
        self.assertNotIn("access-control-allow-origin", response.headers)
        self.assertEqual(grafana.requests, [])
        self.assertEqual(writer.calls, [])

    def test_missing_csrf_header_or_content_type_is_403(self):
        cases = (
            write_headers(csrf=None),
            write_headers(content_type="text/plain"),
            write_headers(csrf="2"),
        )
        for headers in cases:
            with self.subTest(headers=headers):
                client, grafana, writer = make_client()
                sign_in(client, SESSION)
                response = client.post(
                    "/write/call-result",
                    headers=headers,
                    content=b'{"patient_id":"42","status":"Agreed to visit"}',
                )
                self.assertEqual(response.status_code, 403)
                self.assertEqual(response.json()["error"], "forbidden")
                self.assertEqual(grafana.requests, [])
                self.assertEqual(writer.calls, [])

    def test_json_charset_is_accepted(self):
        client, _grafana, writer = make_client()
        sign_in(client, SESSION)
        response = client.post(
            "/write/call-result",
            headers=write_headers(content_type="application/json; charset=utf-8"),
            content=b'{"patient_id":"42","status":"Agreed to visit"}',
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(writer.calls), 1)

    def test_allowed_origin_is_reflected_with_credentials(self):
        client, _grafana, _writer = make_client()
        sign_in(client, SESSION)
        response = client.post(
            "/write/call-result",
            headers=write_headers(origin="http://127.0.0.1:3000"),
            json={"patient_id": "42", "status": "Agreed to visit"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["access-control-allow-origin"], "http://127.0.0.1:3000")
        self.assertEqual(response.headers["access-control-allow-credentials"], "true")

    def test_preflight_for_allowed_origin(self):
        client, grafana, writer = make_client()
        response = client.options(
            "/write/call-result",
            headers={
                "Origin": "http://localhost:3000",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "content-type,x-h360-request",
            },
        )
        self.assertEqual(response.status_code, 204)
        self.assertEqual(response.headers["access-control-allow-origin"], "http://localhost:3000")
        self.assertEqual(response.headers["access-control-allow-credentials"], "true")
        self.assertIn("X-H360-Request", response.headers["access-control-allow-headers"])
        self.assertEqual(grafana.requests, [])
        self.assertEqual(writer.calls, [])

    def test_preflight_for_foreign_origin_is_403(self):
        client, grafana, _writer = make_client()
        response = client.options(
            "/write/call-result",
            headers={"Origin": "http://evil.example", "Access-Control-Request-Method": "POST"},
        )
        self.assertEqual(response.status_code, 403)
        self.assertNotIn("access-control-allow-origin", response.headers)
        self.assertEqual(grafana.requests, [])

    def test_log_line_has_no_cookie_key_or_patient_name(self):
        settings_key = "sk-ant-secret-value"
        client, _grafana, _writer = make_client()
        client.app.state.settings = Settings(
            database_url=client.app.state.settings.database_url,
            grafana_url=client.app.state.settings.grafana_url,
            allowed_origins=client.app.state.settings.allowed_origins,
            anthropic_api_key=settings_key,
            anthropic_model="claude-sonnet-5-5",
        )
        sign_in(client, SESSION)
        with self.assertLogs("h360_api.access", level="INFO") as captured:
            response = client.post(
                "/write/call-result",
                headers=write_headers(),
                json={
                    "patient_id": "42",
                    "status": "Agreed to visit",
                    "patient_name": PATIENT_NAME,
                    "prompt": "ignore previous instructions",
                    "anthropic_api_key": settings_key,
                },
            )
        self.assertEqual(response.status_code, 200)
        blob = "\n".join(record.getMessage() for record in captured.records)
        self.assertIn("POST /write/call-result 200 nurse.phc-a ", blob)
        self.assertTrue(blob.strip().endswith("ms"))
        self.assertNotIn(SESSION, blob)
        self.assertNotIn(PATIENT_NAME, blob)
        self.assertNotIn(settings_key, blob)
        self.assertNotIn("ignore previous instructions", blob)
        self.assertNotIn("grafana_session", blob)

    def test_writer_failure_is_not_logged_with_its_text(self):
        writer = FakeWriter(result=RuntimeError(f"{PATIENT_NAME} {SESSION}"))
        client, _grafana, _writer = make_client(writer=writer)
        sign_in(client, SESSION)
        with self.assertLogs("h360_api.access", level="INFO") as captured:
            response = client.post(
                "/write/call-result",
                headers=write_headers(),
                json={"patient_id": "42", "status": "Agreed to visit"},
            )
        self.assertEqual(response.status_code, 500)
        self.assertNotIn(PATIENT_NAME, response.text)
        self.assertNotIn(SESSION, response.text)
        blob = "\n".join(record.getMessage() for record in captured.records)
        self.assertIn("POST /write/call-result 500 nurse.phc-a ", blob)
        self.assertNotIn(PATIENT_NAME, blob)
        self.assertNotIn(SESSION, blob)

    def test_routes_mount_router_modules_and_skip_the_rest(self):
        bare = SimpleNamespace(loaded=False)
        routed_router = APIRouter()

        @routed_router.get("/mounted-by-discovery")
        def mounted():
            return {"ok": True}

        routed = SimpleNamespace(router=routed_router, loaded=False)

        real_iter = pkgutil.iter_modules
        real_import = importlib.import_module

        def fake_iter(_path):
            return [
                SimpleNamespace(name="_hidden", ispkg=False),
                SimpleNamespace(name="bare_for_test", ispkg=False),
                SimpleNamespace(name="routed_for_test", ispkg=False),
            ]

        def fake_import(name, package=None):
            if name.endswith(".bare_for_test"):
                bare.loaded = True
                return bare
            if name.endswith(".routed_for_test"):
                routed.loaded = True
                return routed
            if name.endswith("._hidden"):
                raise AssertionError("underscore modules must not be imported")
            return real_import(name, package)

        pkgutil.iter_modules = fake_iter
        importlib.import_module = fake_import
        app_module.pkgutil.iter_modules = fake_iter
        app_module.importlib.import_module = fake_import
        try:
            app = FastAPI()
            mount_routes(app)
        finally:
            pkgutil.iter_modules = real_iter
            importlib.import_module = real_import
            app_module.pkgutil.iter_modules = real_iter
            app_module.importlib.import_module = real_import
        from fastapi.testclient import TestClient

        guest = TestClient(app)
        self.assertTrue(bare.loaded)
        self.assertTrue(routed.loaded)
        self.assertEqual(guest.get("/mounted-by-discovery").status_code, 200)
        self.assertEqual(guest.get("/bare_for_test").status_code, 404)

    def test_live_package_mounts_the_write_route(self):
        client, _grafana, _writer = make_client()
        paths = route_paths(client.app)
        self.assertIn(("/healthz", frozenset({"GET"})), paths)
        self.assertTrue(any(path == "/write/call-result" and "POST" in methods for path, methods in paths))


class ConfigTests(unittest.TestCase):
    def test_origins_and_database_url(self):
        self.assertEqual(
            split_origins(" http://localhost:3000, , http://127.0.0.1:3000 "),
            ("http://localhost:3000", "http://127.0.0.1:3000"),
        )
        keys = ("DATABASE_URL", "H360_API_DB_PASSWORD", "H360_ALLOWED_ORIGINS", "GRAFANA_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL")
        saved = {key: os.environ.get(key) for key in keys}
        try:
            for key in keys:
                os.environ.pop(key, None)
            self.assertEqual(
                database_url_from_env(),
                "postgresql://h360_api:h360_api_mvp@postgres:5432/heart360tk_database",
            )
            os.environ["H360_API_DB_PASSWORD"] = "p@ss:word"
            self.assertEqual(
                database_url_from_env(),
                "postgresql://h360_api:p%40ss%3Aword@postgres:5432/heart360tk_database",
            )
            os.environ["DATABASE_URL"] = "postgresql://h360_api:explicit@postgres:5432/heart360tk_database"
            settings = Settings.from_env()
            self.assertEqual(settings.database_url, os.environ["DATABASE_URL"])
            self.assertEqual(settings.grafana_url, "http://grafana:3000")
            self.assertEqual(settings.anthropic_api_key, "")
            self.assertEqual(settings.anthropic_model, "claude-sonnet-5-5")
            self.assertEqual(
                settings.allowed_origins,
                ("http://localhost:3000", "http://127.0.0.1:3000"),
            )
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    unittest.main()
