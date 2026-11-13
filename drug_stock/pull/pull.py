#!/usr/bin/env python3
"""Pull drug-stock rows into drug_stock_submission.

Wide Google Form response sheets are the primary input. A sheet is wide when
its header has Timestamp and at least one drug column. Each response becomes
one long record per reported drug, then the existing drug_stock_pull_apply
path stores it. Long sheets stay as they are: a header containing org_unit_id
and drug_code, or positional columns A:E with no header.

Timestamp assumption: with valueRenderOption=UNFORMATTED_VALUE and
dateTimeRenderOption=SERIAL_NUMBER, a Timestamp is a Google Sheets serial
(days since 1899-12-30, no Lotus 1900 leap-day bug) holding the spreadsheet's
wall clock. Naive strings use that same clock: YYYY-MM-DD HH:MM:SS, or the
en-US Form shape M/D/YYYY h:mm:ss AM/PM. Aware ISO-8601 strings keep their
offset. The zone is the spreadsheet timeZone, and UTC when that is missing.
submitted_at is always emitted as ISO-8601 with an offset.

Blank drug cells are not reported and are left out. "?" stays unknown and is
passed through. Any other non-numeric stock cell is passed through so
drug_stock_pull_apply can write the reject table (invalid_in_stock).
"""

import json
import math
import os
import re
import subprocess
import sys
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

SA_FIELDS = ("client_email", "private_key", "token_uri")
SHEET_COLUMNS = ("org_unit_id", "reporting_month", "drug_code", "in_stock", "submitted_at")
# Form email key. 0.6.6_to_0.6.7 reads submitted_by and accepts submitter_email
# as an alias (lower-cased on write). Set this to "submitted_by" to send the
# canonical key instead.
SUBMITTER_FIELD = "submitter_email"
DEFAULT_TIME_ZONE = "UTC"
DEFAULT_SHEET_RANGE = "A:ZZ"
SHEETS_EPOCH = datetime(1899, 12, 30)
META_HEADERS = frozenset(
    ("timestamp", "email address", "email", "facility", "reporting month")
)
SPEC_PATH = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "form", "form_field_spec.json")
)


class SourceError(Exception):
    pass


def header_key(value):
    text = "" if value is None else str(value)
    text = text.replace("\ufeff", "").strip().lower()
    return re.sub(r"\s+", " ", text)


def zone(time_zone):
    name = (time_zone or DEFAULT_TIME_ZONE).strip() or DEFAULT_TIME_ZONE
    try:
        return ZoneInfo(name)
    except Exception as exc:
        raise SourceError(f"unknown spreadsheet time zone: {name}") from exc


def normalize_strength(dosage):
    if dosage is None:
        return ""
    text = str(dosage).strip()
    if text.lower() in ("", "blank", "n/a", "na", "-", "?"):
        return ""
    match = re.search(r"(\d+(?:\.\d+)?)\s*mg\b", text, re.IGNORECASE)
    if not match:
        return ""
    number = match.group(1)
    if "." in number:
        number = number.rstrip("0").rstrip(".")
    return f"{number} mg"


def normalize_catalog(rows):
    if not isinstance(rows, list):
        raise SourceError("drug catalog is not readable")
    catalog = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = str(row.get("drug_name") or "").strip()
        code = str(row.get("rxnorm_code") or "").strip()
        if not name or not code:
            continue
        dosage = row.get("dosage")
        catalog.append(
            {
                "drug_name": name,
                "dosage": "" if dosage is None else str(dosage),
                "rxnorm_code": code,
                "label": str(row.get("label") or "").strip(),
            }
        )
    return catalog


def load_drug_catalog(path=None):
    catalog_path = path or SPEC_PATH
    try:
        with open(catalog_path, encoding="utf-8") as handle:
            spec = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceError("drug catalog is not readable") from exc
    fields = spec.get("in_stock_fields") if isinstance(spec, dict) else None
    if not isinstance(fields, list):
        raise SourceError("drug catalog is not readable")
    return normalize_catalog(fields)


def parse_drug_header(header):
    text = "" if header is None else str(header).strip()
    core = re.sub(r"^\s*in[\s-]*stock\s+", "", text, flags=re.IGNORECASE)
    core = re.sub(r"\s*[-–—]?\s*tablets\s+on\s+hand\s*$", "", core, flags=re.IGNORECASE)
    core = core.strip()
    match = re.search(r"(\d+(?:\.\d+)?)\s*mg\b", core, re.IGNORECASE)
    if not match:
        name = re.sub(r"\s+", " ", core).strip(" -")
        return name, ""
    strength = normalize_strength(match.group(0))
    name = (core[: match.start()] + core[match.end() :]).strip(" -")
    name = re.sub(r"\s+", " ", name).strip()
    return name, strength


def looks_like_drug_header(header):
    key = header_key(header)
    if not key or key in META_HEADERS:
        return False
    if "in-stock" in key or "in stock" in key or "tablet" in key:
        return True
    return re.search(r"\d+(?:\.\d+)?\s*mg\b", key) is not None


def match_drug(header, drugs):
    key = header_key(header)
    if not key or key in META_HEADERS:
        return None
    labeled = [
        drug for drug in drugs if drug.get("label") and header_key(drug["label"]) == key
    ]
    if len(labeled) == 1:
        return labeled[0]
    name, strength = parse_drug_header(header)
    if not name:
        return None
    name_key = header_key(name)
    found = [
        drug
        for drug in drugs
        if header_key(drug["drug_name"]) == name_key
        and normalize_strength(drug["dosage"]) == strength
    ]
    if len(found) == 1:
        return found[0]
    return None


def header_has_timestamp(header_row):
    return any(header_key(cell) == "timestamp" for cell in header_row or [])


def is_wide_header(header_row, drugs):
    if not header_has_timestamp(header_row):
        return False
    for cell in header_row:
        if looks_like_drug_header(cell) or match_drug(cell, drugs or []):
            return True
    return False


def format_number(value):
    number = round(float(value), 6)
    if number == int(number):
        return str(int(number))
    return f"{number:.6f}".rstrip("0").rstrip(".")


def stock_cell(value):
    if value is None:
        return "skip", None
    if isinstance(value, bool):
        return "emit", str(value).lower()
    if isinstance(value, (int, float)):
        if isinstance(value, float) and not math.isfinite(value):
            return "emit", str(value)
        return "emit", format_number(value)
    text = str(value).strip()
    if text == "":
        return "skip", None
    return "emit", text


def serial_to_iso(serial, time_zone):
    whole = math.floor(float(serial))
    seconds = int(round((float(serial) - whole) * 86400))
    if seconds >= 86400:
        whole += 1
        seconds -= 86400
    if seconds < 0:
        whole -= 1
        seconds += 86400
    wall = SHEETS_EPOCH + timedelta(days=whole, seconds=seconds)
    return wall.replace(tzinfo=zone(time_zone)).isoformat()


def parse_timestamp(value, time_zone):
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return serial_to_iso(value, time_zone)
    text = str(value).strip()
    if not text:
        return ""
    iso_text = text[:-1] + "+00:00" if text.endswith("Z") else text
    parsed = None
    try:
        parsed = datetime.fromisoformat(iso_text)
    except ValueError:
        parsed = None
    if parsed is not None:
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=zone(time_zone))
        return parsed.isoformat()
    for fmt in (
        "%m/%d/%Y %I:%M:%S %p",
        "%m/%d/%Y %H:%M:%S",
        "%m/%d/%Y %I:%M %p",
        "%m/%d/%Y %H:%M",
    ):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        return parsed.replace(tzinfo=zone(time_zone)).isoformat()
    return text


def parse_reporting_month(value, time_zone):
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        day = datetime.fromisoformat(serial_to_iso(value, time_zone)).date()
        return day.replace(day=1).isoformat()
    text = str(value).strip()
    if not text:
        return ""
    match = re.fullmatch(r"(\d{4})-(\d{2})(?:-\d{2})?", text)
    if match:
        year = int(match.group(1))
        month = int(match.group(2))
        if 1 <= month <= 12:
            return f"{year:04d}-{month:02d}-01"
        return text
    match = re.fullmatch(r"(\d{1,2})/(\d{4})", text)
    if match:
        month = int(match.group(1))
        year = int(match.group(2))
        if 1 <= month <= 12:
            return f"{year:04d}-{month:02d}-01"
        return text
    for fmt in ("%B %Y", "%b %Y", "%Y/%m/%d", "%m/%d/%Y"):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        return parsed.date().replace(day=1).isoformat()
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return text
    return parsed.date().replace(day=1).isoformat()


def parse_org_unit_id(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)) and math.isfinite(float(value)) and float(value).is_integer():
        return str(int(value))
    text = str(value).strip()
    if re.fullmatch(r"\d+", text):
        return text
    match = re.search(r"\((?:id\s*:?\s*)?(\d+)\)\s*$", text, re.IGNORECASE)
    if match:
        return match.group(1)
    return text


def row_is_blank(raw):
    return all(cell is None or str(cell).strip() == "" for cell in raw)


def value_at(raw, index):
    if index is None or index >= len(raw):
        return ""
    value = raw[index]
    return "" if value is None else value


def wide_rows_to_long(values, drugs, time_zone, first_row=1):
    header = list(values[0])
    positions = {
        "submitted_at": None,
        "submitter": None,
        "org_unit_id": None,
        "reporting_month": None,
    }
    drug_positions = []
    for index, cell in enumerate(header):
        key = header_key(cell)
        if key == "timestamp" and positions["submitted_at"] is None:
            positions["submitted_at"] = index
        elif key in ("email address", "email") and positions["submitter"] is None:
            positions["submitter"] = index
        elif key == "facility" and positions["org_unit_id"] is None:
            positions["org_unit_id"] = index
        elif key == "reporting month" and positions["reporting_month"] is None:
            positions["reporting_month"] = index
        elif key:
            drug_positions.append(index)

    records = []
    for offset, raw in enumerate(values[1:]):
        if row_is_blank(raw):
            continue
        sheet_row = int(first_row) + 1 + offset
        submitted = parse_timestamp(value_at(raw, positions["submitted_at"]), time_zone)
        email = str(value_at(raw, positions["submitter"])).strip()
        org_unit_id = parse_org_unit_id(value_at(raw, positions["org_unit_id"]))
        reporting_month = parse_reporting_month(
            value_at(raw, positions["reporting_month"]), time_zone
        )
        for pos in drug_positions:
            action, stock = stock_cell(value_at(raw, pos))
            if action == "skip":
                continue
            header_text = "" if header[pos] is None else str(header[pos]).strip()
            matched = match_drug(header_text, drugs)
            if matched is None and not looks_like_drug_header(header_text):
                continue
            drug_code = matched["rxnorm_code"] if matched else header_text
            records.append(
                {
                    "org_unit_id": org_unit_id,
                    "reporting_month": reporting_month,
                    "drug_code": drug_code,
                    "in_stock": stock,
                    "submitted_at": submitted,
                    SUBMITTER_FIELD: email,
                    "sheet_row": sheet_row,
                }
            )
    return records


def rows_from_sheet_values(values, drugs=None, time_zone=None, first_row=1):
    if not values:
        return []
    if header_has_timestamp(values[0]):
        catalog = normalize_catalog(drugs) if drugs is not None else load_drug_catalog()
        if is_wide_header(values[0], catalog):
            return wide_rows_to_long(
                values,
                catalog,
                time_zone or DEFAULT_TIME_ZONE,
                first_row=first_row,
            )
    header = [str(cell).strip().lower() for cell in values[0]]
    if "org_unit_id" in header and "drug_code" in header:
        start = 1
        indexes = {name: header.index(name) for name in SHEET_COLUMNS if name in header}
    else:
        start = 0
        indexes = {name: pos for pos, name in enumerate(SHEET_COLUMNS)}
    rows = []
    for raw in values[start:]:
        cells = ["" if cell is None else str(cell) for cell in raw]
        record = {}
        for name in SHEET_COLUMNS:
            pos = indexes.get(name)
            record[name] = cells[pos] if pos is not None and pos < len(cells) else ""
        if all(record[name].strip() == "" for name in SHEET_COLUMNS):
            continue
        rows.append(record)
    return rows


def grid_first_row(range_name):
    text = (range_name or "").split("!")[-1]
    match = re.match(r"[A-Za-z]{0,3}(\d+)", text)
    if not match:
        return 1
    return int(match.group(1))


def records_from_loaded(data, drugs=None, time_zone=None):
    if isinstance(data, dict):
        values = data.get("values")
        if not isinstance(values, list):
            raise SourceError("fixture must be a JSON array")
        if "protocol_drugs" in data:
            catalog = data.get("protocol_drugs")
        else:
            catalog = drugs
        tz = data.get("timeZone") or data.get("timezone") or time_zone
        first_row = data.get("first_row") or 1
        return rows_from_sheet_values(
            values, drugs=catalog, time_zone=tz, first_row=int(first_row)
        )
    if isinstance(data, list):
        if data and isinstance(data[0], list):
            return rows_from_sheet_values(data, drugs=drugs, time_zone=time_zone)
        return data
    raise SourceError("fixture must be a JSON array")


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
    if isinstance(data, dict) and isinstance(data.get("values"), list):
        return data
    if not isinstance(data, list):
        raise SourceError("fixture must be a JSON array")
    return data


def build_sheets_service(creds_path):
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
    return build("sheets", "v4", credentials=creds, cache_discovery=False)


def fetch_sheet(service, sheet_id, range_name):
    meta = (
        service.spreadsheets()
        .get(spreadsheetId=sheet_id, fields="properties.timeZone")
        .execute()
    )
    time_zone = ((meta or {}).get("properties") or {}).get("timeZone") or DEFAULT_TIME_ZONE
    result = (
        service.spreadsheets()
        .values()
        .get(
            spreadsheetId=sheet_id,
            range=range_name,
            valueRenderOption="UNFORMATTED_VALUE",
            dateTimeRenderOption="SERIAL_NUMBER",
        )
        .execute()
    )
    return {"values": result.get("values") or [], "timeZone": time_zone}


def unpack_fetched(fetched, drug_catalog):
    if isinstance(fetched, list):
        return fetched, DEFAULT_TIME_ZONE, drug_catalog
    if isinstance(fetched, dict):
        if "protocol_drugs" in fetched:
            catalog = fetched.get("protocol_drugs")
        else:
            catalog = drug_catalog
        return fetched.get("values") or [], fetched.get("timeZone") or DEFAULT_TIME_ZONE, catalog
    raise SourceError("sheet read failed")


def load_sheet(sheet_id, creds_path, fetcher=None, drug_catalog=None, range_name=None):
    if range_name is None:
        range_name = os.environ.get("DRUG_STOCK_SHEET_RANGE", "").strip() or DEFAULT_SHEET_RANGE
    if fetcher is None:
        service = build_sheets_service(creds_path)
        try:
            fetched = fetch_sheet(service, sheet_id, range_name)
        except Exception as exc:
            raise SourceError("sheet read failed") from exc
    else:
        fetched = fetcher(sheet_id)
    values, time_zone, catalog = unpack_fetched(fetched, drug_catalog)
    return rows_from_sheet_values(
        values,
        drugs=catalog,
        time_zone=time_zone,
        first_row=grid_first_row(range_name),
    )


def load_rows(sheet_fetcher=None, drug_catalog=None):
    fixture = os.environ.get("DRUG_STOCK_FIXTURE_PATH", "").strip()
    sheet_id = os.environ.get("DRUG_STOCK_SHEET_ID", "").strip()
    creds = os.environ.get("DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    if fixture:
        return records_from_loaded(load_fixture(fixture), drugs=drug_catalog)
    if sheet_fetcher is not None:
        if not sheet_id:
            raise SourceError(
                "sheet pull needs DRUG_STOCK_SHEET_ID and DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS"
            )
        return load_sheet(
            sheet_id,
            creds,
            fetcher=sheet_fetcher,
            drug_catalog=drug_catalog,
        )
    if sheet_id or creds:
        if not sheet_id or not creds:
            raise SourceError(
                "sheet pull needs DRUG_STOCK_SHEET_ID and DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS"
            )
        return load_sheet(sheet_id, creds, drug_catalog=drug_catalog)
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
