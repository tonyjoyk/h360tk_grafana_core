import json
import logging
import os
from datetime import date, datetime

from psycopg2 import sql

log = logging.getLogger(__name__)

# JSON codes are the toolkit column names. A code is table-qualified only when
# the same column exists on both the hypertension and diabetes tables.
# One code can fill several columns, because the dashboards read the same
# count from more than one table.
INDICATORS: dict[str, tuple[tuple[str, str], ...]] = {
    'nb_patients_controlled': (('heart360_patients_category', 'nb_patients_controlled'),),
    'nb_patients_uncontrolled': (('heart360_patients_category', 'nb_patients_uncontrolled'),),
    'nb_patients_no_visit': (('heart360_patients_category', 'nb_patients_no_visit'),),
    'nb_patients_visit_no_bp': (('heart360_patients_category', 'nb_patients_visit_no_bp'),),
    'heart360_patients_category.nb_patients_lost_to_follow_up': (
        ('heart360_patients_category', 'nb_patients_lost_to_follow_up'),
    ),
    'heart360_patients_category.total_number_of_patients': (
        ('heart360_patients_category', 'total_number_of_patients'),
    ),
    'nb_patients_newly_registered': (('heart360_patients_category', 'nb_patients_newly_registered'),),
    'nb_patients_under_care': (
        ('heart360_patients_under_care', 'nb_patients_under_care'),
        ('heart360_patients_category', 'nb_patients_under_care'),
    ),
    'nb_new_patients': (('heart360_patients_registered', 'nb_new_patients'),),
    'diabetes_controlled': (('heart360_blood_sugar_controlled', 'diabetes_controlled'),),
    'uncontrolled_moderate': (('heart360_blood_sugar_severity', 'uncontrolled_moderate'),),
    'uncontrolled_high': (('heart360_blood_sugar_severity', 'uncontrolled_high'),),
    'missed_visit': (('heart360_blood_sugar_missed_visits', 'missed_visit'),),
    'nb_dm_patients_under_care': (
        ('heart360_dm_patients_under_care', 'nb_dm_patients_under_care'),
        ('heart360_blood_sugar_controlled', 'diabetes_patients_under_care'),
        ('heart360_blood_sugar_severity', 'diabetes_patients_under_care'),
        ('heart360_blood_sugar_missed_visits', 'diabetes_patients_under_care'),
        ('heart360_dm_bp_control', 'dm_patients_under_care'),
    ),
    'nb_new_dm_patients': (('heart360_dm_patients_under_care', 'nb_new_dm_patients'),),
    'heart360_dm_patients_catagory.nb_patients_lost_to_follow_up': (
        ('heart360_dm_patients_catagory', 'nb_patients_lost_to_follow_up'),
    ),
    'heart360_dm_patients_catagory.total_number_of_patients': (
        ('heart360_dm_patients_catagory', 'total_number_of_patients'),
    ),
    'bp_controlled_140_90': (('heart360_dm_bp_control', 'bp_controlled_140_90'),),
    'bp_controlled_130_80': (('heart360_dm_bp_control', 'bp_controlled_130_80'),),
}


def _parse_iso_date(raw: str) -> date | None:
    try:
        return datetime.fromisoformat(raw.replace('Z', '+00:00')).date()
    except Exception:
        return None


def _month_start(value: date) -> date:
    return value.replace(day=1)


def _is_percent_code(code: str) -> bool:
    return (
        code.endswith('_percent')
        or code.endswith('_pct')
        or code.endswith('_rate')
        or 'percentage' in code
    )


def _count_value(raw_value) -> int | None:
    try:
        value = int(raw_value)
    except Exception:
        return None
    if value < 0:
        return None
    return value


def _extract_source_key(submission: dict, fallback: str) -> str:
    candidates = [
        submission.get('source_key'),
        ((submission.get('reporter') or {}).get('identifier') or {}).get('value'),
        ((submission.get('reporter') or {}).get('display')),
        fallback,
    ]
    for value in candidates:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return fallback


def _extract_submission_id(submission: dict, fallback: str) -> str:
    identifier = submission.get('identifier') or {}
    if isinstance(identifier, dict):
        value = identifier.get('value')
        if isinstance(value, str) and value.strip():
            return value.strip()
    return fallback


def validate_aggregate_json(json_path: str) -> tuple[bool, str]:
    try:
        with open(json_path, 'r', encoding='utf-8') as handle:
            payload = json.load(handle)
    except Exception as exc:
        return False, f'could not parse JSON payload: {exc}'

    if not isinstance(payload, dict):
        return False, 'payload root must be a JSON object'
    if payload.get('resourceType') != 'AggregateIndicatorSubmission':
        return False, "resourceType must be 'AggregateIndicatorSubmission'"
    entries = payload.get('entries')
    if not isinstance(entries, list) or not entries:
        return False, 'entries must be a non-empty array'
    return True, ''


def _resolve_org_unit_id(conn, source_key: str, org_unit_payload: dict) -> tuple[int | None, str | None]:
    org_unit_id = org_unit_payload.get('id')
    code = org_unit_payload.get('code')
    display = org_unit_payload.get('display')

    if org_unit_id is not None:
        try:
            org_unit_id = int(org_unit_id)
        except Exception:
            return None, 'orgUnit.id must be an integer when provided'
        with conn.cursor() as cur:
            cur.execute('SELECT 1 FROM heart360tk_schema.org_units WHERE id = %s', (org_unit_id,))
            if cur.fetchone():
                _remember_code(conn, source_key, code, org_unit_id, display)
                return org_unit_id, None

    if isinstance(code, str) and code.strip():
        with conn.cursor() as cur:
            cur.execute(
                '''
                SELECT central_org_unit_id
                FROM heart360tk_reporting.external_org_unit_mapping
                WHERE source_key = %s AND external_code = %s
                ''',
                (source_key, code.strip()),
            )
            row = cur.fetchone()
            if row:
                return int(row[0]), None

    if isinstance(display, str) and display.strip():
        level = org_unit_payload.get('level')
        with conn.cursor() as cur:
            if level is not None:
                try:
                    level = int(level)
                except Exception:
                    return None, 'orgUnit.level must be an integer when provided'
                cur.execute(
                    '''
                    SELECT id FROM heart360tk_schema.org_units
                    WHERE name = %s AND level = %s
                    ORDER BY id
                    ''',
                    (display.strip(), level),
                )
            else:
                cur.execute(
                    '''
                    SELECT id FROM heart360tk_schema.org_units
                    WHERE name = %s
                    ORDER BY id
                    ''',
                    (display.strip(),),
                )
            rows = cur.fetchall()
            if len(rows) == 1:
                resolved_id = int(rows[0][0])
                _remember_code(conn, source_key, code, resolved_id, display)
                return resolved_id, None
            if len(rows) > 1:
                return None, 'orgUnit.display matched multiple central org units; provide orgUnit.id or orgUnit.code mapping'

    return None, 'could not resolve org unit by id/code/display'


def _remember_code(conn, source_key: str, code, org_unit_id: int, display) -> None:
    if not isinstance(code, str) or not code.strip():
        return
    with conn.cursor() as cur:
        cur.execute(
            '''
            INSERT INTO heart360tk_reporting.external_org_unit_mapping
                (source_key, external_code, central_org_unit_id, external_display_name, last_seen_at)
            VALUES (%s, %s, %s, %s, NOW())
            ON CONFLICT (source_key, external_code)
            DO UPDATE SET
                central_org_unit_id = EXCLUDED.central_org_unit_id,
                external_display_name = EXCLUDED.external_display_name,
                last_seen_at = NOW()
            ''',
            (
                source_key,
                code.strip(),
                org_unit_id,
                display.strip() if isinstance(display, str) and display.strip() else None,
            ),
        )


def _log_skip(conn, source_key, submission_id, period_start, entry_index, reason, org_unit_payload, entry_payload):
    with conn.cursor() as cur:
        cur.execute(
            '''
            INSERT INTO heart360tk_reporting.external_aggregate_rejection_log
                (source_key, submission_id, period_start, entry_index, reason,
                 org_unit_payload, entry_payload, rejected_at)
            VALUES (%s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, NOW())
            ''',
            (
                source_key,
                submission_id,
                period_start,
                entry_index,
                reason,
                json.dumps(org_unit_payload or {}),
                json.dumps(entry_payload),
            ),
        )


def _entry_month(entry: dict, default_start: date | None) -> tuple[date | None, str | None]:
    period = entry.get('period') if isinstance(entry.get('period'), dict) else None
    if period:
        start = _parse_iso_date(str(period.get('start', '')))
        if start is None:
            return None, 'entry period.start must be an ISO date'
        return _month_start(start), None
    if default_start is None:
        return None, 'entry is missing period and the file has no period'
    return default_start, None


def _add_count(cells: dict, month: date, org_unit_id: int, table: str, column: str, value: int) -> None:
    key = (month, org_unit_id, table)
    bucket = cells.setdefault(key, {})
    bucket[column] = bucket.get(column, 0) + value


def _upsert(conn, month: date, org_unit_id: int, table: str, columns: dict[str, int]) -> None:
    if not columns:
        return
    column_names = list(columns)
    query = sql.SQL(
        'INSERT INTO heart360tk_reporting.{table} ({cols}) VALUES ({values}) '
        'ON CONFLICT (org_unit_id, ref_month) DO UPDATE SET {assignments}'
    ).format(
        table=sql.Identifier(table),
        cols=sql.SQL(', ').join(sql.Identifier(name) for name in ('ref_month', 'org_unit_id', *column_names)),
        values=sql.SQL(', ').join(sql.Placeholder() for _ in range(2 + len(column_names))),
        assignments=sql.SQL(', ').join(
            sql.SQL('{col} = EXCLUDED.{col}').format(col=sql.Identifier(name))
            for name in column_names
        ),
    )
    with conn.cursor() as cur:
        cur.execute(query, (month, org_unit_id, *[columns[name] for name in column_names]))


def _anchor_registration_row(conn, month: date, org_unit_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            '''
            INSERT INTO heart360tk_reporting.heart360_patients_registered (ref_month, org_unit_id)
            VALUES (%s, %s)
            ON CONFLICT (org_unit_id, ref_month) DO NOTHING
            ''',
            (month, org_unit_id),
        )


def import_aggregate_json_file(conn, json_path: str) -> str:
    with open(json_path, 'r', encoding='utf-8') as handle:
        submission = json.load(handle)

    file_fallback = os.path.splitext(os.path.basename(json_path))[0]
    source_key = _extract_source_key(submission, file_fallback)
    submission_id = _extract_submission_id(submission, file_fallback)

    file_period = submission.get('period') if isinstance(submission.get('period'), dict) else {}
    default_start = _parse_iso_date(str(file_period.get('start', ''))) if file_period else None
    default_end = _parse_iso_date(str(file_period.get('end', ''))) if file_period else None
    if default_start is not None:
        default_start = _month_start(default_start)

    with conn.cursor() as cur:
        cur.execute(
            '''
            DELETE FROM heart360tk_reporting.external_aggregate_rejection_log
            WHERE source_key = %s AND submission_id = %s
            ''',
            (source_key, submission_id),
        )

    accepted = 0
    rejected = 0
    cells: dict[tuple[date, int, str], dict[str, int]] = {}
    period_end = default_end

    for idx, entry in enumerate(submission.get('entries') or []):
        if not isinstance(entry, dict):
            rejected += 1
            _log_skip(conn, source_key, submission_id, default_start or date.today(), idx,
                      'entry must be an object', None, {'entry': entry})
            continue

        month, month_error = _entry_month(entry, default_start)
        if month is None:
            rejected += 1
            _log_skip(conn, source_key, submission_id, default_start or date.today(), idx,
                      month_error, entry.get('orgUnit'), entry)
            continue

        org_unit_payload = entry.get('orgUnit') or {}
        if not isinstance(org_unit_payload, dict):
            rejected += 1
            _log_skip(conn, source_key, submission_id, month, idx, 'orgUnit must be an object', None, entry)
            continue

        org_unit_id, org_reason = _resolve_org_unit_id(conn, source_key, org_unit_payload)
        if org_unit_id is None:
            rejected += 1
            _log_skip(conn, source_key, submission_id, month, idx,
                      f'org unit resolution failed: {org_reason}', org_unit_payload, entry)
            continue

        indicators = entry.get('indicators') or []
        if not isinstance(indicators, list):
            rejected += 1
            _log_skip(conn, source_key, submission_id, month, idx, 'indicators must be an array', org_unit_payload, entry)
            continue

        stored = 0
        for indicator in indicators:
            if not isinstance(indicator, dict):
                _log_skip(conn, source_key, submission_id, month, idx,
                          'ignored: indicator entries must be objects', org_unit_payload, entry)
                continue
            code = str(indicator.get('code', '')).strip().lower()
            if _is_percent_code(code):
                _log_skip(conn, source_key, submission_id, month, idx,
                          f'ignored: {code} is a percentage; send the count and the dashboard calculates the percent',
                          org_unit_payload, entry)
                continue
            targets = INDICATORS.get(code)
            if targets is None:
                _log_skip(conn, source_key, submission_id, month, idx,
                          f'ignored: unknown indicator code {code}', org_unit_payload, entry)
                continue
            value = _count_value(indicator.get('value'))
            if value is None:
                _log_skip(conn, source_key, submission_id, month, idx,
                          f'ignored: {code} must be a non-negative integer', org_unit_payload, entry)
                continue
            for table, column in targets:
                _add_count(cells, month, org_unit_id, table, column, value)
            stored += 1

        if stored == 0:
            rejected += 1
            _log_skip(conn, source_key, submission_id, month, idx,
                      'entry has no supported indicator counts', org_unit_payload, entry)
            continue
        accepted += 1

    for (month, org_unit_id, table), columns in cells.items():
        _upsert(conn, month, org_unit_id, table, columns)
        if table == 'heart360_patients_under_care':
            _anchor_registration_row(conn, month, org_unit_id)

    with conn.cursor() as cur:
        cur.execute(
            '''
            INSERT INTO heart360tk_reporting.external_aggregate_submission_log
                (source_key, submission_id, period_start, period_end,
                 accepted_entries, rejected_entries, ingested_at, raw_filename)
            VALUES (%s, %s, %s, %s, %s, %s, NOW(), %s)
            ON CONFLICT (source_key, submission_id, period_start) DO UPDATE SET
                period_end = EXCLUDED.period_end,
                accepted_entries = EXCLUDED.accepted_entries,
                rejected_entries = EXCLUDED.rejected_entries,
                ingested_at = NOW(),
                raw_filename = EXCLUDED.raw_filename
            ''',
            (
                source_key,
                submission_id,
                default_start or (min(cells)[0] if cells else date.today().replace(day=1)),
                period_end,
                accepted,
                rejected,
                os.path.basename(json_path),
            ),
        )

    log.info(
        '  Imported JSON submission %s (source_key=%s, accepted_entries=%d, rejected_entries=%d)',
        submission_id, source_key, accepted, rejected,
    )
    return source_key
