"""h360-api. Identity comes from Grafana. Routes under routes/ mount themselves."""

from __future__ import annotations

import importlib
import logging
import pkgutil
import sys
import time

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

from h360_api.auth import GrafanaDirectory, Unauthenticated, error_payload
from h360_api.config import Settings
from h360_api.routes.write import execute_save

ACCESS_LOG = logging.getLogger("h360_api.access")
_UNSAFE = {"POST", "PUT", "PATCH", "DELETE"}
_CORS_HEADERS = "Content-Type, X-H360-Request"
_CORS_METHODS = "GET, POST, OPTIONS"


def configure_logging() -> None:
    if ACCESS_LOG.handlers:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    ACCESS_LOG.addHandler(handler)
    ACCESS_LOG.setLevel(logging.INFO)
    ACCESS_LOG.propagate = False
    # Client libraries must not log request headers (the session cookie) at DEBUG.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)


def mount_routes(app: FastAPI) -> None:
    """Mount every routes module that exposes `router`, in name order."""
    import h360_api.routes as routes_pkg

    prefix = routes_pkg.__name__
    discovered = sorted(pkgutil.iter_modules(routes_pkg.__path__), key=lambda item: item.name)
    for module_info in discovered:
        if module_info.name.startswith("_"):
            continue
        module = importlib.import_module(f"{prefix}.{module_info.name}")
        route_router = getattr(module, "router", None)
        if route_router is not None:
            app.include_router(route_router)


def _origin_allowed(request: Request) -> str | None:
    origin = request.headers.get("origin")
    if origin is None:
        return None
    if origin in request.app.state.settings.allowed_origins:
        return origin
    return ""


def _apply_cors(request: Request, response: Response) -> None:
    origin = _origin_allowed(request)
    if not origin:
        return
    response.headers["Access-Control-Allow-Origin"] = origin
    response.headers["Access-Control-Allow-Credentials"] = "true"
    response.headers["Access-Control-Allow-Headers"] = _CORS_HEADERS
    response.headers["Access-Control-Allow-Methods"] = _CORS_METHODS
    response.headers["Vary"] = "Origin"


def _media_type(request: Request) -> str:
    return request.headers.get("content-type", "").split(";", 1)[0].strip().lower()


def _csrf_block(request: Request) -> JSONResponse | None:
    if request.method not in _UNSAFE:
        return None
    if _media_type(request) != "application/json" or request.headers.get("x-h360-request") != "1":
        return JSONResponse(
            status_code=403,
            content=error_payload("forbidden", "This request is missing the required headers."),
        )
    return None


def _authenticate(request: Request) -> JSONResponse | None:
    session = request.cookies.get("grafana_session", "")
    try:
        actor = request.app.state.directory.lookup(session)
    except Unauthenticated:
        return JSONResponse(
            status_code=401,
            content=error_payload("unauthenticated", "Sign in and try again."),
        )
    request.state.actor = actor
    request.state.login = actor.login
    return None


def create_app(
    settings: Settings | None = None,
    directory: GrafanaDirectory | None = None,
    writer=None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging()
    app = FastAPI(title="h360-api", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.directory = directory or GrafanaDirectory(settings.grafana_url)
    app.state.writer = writer or (
        lambda actor, patient_id, status: execute_save(settings, actor, patient_id, status)
    )

    @app.middleware("http")
    async def gate(request: Request, call_next):
        started = time.perf_counter()
        request.state.login = "-"
        response: Response | None = None
        try:
            if request.url.path == "/healthz" and request.method == "GET":
                response = await call_next(request)
            else:
                origin = _origin_allowed(request)
                if origin == "":
                    response = JSONResponse(
                        status_code=403,
                        content=error_payload("forbidden", "This origin is not allowed."),
                    )
                elif request.method == "OPTIONS":
                    response = Response(status_code=204)
                else:
                    response = _csrf_block(request)
                    if response is None:
                        response = _authenticate(request)
                    if response is None:
                        response = await call_next(request)
            _apply_cors(request, response)
            return response
        except Exception:
            response = JSONResponse(
                status_code=500,
                content=error_payload("bad_request", "The request could not be completed."),
            )
            _apply_cors(request, response)
            return response
        finally:
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            status = response.status_code if response is not None else 500
            login = getattr(request.state, "login", "-") or "-"
            login = login.replace("\r", "").replace("\n", "") or "-"
            # One line: method, path, status, login, ms. Never cookies, keys, prompts, or names.
            ACCESS_LOG.info("%s %s %s %s %dms", request.method, request.url.path, status, login, elapsed_ms)

    @app.get("/healthz")
    def healthz() -> dict:
        return {"ok": True}

    mount_routes(app)
    return app


app = create_app()
