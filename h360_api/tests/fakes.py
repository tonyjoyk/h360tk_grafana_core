"""In-process Grafana and database stand-ins. No sockets."""

from __future__ import annotations

import httpx
from fastapi.testclient import TestClient

from h360_api.app import create_app
from h360_api.auth import GrafanaDirectory
from h360_api.config import Settings


class FakeGrafana(httpx.BaseTransport):
    def __init__(self, user_status=200, teams_status=200, user=None, teams=None, user_body=None, teams_body=None):
        self.user_status = user_status
        self.teams_status = teams_status
        self.user = user if user is not None else {
            "id": 7,
            "login": "nurse.phc-a",
            "isGrafanaAdmin": False,
        }
        self.teams = teams if teams is not None else [
            {"id": 3, "name": "heart360tk_facility_view_patients_phc-a", "orgId": 1}
        ]
        self.user_body = user_body
        self.teams_body = teams_body
        self.requests: list[httpx.Request] = []

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        if path == "/api/user":
            if self.user_body is not None:
                return httpx.Response(self.user_status, content=self.user_body)
            return httpx.Response(self.user_status, json=self.user)
        if path == "/api/user/teams":
            if self.teams_body is not None:
                return httpx.Response(self.teams_status, content=self.teams_body)
            return httpx.Response(self.teams_status, json=self.teams)
        return httpx.Response(404, json={"message": "not found"})


class FakeWriter:
    def __init__(self, result=None):
        self.calls = []
        self.result = {"ok": True, "patient_id": "42", "status": "Agreed to visit"} if result is None else result

    def __call__(self, actor, patient_id, status):
        self.calls.append((actor, patient_id, status))
        if isinstance(self.result, Exception):
            raise self.result
        if callable(self.result):
            return self.result(actor, patient_id, status)
        return self.result


def make_client(grafana: FakeGrafana | None = None, writer: FakeWriter | None = None, origins=None):
    grafana = grafana or FakeGrafana()
    writer = writer or FakeWriter()
    settings = Settings(
        database_url="postgresql://h360_api:h360_api_mvp@postgres:5432/heart360tk_database",
        grafana_url="http://grafana.test",
        allowed_origins=origins or ("http://localhost:3000", "http://127.0.0.1:3000"),
        anthropic_api_key="",
        anthropic_model="claude-sonnet-5-5",
    )
    directory = GrafanaDirectory(settings.grafana_url, transport=grafana)
    app = create_app(settings=settings, directory=directory, writer=writer)
    return TestClient(app), grafana, writer


def write_headers(origin="http://localhost:3000", csrf="1", content_type="application/json"):
    headers = {}
    if origin is not None:
        headers["Origin"] = origin
    if csrf is not None:
        headers["X-H360-Request"] = csrf
    if content_type is not None:
        headers["Content-Type"] = content_type
    return headers


def sign_in(client: TestClient, session: str = "session-token-abc") -> TestClient:
    client.cookies.clear()
    if session:
        client.cookies.set("grafana_session", session)
    return client


def route_paths(app) -> set[tuple[str, frozenset]]:
    found: set[tuple[str, frozenset]] = set()

    def walk(routes) -> None:
        for route in routes:
            path = getattr(route, "path", None)
            methods = getattr(route, "methods", None)
            if path and methods:
                found.add((path, frozenset(methods)))
            original = getattr(route, "original_router", None)
            if original is not None:
                walk(original.routes)

    walk(app.routes)
    return found
