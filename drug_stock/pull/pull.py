#!/usr/bin/env python3
"""Pull long drug-stock rows into drug_stock_submission."""

import json
import os
import re
import subprocess
import sys
import uuid

SA_FIELDS = ("client_email", "private_key", "token_uri")
SHEET_COLUMNS = ("org_unit_id", "reporting_month", "drug_code", "in_stock", "submitted_at")


class SourceError(Exception):
    pass


def rows_from_sheet_values(values):
    if not values:
        return []
    start = 0
    header = [str(cell).strip().lower() for cell in values[0]]
    if header and header[0] == "org_unit_id":
        start = 1
    rows = []
    for raw in values[start:]:
        cells = ["" if cell is None else str(cell) for cell in raw]
        while len(cells) < len(SHEET_COLUMNS):
            cells.append("")
        cells = cells[: len(SHEET_COLUMNS)]
        if all(cell.strip() == "" for cell in cells):
            continue
        rows.append(dict(zip(SHEET_COLUMNS, cells)))
    return rows


def load_fixture(path):
    if not os.path.isfile(path):
        raise SourceError("fixture not found")
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SourceError("fixture is not valid JSON") from exc
    except OSError as exc:
        raise SourceError("fixture is not readable") from exc
    if not isinstance(data, list):
        raise SourceError("fixture must be a JSON array")
    return data


def load_sheet(sheet_id, creds_path):
    if not os.path.isfile(creds_path):
        raise SourceError("service account file not found")
    try:
        with open(creds_path, encoding="utf-8") as handle:
            info = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceError("service account file is not valid") from exc
    if not isinstance(info, dict) or any(not info.get(field) for field in SA_FIELDS):
        raise SourceError("service account file is not valid")

    try:
        from google.oauth2.service_account import Credentials
        from googleapiclient.discovery import build
    except ImportError as exc:
        raise SourceError("Google Sheets client is not installed") from exc

    creds = Credentials.from_service_account_file(
        creds_path,
        scopes=["https://www.googleapis.com/auth/spreadsheets.readonly"],
    )
    service = build("sheets", "v4", credentials=creds, cache_discovery=False)
    range_name = os.environ.get("DRUG_STOCK_SHEET_RANGE", "").strip() or "A:E"
    try:
        result = (
            service.spreadsheets()
            .values()
            .get(spreadsheetId=sheet_id, range=range_name)
            .execute()
        )
    except Exception as exc:
        raise SourceError("sheet read failed") from exc
    return rows_from_sheet_values(result.get("values") or [])


def load_rows():
    fixture = os.environ.get("DRUG_STOCK_FIXTURE_PATH", "").strip()
    sheet_id = os.environ.get("DRUG_STOCK_SHEET_ID", "").strip()
    creds = os.environ.get("DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    if fixture:
        return load_fixture(fixture)
    if sheet_id or creds:
        if not sheet_id or not creds:
            raise SourceError(
                "sheet pull needs DRUG_STOCK_SHEET_ID and DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS"
            )
        return load_sheet(sheet_id, creds)
    raise SourceError("no drug stock source configured")


def database_name():
    name = os.environ.get("DRUG_STOCK_PULL_DB", "").strip() or os.environ.get("PGDATABASE", "").strip()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name or ""):
        raise SystemExit("DRUG_STOCK_PULL_DB or PGDATABASE must be a simple identifier")
    return name


def can_connect(prefix, database):
    probe = subprocess.run(
        prefix + ["-d", database, "-X", "-v", "ON_ERROR_STOP=1", "-c", "SELECT 1"],
        capture_output=True,
        text=True,
    )
    return probe.returncode == 0


def psql_prefix(database):
    mode = os.environ.get("DRUG_STOCK_PSQL_MODE", "auto")
    sudo_prefix = ["sudo", "-n", "-u", "postgres", "psql"]
    local_prefix = ["psql"]
    if mode in ("sudo", "auto") and can_connect(sudo_prefix, database):
        return sudo_prefix
    if mode == "sudo":
        raise SystemExit("sudo -u postgres psql failed")
    if mode in ("local", "auto") and can_connect(local_prefix, database):
        return local_prefix
    raise SystemExit("psql cannot connect")


def quote_payload(payload):
    for _ in range(3):
        fence = "$p" + uuid.uuid4().hex + "$"
        if fence not in payload:
            return fence
    raise RuntimeError("could not quote payload")


def apply_rows(rows):
    database = database_name()
    payload = json.dumps(rows, ensure_ascii=False)
    fence = quote_payload(payload)
    sql = f"""
BEGIN;
SET ROLE heart360tk;
SELECT accepted, rejected
FROM heart360tk_schema.drug_stock_pull_apply({fence}{payload}{fence}::jsonb);
COMMIT;
"""
    proc = subprocess.run(
        psql_prefix(database)
        + ["-d", database, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-tA", "-F", "|", "-f", "-"],
        input=sql,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "psql failed").strip()
        raise SystemExit(detail)
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if len(lines) != 1 or lines[0].count("|") != 1:
        raise SystemExit(f"unexpected pull result: {proc.stdout!r}")
    accepted, rejected = lines[0].split("|")
    return int(accepted), int(rejected)


def main():
    try:
        rows = load_rows()
    except SourceError as exc:
        print(f"source error: {exc}", file=sys.stderr)
        return 1
    accepted, rejected = apply_rows(rows)
    print(f"accepted={accepted} rejected={rejected}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
