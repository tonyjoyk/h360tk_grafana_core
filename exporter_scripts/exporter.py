import os
import sys
import csv
import json
import logging
import tempfile
import shutil
import time
import zipfile
from datetime import datetime, timezone
import psycopg2
from psycopg2 import sql
from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.cron import CronTrigger
import paramiko
import boto3
from botocore.exceptions import BotoCoreError, ClientError

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
log = logging.getLogger(__name__)

# export_run_log.log_type values (enforced by a CHECK constraint).
LOG_TYPE_LEAF_NODE = 'leaf_node'
LOG_TYPE_INFRASTRUCTURE = 'infrastructure'

# export_run_log.source_key for exporter configuration failures, which are not
# an export attempt by this leaf node.
SOURCE_EXPORTER = 'Exporter'

VERSION_DATA_FORMAT_MAP: dict[str, int] = {
    '0.5.0': 1,
}

def _resolve_import_export_version(source_version: str) -> int:
    if source_version in VERSION_DATA_FORMAT_MAP:
        return VERSION_DATA_FORMAT_MAP[source_version]

    log.warning(
        "SOURCE_VERSION '%s' is not in VERSION_DATA_FORMAT_MAP — "
        "defaulting to import_export_version=1.",
        source_version,
    )
    return 1

SOURCE_KEY       = os.getenv('SOURCE_KEY', '').strip()
SOURCE_VERSION   = os.getenv('SOURCE_VERSION', '').strip()
IMPORT_EXPORT_VERSION = _resolve_import_export_version(SOURCE_VERSION)
EXPORT_CRON      = os.getenv('EXPORT_CRON', '0 * * * *').strip()
UPLOAD_PROTOCOL  = os.getenv('UPLOAD_PROTOCOL', 'file').strip().lower()
UPLOAD_DEST_PATH = os.getenv('UPLOAD_DEST_PATH', '/export').strip()

SFTP_HOST            = os.getenv('SFTP_HOST', '').strip()
SFTP_PORT            = int(os.getenv('SFTP_PORT', '22').strip())
SFTP_USER            = os.getenv('SFTP_USER', '').strip()
SFTP_PASSWORD        = os.getenv('SFTP_PASSWORD', '').strip()
SFTP_DEST_PATH       = os.getenv('SFTP_DEST_PATH', '/upload').strip()
SFTP_TIMEOUT_SECONDS = int(os.getenv('SFTP_TIMEOUT', '60').strip())

S3_BUCKET       = os.getenv('S3_BUCKET', '').strip()
S3_KEY_PREFIX   = os.getenv('S3_KEY_PREFIX', '').strip().strip('/')
S3_REGION       = os.getenv('S3_REGION', '').strip()
S3_ACCESS_KEY   = os.getenv('S3_ACCESS_KEY', '').strip()
S3_SECRET_KEY   = os.getenv('S3_SECRET_KEY', '').strip()
S3_ENDPOINT_URL = os.getenv('S3_ENDPOINT_URL', '').strip() or None  # optional: MinIO / non-AWS S3

DEFAULT_EXPORT_TABLES = [
    'heart360_patients_category',
    'heart360_patients_under_care',
    'heart360_patients_registered',
    'heart360_blood_sugar_controlled',
    'heart360_blood_sugar_severity',
    'heart360_blood_sugar_missed_visits',
    'heart360_dm_bp_control',
    'heart360_dm_patients_under_care',
    'heart360_overdue_start_of_month',
    'heart360_overdue_patients_called',
    'heart360_overdue_returned_to_care',
    'heart360_dm_patients_catagory',
]

_export_tables_env = os.getenv('EXPORT_TABLES', '').strip()
EXPORT_TABLES = (
    [t.strip() for t in _export_tables_env.split(',') if t.strip()]
    if _export_tables_env
    else DEFAULT_EXPORT_TABLES
)

DB_CONNECTION_PARAMS = {
    'host':     os.getenv('POSTGRES_HOST', 'postgres'),
    'database': os.getenv('POSTGRES_DB', 'heart360tk_database'),
    'user':     os.getenv('POSTGRES_USER', 'heart360tk'),
    'password': os.getenv('POSTGRES_PASSWORD', ''),
}

def validate_config():
    # SOURCE_VERSION is baked into the image at build time (ARG → ENV).
    # If it's missing, the image was built without passing the build arg.
    if not SOURCE_VERSION:
        log.warning(
            "SOURCE_VERSION is empty — image was likely built without "
            "--build-arg SOURCE_VERSION=<version>. "
            "Metadata will report this version as-is.",
        )

    required = {
        'SOURCE_KEY':        SOURCE_KEY,
        'POSTGRES_PASSWORD': DB_CONNECTION_PARAMS['password'],
    }

    if UPLOAD_PROTOCOL == 'sftp':
        required.update({
            'SFTP_HOST':     SFTP_HOST,
            'SFTP_USER':     SFTP_USER,
            'SFTP_PASSWORD': SFTP_PASSWORD,
        })

    if UPLOAD_PROTOCOL == 's3':
        required.update({
            'S3_BUCKET':     S3_BUCKET,
            'S3_ACCESS_KEY': S3_ACCESS_KEY,
            'S3_SECRET_KEY': S3_SECRET_KEY,
        })

    missing = [k for k, v in required.items() if not v]
    if missing:
        exit_with_exporter_error(
            f"Missing required environment variables: {', '.join(missing)}"
        )

    log.info("Config validated OK.")
    log.info("  SOURCE_KEY          : %s", SOURCE_KEY)
    log.info("  SOURCE_VERSION      : %s", SOURCE_VERSION)
    log.info("  IMPORT_EXPORT_VERSION : %d", IMPORT_EXPORT_VERSION)
    log.info("  EXPORT_CRON         : %s", EXPORT_CRON)
    log.info("  UPLOAD_PROTOCOL     : %s", UPLOAD_PROTOCOL)
    if UPLOAD_PROTOCOL == 'sftp':
        log.info("  SFTP_HOST           : %s", SFTP_HOST)
        log.info("  SFTP_PORT           : %d", SFTP_PORT)
        log.info("  SFTP_USER           : %s", SFTP_USER)
        log.info("  SFTP_DEST_PATH      : %s", SFTP_DEST_PATH)
        log.info("  SFTP_TIMEOUT        : %ds", SFTP_TIMEOUT_SECONDS)
    elif UPLOAD_PROTOCOL == 's3':
        log.info("  S3_BUCKET           : %s", S3_BUCKET)
        log.info("  S3_KEY_PREFIX       : %s", S3_KEY_PREFIX or '(root)')
        log.info("  S3_REGION           : %s", S3_REGION or '(default)')
        log.info("  S3_ENDPOINT_URL     : %s", S3_ENDPOINT_URL or '(AWS default)')
    else:
        log.info("  UPLOAD_DEST_PATH    : %s", UPLOAD_DEST_PATH)
    log.info("  EXPORT_TABLES       : %s", EXPORT_TABLES)

def generate_csvs(conn):
    tmp_dir = tempfile.mkdtemp(prefix='h360tk_export_')
    log.info("Writing CSVs to temp dir: %s", tmp_dir)

    stats = {
        'facility_count': 0,
        'patient_count':  0,
    }

    cur = conn.cursor()
    try:
        for table_name in EXPORT_TABLES:
            csv_path = os.path.join(tmp_dir, f'{table_name.upper()}.csv')
            try:
                cur.execute(
                    sql.SQL('SELECT * FROM heart360tk_reporting.{}').format(
                        sql.Identifier(table_name)
                    )
                )
                rows = cur.fetchall()
                col_names = [desc[0] for desc in cur.description]

                with open(csv_path, 'w', newline='', encoding='utf-8') as f:
                    writer = csv.writer(f)
                    writer.writerow(col_names)
                    writer.writerows(rows)

                log.info("  Written %s — %d rows", f'{table_name.upper()}.csv', len(rows))

            except Exception as e:
                log.error("  Failed to export table '%s': %s", table_name, e)
                raise

        orgunit_path = os.path.join(tmp_dir, 'orgunit.csv')
        cur.execute(
            'SELECT id, name, level, parent_id FROM heart360tk_schema.org_units ORDER BY level, id'
        )
        rows = cur.fetchall()
        col_names = [desc[0] for desc in cur.description]

        with open(orgunit_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(col_names)
            writer.writerows(rows)

        facility_level = 3
        try:
            cur.execute(
                "SELECT level FROM heart360tk_schema.hierarchy_config WHERE var_name = 'facility'"
            )
            row = cur.fetchone()
            if row:
                facility_level = row[0]
        except Exception as e:
            log.warning("Could not fetch facility level, defaulting to 3: %s", e)

        stats['facility_count'] = sum(1 for r in rows if r[2] == facility_level)
        log.info("  Written orgunit.csv — %d org units (facility count: %d)",
                 len(rows), stats['facility_count'])

        try:
            cur.execute(
                '''
                SELECT COUNT(DISTINCT p.patient_id)
                FROM heart360tk_schema.patients p
                WHERE LOWER(p.patient_status) <> 'dead'
                  AND EXISTS (
                      SELECT 1 FROM heart360tk_schema.patient_diagnoses pd
                      WHERE pd.patient_id = p.patient_id
                        AND pd.diagnosis_code IN ('I10', 'E11')
                  )
                '''
            )
            result = cur.fetchone()
            stats['patient_count'] = int(result[0]) if result and result[0] else 0
        except Exception as e:
            log.warning("Could not fetch patient count: %s", e)
            stats['patient_count'] = 0

    except Exception:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise

    finally:
        cur.close()

    log.info("CSV generation complete. Facilities: %d, Patients: %d",
             stats['facility_count'], stats['patient_count'])

    return tmp_dir, stats


def generate_metadata(tmp_dir, stats, generation_start_epoch):
    now_epoch = time.time()
    now_human = datetime.fromtimestamp(now_epoch, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
    generation_duration = round(now_epoch - generation_start_epoch, 2)

    metadata = {
        'import_export_version':       IMPORT_EXPORT_VERSION,
        'source_key':                  SOURCE_KEY,
        'source_h360tk_version':       SOURCE_VERSION,
        'generated_at':                now_human,
        'generated_at_epoch':          int(now_epoch),
        'generation_duration_seconds': generation_duration,
        'facility_count':              stats['facility_count'],
        'patient_count':               stats['patient_count'],
    }

    metadata_path = os.path.join(tmp_dir, 'metadata.json')
    with open(metadata_path, 'w', encoding='utf-8') as f:
        json.dump(metadata, f, indent=2)

    log.info("  Written metadata.json — source_key=%s, version=%s, facilities=%d, patients=%d",
             SOURCE_KEY, SOURCE_VERSION,
             stats['facility_count'], stats['patient_count'])

    return metadata_path


def package_zip(tmp_dir):
    zip_filename = f'{SOURCE_KEY}.zip'
    zip_path = os.path.join('/tmp', zip_filename)
    zip_tmp_path = zip_path + '.tmp'

    try:
        with zipfile.ZipFile(zip_tmp_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
            for filename in sorted(os.listdir(tmp_dir)):
                file_path = os.path.join(tmp_dir, filename)
                if os.path.isfile(file_path):
                    zf.write(file_path, arcname=filename)
                    log.info("  Added to zip: %s", filename)

        os.rename(zip_tmp_path, zip_path)

    except Exception:
        if os.path.exists(zip_tmp_path):
            os.remove(zip_tmp_path)
        raise

    zip_size_kb = round(os.path.getsize(zip_path) / 1024, 2)
    log.info("  Zip created: %s (%.2f KB)", zip_filename, zip_size_kb)

    shutil.rmtree(tmp_dir, ignore_errors=True)
    log.info("  Temp dir cleaned up.")

    return zip_path


def upload_file(zip_path):
    os.makedirs(UPLOAD_DEST_PATH, exist_ok=True)
    dest = os.path.join(UPLOAD_DEST_PATH, os.path.basename(zip_path))

    if os.path.abspath(zip_path) != os.path.abspath(dest):
        shutil.copy2(zip_path, dest)
        os.remove(zip_path)

    log.info("  Zip uploaded to: %s", dest)
    return dest


def upload_sftp(zip_path):
    filename    = os.path.basename(zip_path)
    remote_path = f"{SFTP_DEST_PATH.rstrip('/')}/{filename}"
    remote_tmp  = remote_path + '.tmp'

    log.warning(
        "SFTP host key verification is disabled — "
        "set a known_hosts file in production for security."
    )

    transport = None
    sftp      = None
    try:
        transport = paramiko.Transport((SFTP_HOST, SFTP_PORT))
        transport.banner_timeout  = SFTP_TIMEOUT_SECONDS
        transport.auth_timeout    = SFTP_TIMEOUT_SECONDS
        transport.connect(username=SFTP_USER, password=SFTP_PASSWORD)

        sftp = paramiko.SFTPClient.from_transport(transport)
        sftp.get_channel().settimeout(SFTP_TIMEOUT_SECONDS)

        # Upload to a .tmp path first — atomic rename prevents the importer
        # from picking up a half-written file if the transfer fails midway.
        sftp.put(zip_path, remote_tmp)
        try:
            sftp.remove(remote_path)
        except FileNotFoundError:
            pass
        sftp.rename(remote_tmp, remote_path)

        os.remove(zip_path)
        log.info("  Zip uploaded via SFTP to: %s@%s:%s", SFTP_USER, SFTP_HOST, remote_path)

    except Exception:
        # Best-effort cleanup of the remote temp file if it was created
        if sftp is not None:
            try:
                sftp.remove(remote_tmp)
            except Exception:
                pass
        raise

    finally:
        if sftp is not None:
            try:
                sftp.close()
            except Exception:
                pass
        if transport is not None:
            transport.close()

    return remote_path


def upload_s3(zip_path):
    filename   = os.path.basename(zip_path)
    s3_key     = f"{S3_KEY_PREFIX}/{filename}" if S3_KEY_PREFIX else filename
    s3_uri     = f"s3://{S3_BUCKET}/{s3_key}"

    kwargs = dict(
        aws_access_key_id     = S3_ACCESS_KEY,
        aws_secret_access_key = S3_SECRET_KEY,
    )
    if S3_REGION:
        kwargs['region_name'] = S3_REGION
    if S3_ENDPOINT_URL:
        kwargs['endpoint_url'] = S3_ENDPOINT_URL

    try:
        s3 = boto3.client('s3', **kwargs)
        s3.upload_file(zip_path, S3_BUCKET, s3_key)
        os.remove(zip_path)
        log.info("  Zip uploaded to S3: %s", s3_uri)
    except (BotoCoreError, ClientError) as e:
        log.error("  S3 upload failed: %s", e)
        raise

    return s3_uri


def upload(zip_path):
    if UPLOAD_PROTOCOL == 'sftp':
        return upload_sftp(zip_path)
    if UPLOAD_PROTOCOL == 's3':
        return upload_s3(zip_path)
    return upload_file(zip_path)


def log_export_run(started_at, status, duration_seconds=None,
                   destination=None, error_message=None, infrastructure_layer=None):
    """Write one export_run_log row.

    Rows describe this leaf node's own export (source_key = SOURCE_KEY) unless
    infrastructure_layer is given, e.g. 'Exporter' for a configuration failure.
    """
    if infrastructure_layer:
        source_key, log_type = infrastructure_layer, LOG_TYPE_INFRASTRUCTURE
    else:
        source_key, log_type = SOURCE_KEY, LOG_TYPE_LEAF_NODE

    try:
        with psycopg2.connect(**DB_CONNECTION_PARAMS) as conn:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(
                    '''
                    INSERT INTO heart360tk_reporting.export_run_log
                        (source_key, started_at, finished_at, status,
                         duration_seconds, destination, error_message, log_type)
                    VALUES (%s, %s, NOW(), %s, %s, %s, %s, %s)
                    ''',
                    (
                        source_key,
                        datetime.fromtimestamp(started_at, tz=timezone.utc),
                        status,
                        duration_seconds,
                        destination,
                        error_message,
                        log_type,
                    )
                )
        log.info("  Export run logged to DB — source_key=%s, log_type=%s, status=%s, duration=%.2fs",
                 source_key, log_type, status, duration_seconds or 0)
    except Exception as e:
        log.warning("Could not write export run log to DB (non-fatal): %s", e)


def exit_with_exporter_error(error):
    """Log a startup configuration failure and stop the container."""
    log.error("Exporter configuration error: %s", error)
    log_export_run(
        started_at           = time.time(),
        status               = 'failed',
        error_message        = str(error),
        infrastructure_layer = SOURCE_EXPORTER,
    )
    sys.exit(1)


def run_export():
    log.info("=== Export job started (source_key=%s) ===", SOURCE_KEY)
    job_start = time.time()

    conn        = None
    destination = None

    try:
        conn = psycopg2.connect(**DB_CONNECTION_PARAMS)
        conn.autocommit = True

        tmp_dir, stats = generate_csvs(conn)
        generate_metadata(tmp_dir, stats, generation_start_epoch=job_start)
        zip_path    = package_zip(tmp_dir)
        destination = upload(zip_path)

        duration = round(time.time() - job_start, 2)
        log_export_run(
            started_at       = job_start,
            status           = 'success',
            duration_seconds = duration,
            destination      = destination,
        )
        log.info("=== Export job completed successfully in %.2fs. Destination: %s ===",
                 duration, destination)

    except Exception as e:
        duration = round(time.time() - job_start, 2)
        log.error("Export job failed: %s", e, exc_info=True)
        log_export_run(
            started_at       = job_start,
            status           = 'failed',
            duration_seconds = duration,
            error_message    = str(e),
        )

    finally:
        if conn:
            conn.close()



def start_scheduler():
    try:
        trigger = CronTrigger.from_crontab(EXPORT_CRON)
    except Exception as e:
        exit_with_exporter_error(f"Invalid EXPORT_CRON expression '{EXPORT_CRON}': {e}")

    scheduler = BlockingScheduler()
    scheduler.add_job(run_export, trigger, id='export_job', name='h360tk export')
    log.info("Scheduler started. Export will run on cron: '%s'", EXPORT_CRON)

    try:
        scheduler.start()
    except KeyboardInterrupt:
        log.info("Exporter stopped.")
        scheduler.shutdown()


if __name__ == '__main__':
    validate_config()
    start_scheduler()
