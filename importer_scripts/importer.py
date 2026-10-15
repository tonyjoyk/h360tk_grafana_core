import csv
import io
import json
import logging
import os
import shutil
import stat
import sys
import tempfile
import time
import zipfile
from datetime import date, datetime, timezone

import paramiko
import psycopg2
from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.cron import CronTrigger

from import_versions import get_importer
from import_versions.base import BaseImportVersion

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
)
log = logging.getLogger(__name__)


def _env_str(name: str, default: str = '') -> str:
    raw = os.getenv(name)
    if raw is None:
        return default
    value = raw.strip()
    return value if value else default


def _env_int(name: str, default: int) -> int:
    raw = _env_str(name, str(default))
    try:
        return int(raw)
    except ValueError:
        return default


IMPORT_CRON = _env_str('IMPORT_CRON', '0 * * * *')
IMPORT_AGGREGATE_DATA = _env_str('IMPORT_AGGREGATE_DATA', 'false').lower() == 'true'
IMPORT_PROTOCOL = _env_str('IMPORT_PROTOCOL', 'sftp').lower()
IMPORT_FOLDER_PATH = _env_str('IMPORT_FOLDER_PATH', '/export')

SFTP_HOST = _env_str('SFTP_HOST')
SFTP_PORT = _env_int('SFTP_PORT', 22)
SFTP_USER = _env_str('SFTP_USER')
SFTP_PASSWORD = _env_str('SFTP_PASSWORD')
SFTP_TIMEOUT_SECONDS = _env_int('SFTP_TIMEOUT', 60)

DB_CONNECTION_PARAMS = {
    'host': os.getenv('POSTGRES_HOST', 'postgres'),
    'database': os.getenv('POSTGRES_DB', 'heart360tk_database'),
    'user': os.getenv('POSTGRES_USER', 'heart360tk'),
    'password': os.getenv('POSTGRES_PASSWORD', ''),
}

SUPPORTED_INDICATOR_CODES = {
    'bp_controlled',
    'bp_uncontrolled',
    'missed_visit',
}


def validate_config():
    if IMPORT_PROTOCOL not in {'sftp', 'file'}:
        log.error("Unsupported IMPORT_PROTOCOL '%s'. Use 'sftp' or 'file'.", IMPORT_PROTOCOL)
        sys.exit(1)

    required = {
        'POSTGRES_PASSWORD': DB_CONNECTION_PARAMS['password'],
    }

    if IMPORT_PROTOCOL == 'sftp':
        required.update({
            'SFTP_HOST': SFTP_HOST,
            'SFTP_USER': SFTP_USER,
            'SFTP_PASSWORD': SFTP_PASSWORD,
        })

    missing = [k for k, v in required.items() if not v]
    if missing:
        log.error('Missing required environment variables: %s', ', '.join(missing))
        sys.exit(1)

    log.info('Config validated OK.')
    log.info('  IMPORT_CRON            : %s', IMPORT_CRON)
    log.info('  IMPORT_AGGREGATE_DATA : %s', IMPORT_AGGREGATE_DATA)
    log.info('  IMPORT_PROTOCOL        : %s', IMPORT_PROTOCOL)
    log.info('  IMPORT_FOLDER_PATH     : %s', IMPORT_FOLDER_PATH)
    if IMPORT_PROTOCOL == 'sftp':
        log.info('  SFTP_HOST              : %s', SFTP_HOST)
        log.info('  SFTP_PORT              : %d', SFTP_PORT)
        log.info('  SFTP_USER              : %s', SFTP_USER)
        log.info('  SFTP_TIMEOUT           : %ds', SFTP_TIMEOUT_SECONDS)


def is_import_enabled():
    if not IMPORT_AGGREGATE_DATA:
        log.info('IMPORT_AGGREGATE_DATA=false — import is disabled. Skipping.')
        return False
    return True


def log_import_run(
    source_key,
    started_at,
    status,
    duration_seconds=None,
    error_message=None,
):
    try:
        with psycopg2.connect(**DB_CONNECTION_PARAMS) as conn:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(
                    '''
                    INSERT INTO heart360tk_reporting.import_run_log
                        (source_key, started_at, finished_at, status,
                         duration_seconds, error_message)
                    VALUES (%s, %s, NOW(), %s, %s, %s)
                    ''',
                    (
                        source_key,
                        datetime.fromtimestamp(started_at, tz=timezone.utc),
                        status,
                        duration_seconds,
                        error_message,
                    ),
                )
        log.info(
            '  Import run logged to DB — source_key=%s, status=%s, duration=%.2fs',
            source_key,
            status,
            duration_seconds or 0,
        )
    except Exception as e:
        log.warning('Could not write import run log to DB (non-fatal): %s', e)


def _open_sftp_client():
    log.warning(
        'SFTP host key verification is disabled — '
        'set a known_hosts file in production for security.'
    )

    transport = paramiko.Transport((SFTP_HOST, SFTP_PORT))
    transport.banner_timeout = SFTP_TIMEOUT_SECONDS
    transport.auth_timeout = SFTP_TIMEOUT_SECONDS
    transport.connect(username=SFTP_USER, password=SFTP_PASSWORD)

    sftp = paramiko.SFTPClient.from_transport(transport)
    sftp.get_channel().settimeout(SFTP_TIMEOUT_SECONDS)
    return transport, sftp


def _is_import_zip(filename: str) -> bool:
    return (
        filename.lower().endswith('.zip')
        and not filename.startswith('.')
        and not filename.endswith('.tmp')
    )


def _is_import_json(filename: str) -> bool:
    return (
        filename.lower().endswith('.json')
        and not filename.startswith('.')
        and not filename.endswith('.tmp')
    )


def _is_import_payload(filename: str) -> bool:
    return _is_import_zip(filename) or _is_import_json(filename)


def fetch_sftp_payload_names() -> list[str]:
    remote_dir = IMPORT_FOLDER_PATH.rstrip('/')
    transport = None
    sftp = None

    try:
        transport, sftp = _open_sftp_client()
        entries = sftp.listdir_attr(remote_dir)
        names = sorted(
            entry.filename
            for entry in entries
            if not stat.S_ISDIR(entry.st_mode) and _is_import_payload(entry.filename)
        )
        log.info(
            'Found %d import file(s) in %s@%s:%s',
            len(names),
            SFTP_USER,
            SFTP_HOST,
            remote_dir,
        )
        for name in names:
            log.info('  %s', name)
        return names

    finally:
        if sftp is not None:
            try:
                sftp.close()
            except Exception:
                pass
        if transport is not None:
            transport.close()


def fetch_file_payload_names() -> list[str]:
    if not os.path.isdir(IMPORT_FOLDER_PATH):
        raise FileNotFoundError(
            f"IMPORT_FOLDER_PATH does not exist or is not a directory: {IMPORT_FOLDER_PATH}"
        )
    names = sorted(
        name for name in os.listdir(IMPORT_FOLDER_PATH)
        if os.path.isfile(os.path.join(IMPORT_FOLDER_PATH, name)) and _is_import_payload(name)
    )
    log.info('Found %d import file(s) in local path %s', len(names), IMPORT_FOLDER_PATH)
    for name in names:
        log.info('  %s', name)
    return names


def download_sftp_payload(name: str, local_path: str) -> None:
    remote_dir = IMPORT_FOLDER_PATH.rstrip('/')
    remote_path = f'{remote_dir}/{name}'
    transport = None
    sftp = None

    try:
        transport, sftp = _open_sftp_client()
        sftp.get(remote_path, local_path)
        log.info('  Downloaded %s', name)
    finally:
        if sftp is not None:
            try:
                sftp.close()
            except Exception:
                pass
        if transport is not None:
            transport.close()


_SFTP_RETRY_MAX_ATTEMPTS = 3
_SFTP_RETRY_BACKOFF_SECONDS = [0, 5, 10]


def download_sftp_payload_with_retry(name: str, local_path: str) -> None:
    last_exc: Exception | None = None
    for attempt in range(1, _SFTP_RETRY_MAX_ATTEMPTS + 1):
        delay = _SFTP_RETRY_BACKOFF_SECONDS[attempt - 1]
        if delay:
            log.warning(
                '  Retrying download of %s (attempt %d/%d) in %ds...',
                name, attempt, _SFTP_RETRY_MAX_ATTEMPTS, delay,
            )
            time.sleep(delay)
        try:
            download_sftp_payload(name, local_path)
            return
        except Exception as e:
            last_exc = e
            log.warning(
                '  Download attempt %d/%d failed for %s: %s',
                attempt, _SFTP_RETRY_MAX_ATTEMPTS, name, e,
            )
    assert last_exc is not None
    raise last_exc


def copy_file_payload(name: str, local_path: str) -> None:
    src_path = os.path.join(IMPORT_FOLDER_PATH, name)
    shutil.copy2(src_path, local_path)
    log.info('  Copied %s from local import path', name)


def download_payload_with_retry(name: str, local_path: str) -> None:
    if IMPORT_PROTOCOL == 'sftp':
        download_sftp_payload_with_retry(name, local_path)
        return
    if IMPORT_PROTOCOL == 'file':
        copy_file_payload(name, local_path)
        return
    raise ValueError(f'Unsupported IMPORT_PROTOCOL: {IMPORT_PROTOCOL}')


def load_metadata(extract_dir: str) -> dict:
    metadata_path = os.path.join(extract_dir, 'metadata.json')
    if not os.path.isfile(metadata_path):
        raise FileNotFoundError('metadata.json not found in zip')

    with open(metadata_path, 'r', encoding='utf-8') as metadata_file:
        metadata = json.load(metadata_file)

    source_key = metadata.get('source_key', '').strip()
    if not source_key:
        raise ValueError('metadata.json is missing source_key')

    version = metadata.get('import_export_version')
    if version is None:
        raise ValueError('metadata.json is missing import_export_version')

    return metadata


def read_zip_source_key(zip_path: str) -> str:
    with zipfile.ZipFile(zip_path, 'r') as zf:
        with zf.open('metadata.json') as f:
            metadata = json.load(f)
    source_key = metadata.get('source_key', '').strip()
    if not source_key:
        raise ValueError('metadata.json is missing source_key')
    return source_key


def validate_zip(zip_path: str, zip_name: str) -> tuple[bool, str]:
    """Return (True, '') when the ZIP is safe to import, (False, reason) otherwise.

    A ZIP is considered valid when:
      1. It is a well-formed ZIP archive.
      2. metadata.json is present with a non-empty source_key and a recognised
         import_export_version.
      3. At least one CSV file inside the archive contains at least one data
         row (beyond the header line).
    """
    if not zipfile.is_zipfile(zip_path):
        return False, 'not a valid ZIP archive'

    with zipfile.ZipFile(zip_path, 'r') as zf:
        names_in_zip = zf.namelist()

        if 'metadata.json' not in names_in_zip:
            return False, 'metadata.json is missing'

        try:
            with zf.open('metadata.json') as f:
                metadata = json.load(f)
        except Exception as exc:
            return False, f'metadata.json could not be parsed: {exc}'

        source_key = metadata.get('source_key', '').strip()
        if not source_key:
            return False, 'metadata.json is missing source_key'

        if metadata.get('import_export_version') is None:
            return False, 'metadata.json is missing import_export_version'

        csv_files = [n for n in names_in_zip if n.lower().endswith('.csv')]
        has_data = False
        for csv_name in csv_files:
            with zf.open(csv_name) as raw:
                reader = csv.reader(io.TextIOWrapper(raw, encoding='utf-8'))
                try:
                    next(reader)  # header row
                    next(reader)  # first data row — proves file is non-empty
                    has_data = True
                    break
                except StopIteration:
                    continue

        if not has_data:
            return False, 'no CSV files contain any data rows'

    return True, ''


def import_zip_file(conn, zip_path: str, source_key: str) -> None:
    extract_dir = tempfile.mkdtemp(prefix='h360tk_import_')
    try:
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(extract_dir)

        metadata = load_metadata(extract_dir)
        version = int(metadata['import_export_version'])

        importer = get_importer(version)
        importer.import_zip(conn, extract_dir, metadata)

    finally:
        shutil.rmtree(extract_dir, ignore_errors=True)


def _parse_iso_date(raw: str) -> date | None:
    try:
        return datetime.fromisoformat(raw.replace('Z', '+00:00')).date()
    except Exception:
        return None


def _extract_source_key(submission: dict, fallback: str) -> str:
    candidates = [
        submission.get('source_key'),
        ((submission.get('reporter') or {}).get('identifier') or {}).get('value'),
        ((submission.get('reporter') or {}).get('display')),
        fallback,
    ]
    for value in candidates:
        if not isinstance(value, str):
            continue
        cleaned = value.strip()
        if cleaned:
            return cleaned
    return fallback


def _extract_submission_id(submission: dict, fallback: str) -> str:
    identifier = submission.get('identifier') or {}
    if isinstance(identifier, dict):
        value = identifier.get('value')
        if isinstance(value, str) and value.strip():
            return value.strip()
    return fallback


def _validate_indicator_value(raw_value) -> int | None:
    try:
        value = int(raw_value)
    except Exception:
        return None
    if value < 0:
        return None
    return value


def validate_aggregate_json(json_path: str) -> tuple[bool, str]:
    try:
        with open(json_path, 'r', encoding='utf-8') as f:
            payload = json.load(f)
    except Exception as exc:
        return False, f'could not parse JSON payload: {exc}'

    if not isinstance(payload, dict):
        return False, 'payload root must be a JSON object'

    if payload.get('resourceType') != 'AggregateIndicatorSubmission':
        return False, "resourceType must be 'AggregateIndicatorSubmission'"

    period = payload.get('period') or {}
    if not isinstance(period, dict):
        return False, 'period must be an object'

    start_raw = period.get('start')
    end_raw = period.get('end')
    if not isinstance(start_raw, str) or not _parse_iso_date(start_raw):
        return False, 'period.start must be an ISO date string'
    if not isinstance(end_raw, str) or not _parse_iso_date(end_raw):
        return False, 'period.end must be an ISO date string'

    entries = payload.get('entries')
    if not isinstance(entries, list) or not entries:
        return False, 'entries must be a non-empty array'

    return True, ''


def _resolve_org_unit_id(conn, source_key: str, org_unit_payload: dict) -> tuple[int | None, str | None]:
    org_unit_id = org_unit_payload.get('id')
    if org_unit_id is not None:
        try:
            org_unit_id = int(org_unit_id)
        except Exception:
            return None, 'orgUnit.id must be an integer when provided'

        with conn.cursor() as cur:
            cur.execute(
                'SELECT 1 FROM heart360tk_schema.org_units WHERE id = %s',
                (org_unit_id,),
            )
            if cur.fetchone():
                code = org_unit_payload.get('code')
                if isinstance(code, str) and code.strip():
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
                            (org_unit_payload.get('display') or '').strip() or None,
                        ),
                    )
                return org_unit_id, None

    code = org_unit_payload.get('code')
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

    display = org_unit_payload.get('display')
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
                    SELECT id
                    FROM heart360tk_schema.org_units
                    WHERE name = %s AND level = %s
                    ORDER BY id
                    ''',
                    (display.strip(), level),
                )
            else:
                cur.execute(
                    '''
                    SELECT id
                    FROM heart360tk_schema.org_units
                    WHERE name = %s
                    ORDER BY id
                    ''',
                    (display.strip(),),
                )
            rows = cur.fetchall()
            if len(rows) == 1:
                resolved_id = int(rows[0][0])
                if isinstance(code, str) and code.strip():
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
                            resolved_id,
                            display.strip(),
                        ),
                    )
                return resolved_id, None
            if len(rows) > 1:
                return None, 'orgUnit.display matched multiple central org units; provide orgUnit.id or orgUnit.code mapping'

    return None, 'could not resolve org unit by id/code/display'


def _log_json_rejection(
    conn,
    source_key: str,
    submission_id: str,
    period_start: date,
    entry_index: int,
    reason: str,
    org_unit_payload: dict | None,
    entry_payload: dict,
) -> None:
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


def import_aggregate_json_file(conn, json_path: str) -> str:
    with open(json_path, 'r', encoding='utf-8') as f:
        submission = json.load(f)

    file_fallback = os.path.splitext(os.path.basename(json_path))[0]
    source_key = _extract_source_key(submission, file_fallback)
    submission_id = _extract_submission_id(submission, file_fallback)

    period = submission.get('period') or {}
    period_start = _parse_iso_date(str(period.get('start', '')))
    period_end = _parse_iso_date(str(period.get('end', '')))
    if period_start is None or period_end is None:
        raise ValueError('JSON submission period.start/period.end must be valid ISO dates')

    entries = submission.get('entries') or []
    accepted = 0
    rejected = 0
    totals: dict[tuple[date, int], dict[str, int]] = {}

    with conn.cursor() as cur:
        cur.execute(
            '''
            DELETE FROM heart360tk_reporting.external_aggregate_rejection_log
            WHERE source_key = %s
              AND submission_id = %s
              AND period_start = %s
            ''',
            (source_key, submission_id, period_start),
        )

    for idx, entry in enumerate(entries):
        if not isinstance(entry, dict):
            rejected += 1
            _log_json_rejection(
                conn,
                source_key,
                submission_id,
                period_start,
                idx,
                'entry must be an object',
                None,
                {'entry': entry},
            )
            continue

        org_unit_payload = entry.get('orgUnit') or {}
        if not isinstance(org_unit_payload, dict):
            rejected += 1
            _log_json_rejection(
                conn,
                source_key,
                submission_id,
                period_start,
                idx,
                'orgUnit must be an object',
                None,
                entry,
            )
            continue

        org_unit_id, org_reason = _resolve_org_unit_id(conn, source_key, org_unit_payload)
        if org_unit_id is None:
            rejected += 1
            _log_json_rejection(
                conn,
                source_key,
                submission_id,
                period_start,
                idx,
                f'org unit resolution failed: {org_reason}',
                org_unit_payload,
                entry,
            )
            continue

        indicators = entry.get('indicators') or []
        if not isinstance(indicators, list):
            rejected += 1
            _log_json_rejection(
                conn,
                source_key,
                submission_id,
                period_start,
                idx,
                'indicators must be an array',
                org_unit_payload,
                entry,
            )
            continue

        counts = {'bp_controlled': 0, 'bp_uncontrolled': 0, 'missed_visit': 0}
        invalid_reason = None
        for indicator in indicators:
            if not isinstance(indicator, dict):
                invalid_reason = 'indicator entries must be objects'
                break
            code = str(indicator.get('code', '')).strip().lower()
            if code not in SUPPORTED_INDICATOR_CODES:
                continue
            value = _validate_indicator_value(indicator.get('value'))
            if value is None:
                invalid_reason = f'invalid value for indicator code={code}'
                break
            counts[code] += value

        if invalid_reason:
            rejected += 1
            _log_json_rejection(
                conn,
                source_key,
                submission_id,
                period_start,
                idx,
                invalid_reason,
                org_unit_payload,
                entry,
            )
            continue

        if sum(counts.values()) == 0:
            rejected += 1
            _log_json_rejection(
                conn,
                source_key,
                submission_id,
                period_start,
                idx,
                'entry has no supported indicator values',
                org_unit_payload,
                entry,
            )
            continue

        extensions = entry.get('extensions') or {}
        if not isinstance(extensions, dict):
            extensions = {}

        denominator = _validate_indicator_value(extensions.get('denominator_under_care'))
        if denominator is None:
            denominator = counts['bp_controlled'] + counts['bp_uncontrolled'] + counts['missed_visit']

        newly_registered = _validate_indicator_value(extensions.get('newly_registered'))
        newly_registered = 0 if newly_registered is None else newly_registered
        lost_to_follow_up = _validate_indicator_value(extensions.get('lost_to_follow_up'))
        lost_to_follow_up = 0 if lost_to_follow_up is None else lost_to_follow_up

        key = (period_start, org_unit_id)
        bucket = totals.setdefault(
            key,
            {
                'bp_controlled': 0,
                'bp_uncontrolled': 0,
                'missed_visit': 0,
                'denominator': 0,
                'newly_registered': 0,
                'lost_to_follow_up': 0,
            },
        )
        bucket['bp_controlled'] += counts['bp_controlled']
        bucket['bp_uncontrolled'] += counts['bp_uncontrolled']
        bucket['missed_visit'] += counts['missed_visit']
        bucket['denominator'] += denominator
        bucket['newly_registered'] += newly_registered
        bucket['lost_to_follow_up'] += lost_to_follow_up
        accepted += 1

    with conn.cursor() as cur:
        for (ref_month, org_unit_id), metrics in totals.items():
            denominator = max(
                metrics['denominator'],
                metrics['bp_controlled'] + metrics['bp_uncontrolled'] + metrics['missed_visit'],
            )
            visit_no_bp = max(
                denominator - (
                    metrics['bp_controlled']
                    + metrics['bp_uncontrolled']
                    + metrics['missed_visit']
                ),
                0,
            )
            total_patients = denominator + metrics['newly_registered'] + metrics['lost_to_follow_up']
            cur.execute(
                '''
                INSERT INTO heart360tk_reporting.heart360_patients_category
                    (ref_month, org_unit_id, total_number_of_patients, nb_patients_under_care,
                     nb_patients_newly_registered,
                     nb_patients_under_care_registered_before_the_past_3_months,
                     nb_patients_lost_to_follow_up, nb_patients_no_visit,
                     nb_patients_under_care_registered_before_3m_incl_visits,
                     nb_patients_uncontrolled, nb_patients_controlled, nb_patients_visit_no_bp)
                VALUES
                    (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (org_unit_id, ref_month) DO UPDATE SET
                    total_number_of_patients = EXCLUDED.total_number_of_patients,
                    nb_patients_under_care = EXCLUDED.nb_patients_under_care,
                    nb_patients_newly_registered = EXCLUDED.nb_patients_newly_registered,
                    nb_patients_under_care_registered_before_the_past_3_months =
                        EXCLUDED.nb_patients_under_care_registered_before_the_past_3_months,
                    nb_patients_lost_to_follow_up = EXCLUDED.nb_patients_lost_to_follow_up,
                    nb_patients_no_visit = EXCLUDED.nb_patients_no_visit,
                    nb_patients_under_care_registered_before_3m_incl_visits =
                        EXCLUDED.nb_patients_under_care_registered_before_3m_incl_visits,
                    nb_patients_uncontrolled = EXCLUDED.nb_patients_uncontrolled,
                    nb_patients_controlled = EXCLUDED.nb_patients_controlled,
                    nb_patients_visit_no_bp = EXCLUDED.nb_patients_visit_no_bp
                ''',
                (
                    ref_month,
                    org_unit_id,
                    total_patients,
                    denominator,
                    metrics['newly_registered'],
                    denominator,
                    metrics['lost_to_follow_up'],
                    metrics['missed_visit'],
                    denominator,
                    metrics['bp_uncontrolled'],
                    metrics['bp_controlled'],
                    visit_no_bp,
                ),
            )

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
                period_start,
                period_end,
                accepted,
                rejected,
                os.path.basename(json_path),
            ),
        )

    log.info(
        '  Imported JSON submission %s (source_key=%s, accepted_entries=%d, rejected_entries=%d)',
        submission_id,
        source_key,
        accepted,
        rejected,
    )
    return source_key


def run_import():
    if not is_import_enabled():
        return

    log.info('=== Import job started ===')
    job_start = time.time()
    work_dir = tempfile.mkdtemp(prefix='h360tk_import_work_')
    conn = None

    try:
        if IMPORT_PROTOCOL == 'sftp':
            payload_names = fetch_sftp_payload_names()
            location_label = f'SFTP {SFTP_USER}@{SFTP_HOST}:{IMPORT_FOLDER_PATH}'
        elif IMPORT_PROTOCOL == 'file':
            payload_names = fetch_file_payload_names()
            location_label = f'local folder {IMPORT_FOLDER_PATH}'
        else:
            raise ValueError(f'Unsupported IMPORT_PROTOCOL: {IMPORT_PROTOCOL}')

        if not payload_names:
            log.info(
                'No import files found in %s — nothing to import.',
                location_label,
            )
            return

        log.info('Phase 1 — Downloading %d import file(s)...', len(payload_names))
        downloaded: list[tuple[str, str]] = []
        for payload_name in payload_names:
            local_path = os.path.join(work_dir, payload_name)
            try:
                download_payload_with_retry(payload_name, local_path)
                downloaded.append((payload_name, local_path))
            except Exception as e:
                log.error(
                    'Failed to download %s after %d attempts — skipping: %s',
                    payload_name, _SFTP_RETRY_MAX_ATTEMPTS, e,
                )

        if not downloaded:
            log.error('All downloads failed — reporting tables will NOT be truncated.')
            return

        log.info(
            'Phase 1 complete — %d/%d import file(s) downloaded successfully.',
            len(downloaded),
            len(payload_names),
        )

        log.info('Phase 2 — Validating %d downloaded import file(s)...', len(downloaded))
        valid_payloads: list[tuple[str, str]] = []
        for payload_name, local_path in downloaded:
            if _is_import_zip(payload_name):
                ok, reason = validate_zip(local_path, payload_name)
            elif _is_import_json(payload_name):
                ok, reason = validate_aggregate_json(local_path)
            else:
                ok, reason = False, 'unsupported file type'
            if ok:
                log.info('  [VALID]   %s', payload_name)
                valid_payloads.append((payload_name, local_path))
            else:
                log.warning('  [SKIPPED] %s — %s', payload_name, reason)

        if not valid_payloads:
            log.error(
                'No import files passed validation — '
                'reporting tables will NOT be truncated to avoid data loss.'
            )
            return

        log.info(
            'Phase 2 complete — %d/%d import file(s) passed validation.',  # noqa: E501
            len(valid_payloads),
            len(downloaded),
        )

        conn = psycopg2.connect(**DB_CONNECTION_PARAMS)
        conn.autocommit = False

        log.info(
            'Phase 3 — Truncating reporting tables and importing %d file(s)...',
            len(valid_payloads),
        )
        BaseImportVersion.truncate_reporting_tables(conn)
        conn.commit()

        imported_count = 0
        for payload_name, local_path in valid_payloads:
            payload_start = time.time()
            source_key = None

            try:
                if _is_import_zip(payload_name):
                    source_key = read_zip_source_key(local_path)
                    import_zip_file(conn, local_path, source_key)
                elif _is_import_json(payload_name):
                    source_key = import_aggregate_json_file(conn, local_path)
                else:
                    raise ValueError(f'Unsupported validated import file: {payload_name}')
                conn.commit()

                duration = round(time.time() - payload_start, 2)
                log_import_run(
                    source_key=source_key,
                    started_at=payload_start,
                    status='success',
                    duration_seconds=duration,
                )
                imported_count += 1
                log.info(
                    '  Imported %s (source_key=%s) in %.2fs',
                    payload_name,
                    source_key,
                    duration,
                )

            except Exception as e:
                conn.rollback()
                duration = round(time.time() - payload_start, 2)
                log.error(
                    'Failed to import %s: %s',
                    payload_name,
                    e,
                    exc_info=True,
                )
                log_import_run(
                    source_key=source_key or os.path.splitext(payload_name)[0],
                    started_at=payload_start,
                    status='failed',
                    duration_seconds=duration,
                    error_message=str(e),
                )

        if imported_count == 0:
            log.error('No zip files were imported successfully.')
        else:
            duration = round(time.time() - job_start, 2)
            log.info(
                '=== Import job complete — %d/%d file(s) imported in %.2fs ===',
                imported_count,
                len(valid_payloads),
                duration,
            )

    except Exception as e:
        if conn is not None:
            conn.rollback()
        log.error('Import job failed: %s', e, exc_info=True)

    finally:
        if conn is not None:
            conn.close()
        shutil.rmtree(work_dir, ignore_errors=True)


def start_scheduler():
    try:
        trigger = CronTrigger.from_crontab(IMPORT_CRON)
    except Exception as e:
        log.error("Invalid IMPORT_CRON expression '%s': %s", IMPORT_CRON, e)
        sys.exit(1)

    scheduler = BlockingScheduler()
    scheduler.add_job(run_import, trigger, id='import_job', name='h360tk import')
    log.info("Scheduler started. Import will run on cron: '%s'", IMPORT_CRON)

    try:
        scheduler.start()
    except KeyboardInterrupt:
        log.info('Importer stopped.')
        scheduler.shutdown()


if __name__ == '__main__':
    validate_config()

    if not is_import_enabled():
        log.info('Importer is disabled (IMPORT_AGGREGATE_DATA=false). Container will exit.')
        sys.exit(0)

    start_scheduler()
