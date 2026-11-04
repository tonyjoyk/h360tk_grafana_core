"""Runtime settings. Secrets come from the environment and are never logged."""

from __future__ import annotations

import os
from dataclasses import dataclass
from urllib.parse import quote

DEFAULT_ORIGINS = "http://localhost:3000,http://127.0.0.1:3000"
DEFAULT_DB_PASSWORD = "h360_api_mvp"
DEFAULT_GRAFANA_URL = "http://grafana:3000"
DEFAULT_MODEL = "claude-sonnet-5-5"


def split_origins(raw: str) -> tuple[str, ...]:
    return tuple(part.strip() for part in raw.split(",") if part.strip())


def database_url_from_env() -> str:
    """Connection string for role h360_api.

    DATABASE_URL wins when it is set. Otherwise the URL is built with
    H360_API_DB_PASSWORD (default h360_api_mvp).
    """
    explicit = os.environ.get("DATABASE_URL", "").strip()
    if explicit:
        return explicit
    password = os.environ.get("H360_API_DB_PASSWORD", DEFAULT_DB_PASSWORD)
    return (
        "postgresql://h360_api:"
        + quote(password, safe="")
        + "@postgres:5432/heart360tk_database"
    )


@dataclass(frozen=True)
class Settings:
    database_url: str
    grafana_url: str
    allowed_origins: tuple[str, ...]
    anthropic_api_key: str
    anthropic_model: str

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            database_url=database_url_from_env(),
            grafana_url=os.environ.get("GRAFANA_URL", DEFAULT_GRAFANA_URL).strip().rstrip("/"),
            allowed_origins=split_origins(os.environ.get("H360_ALLOWED_ORIGINS", DEFAULT_ORIGINS)),
            anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", ""),
            anthropic_model=os.environ.get("ANTHROPIC_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL,
        )
