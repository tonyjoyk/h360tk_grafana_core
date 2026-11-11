"""Identity from the Grafana session cookie only. Nothing about the caller is read from the body."""

from __future__ import annotations

from dataclasses import dataclass

import httpx


class Unauthenticated(Exception):
    """Grafana did not confirm the session."""


def error_payload(code: str, message: str) -> dict:
    return {"ok": False, "error": code, "message": message}


@dataclass(frozen=True)
class Actor:
    login: str
    actor_id: int
    is_admin: bool
    teams: tuple[str, ...]
    email: str | None = None  # None: SQL records the login instead


class _LeaveTransportOpen(httpx.BaseTransport):
    """Client.close() must not shut a transport the caller still owns."""

    def __init__(self, inner: httpx.BaseTransport) -> None:
        self._inner = inner

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        return self._inner.handle_request(request)

    def close(self) -> None:
        return None


class GrafanaDirectory:
    """Forwards only the grafana_session cookie to Grafana's user APIs."""

    def __init__(self, base_url: str, transport: httpx.BaseTransport | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self._transport = transport

    def _client(self) -> httpx.Client:
        transport = _LeaveTransportOpen(self._transport) if self._transport is not None else None
        return httpx.Client(
            base_url=self.base_url,
            transport=transport,
            timeout=httpx.Timeout(5.0),
            follow_redirects=False,
        )

    def lookup(self, session: str) -> Actor:
        if not session:
            raise Unauthenticated()
        # A fresh client so one user's Set-Cookie can never be replayed for the next caller.
        with self._client() as client:
            try:
                user_res = self._get(client, "/api/user", session)
                if user_res.status_code != 200:
                    raise Unauthenticated()
                teams_res = self._get(client, "/api/user/teams", session)
                if teams_res.status_code != 200:
                    raise Unauthenticated()
            except httpx.HTTPError as exc:
                raise Unauthenticated() from exc
        try:
            user = user_res.json()
            teams = teams_res.json()
        except ValueError as exc:
            raise Unauthenticated() from exc
        return actor_from_grafana(user, teams)

    @staticmethod
    def _get(client: httpx.Client, path: str, session: str) -> httpx.Response:
        # Replace the jar so a Set-Cookie from /api/user is not sent to /api/user/teams.
        client.cookies = httpx.Cookies({"grafana_session": session})
        return client.get(path)


def actor_from_grafana(user: object, teams: object) -> Actor:
    if not isinstance(user, dict) or not isinstance(teams, list):
        raise Unauthenticated()
    login = user.get("login")
    actor_id = user.get("id")
    if not isinstance(login, str) or not login.strip():
        raise Unauthenticated()
    if isinstance(actor_id, bool) or not isinstance(actor_id, int) or actor_id < 0:
        raise Unauthenticated()
    # Only the boolean flag. A string, a missing field, or orgRole Admin does not grant admin.
    is_admin = user.get("isGrafanaAdmin") is True
    names: list[str] = []
    for team in teams:
        if isinstance(team, dict):
            name = team.get("name")
            if isinstance(name, str):
                names.append(name)
    email = user.get("email")
    email = email.strip() if isinstance(email, str) else ""
    if not email or len(email) > 320 or any(ch in email for ch in "\r\n"):
        email = None
    return Actor(login=login, actor_id=actor_id, is_admin=is_admin, teams=tuple(names), email=email)
