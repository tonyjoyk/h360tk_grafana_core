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
from datetime import datetime, timezone

import paramiko
import psycopg2
from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.cron import CronTrigger

from import_versions import get_importer
from import_versions.aggregate_json import import_aggregate_json_file, validate_aggregate_json
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
