#!/usr/bin/env bash
# Fresh install and upgrade parity (story 7.4, FR-15, FR-16, NFR-5, AD-13).
#
#   PSQL="docker exec -i ${H360_PG_CONTAINER:-postgres} psql -U h360tk_root" ./scripts/verify_upgrade_path.sh
#   KEEP_DBS=1 ...   keep the two scratch databases and the dumps for a look afterwards
#
# Builds two scratch databases in the running cluster and compares them:
#   fresh    00_schemas.sql (per-database part) + 01_heart360_tables.sql with its \ir lines
#            inlined, in one psql session from stdin, as the postgres image init runs it
#            (`psql -v ON_ERROR_STOP=1 -f 01_heart360_tables.sql`).
#   upgrade  the same 00 part + 01_heart360_tables.sql at 0.6.0 (git ref BASE_REF, default
#            08a2894: the cascade-cohort tip, whose 01 is today's minus the \ir lines), then each
#            0.6.x file named by the \ir lines, in that order (never file-name order), one psql
#            session each, as `psql -U h360tk_root` would (AD-13).
# Checks:
#   1. normalised `pg_dump --schema-only` of upgrade equals fresh;
#   2. the pg_cron jobs each one schedules are the same;
#   3. normalised `pg_dump --data-only` (catalogue and config rows: medicines, thresholds, ...)
#      is the same;
#   4. running the 0.6.x chain a second time on the upgrade database changes neither its schema
#      dump nor its data dump.
# pg_dump runs where psql runs (PG_DUMP defaults to PSQL with psql -> pg_dump, so inside the
# container for the demo PSQL).
#
# What this cannot reproduce in a scratch database, and how it is handled:
#   - pg_cron. The extension can only be created in cron.database_name (heart360tk_database), so
#     each scratch database gets a stub `cron` schema (job table; schedule/unschedule functions
#     with pg_cron's signatures and upsert-by-name behaviour). The stub schema is excluded from the
#     dumps; the scheduled jobs are compared as rows instead (check 2).
#   - Cluster-wide statements in 00_schemas.sql (CREATE USER, ALTER ROLE ... SET, GRANT
#     pg_read_server_files) are already applied to the live cluster and cannot run twice. They
#     are skipped; the roles they create must exist (they do on the demo stack). 0.6.5_to_0.6.6
#     re-runs its idempotent role statements against the live roles with the values they already
#     have. Role attributes are cluster-level and not part of a database dump either way.
#   - Grafana's own tables in grafana_schema (created by Grafana at first start) and the
#     db-grants service are outside the init scripts and are not compared.
#   - The empty-volume `docker compose up -d --build` boot (AC 7.4 part 3) is a human step in the
#     demo runbook: this script never runs `compose down` or touches volumes.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/h360_env.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT/pg_init_scripts"
TABLES="$INIT/01_heart360_tables.sql"
SCHEMAS="$INIT/00_schemas.sql"
BASE_REF="${BASE_REF:-08a2894}"
FRESH_DB="${FRESH_DB:-h360_upgrade_fresh}"
UPGRADE_DB="${UPGRADE_DB:-h360_upgrade_from060}"

if [[ -z "${PSQL:-}" ]]; then
    if command -v psql >/dev/null 2>&1; then PSQL="psql"; else PSQL="docker exec -i ${H360_PG_CONTAINER:-postgres} psql -U h360tk_root"; fi
fi
PG_DUMP="${PG_DUMP:-${PSQL/psql/pg_dump}}"
read -r -a PSQL_CMD <<< "$PSQL"
read -r -a PG_DUMP_CMD <<< "$PG_DUMP"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/h360_upgrade.XXXXXX")"
fail() { echo "FAIL $*" >&2; exit 1; }

for db in "$FRESH_DB" "$UPGRADE_DB"; do
    [[ "$db" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "database name must be a simple identifier: $db"
done

psql_admin() { "${PSQL_CMD[@]}" -X -q -v ON_ERROR_STOP=1 -d postgres "$@"; }
psql_db()    { local db="$1"; shift; "${PSQL_CMD[@]}" -X -q -v ON_ERROR_STOP=1 -d "$db" "$@"; }

psql_admin -c 'SELECT 1' >/dev/null 2>&1 || fail "verifier-blocked: '$PSQL' cannot connect"

drop_dbs() {
    for db in "$FRESH_DB" "$UPGRADE_DB"; do
        psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();" >/dev/null
        psql_admin -c "DROP DATABASE IF EXISTS $db;" >/dev/null 2>&1
    done
}
cleanup() {
    if [[ "${KEEP_DBS:-}" == "1" ]]; then
        echo "kept databases $FRESH_DB, $UPGRADE_DB and dumps in $WORK"
    else
        drop_dbs || true
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

# --------------------------------------------------------------------------- inputs
CHAIN=()
while IFS= read -r f; do CHAIN+=("$f"); done < <(sed -n 's/^\\ir[[:space:]]\{1,\}\(migrations\/[^[:space:]]*\.sql\)[[:space:]]*$/\1/p' "$TABLES")
(( ${#CHAIN[@]} > 0 )) || fail "no \\ir lines in $TABLES"
for f in "${CHAIN[@]}"; do [[ -f "$INIT/$f" ]] || fail "missing $INIT/$f"; done
echo "chain (\\ir order): ${CHAIN[*]#migrations/}"

# 0.6.0 base: 01 at BASE_REF. It must equal today's 01 without the \ir lines (AD-13: only the
# merge-housekeeping commit adds lines to 01).
grep -v '^\\ir[[:space:]]' "$TABLES" > "$WORK/01_without_ir.sql"
if git -C "$ROOT" show "$BASE_REF:pg_init_scripts/01_heart360_tables.sql" > "$WORK/01_at_060.sql" 2>/dev/null; then
    if ! diff -q <(sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$WORK/01_at_060.sql") \
                 <(sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$WORK/01_without_ir.sql") >/dev/null; then
        echo "note: 01_heart360_tables.sql differs from $BASE_REF beyond its \\ir lines (shown below); the upgrade base is $BASE_REF"
        diff "$WORK/01_at_060.sql" "$WORK/01_without_ir.sql" | head -20 || true
    fi
else
    echo "note: git ref $BASE_REF not found; 0.6.0 base = today's 01 without its \\ir lines"
    cp "$WORK/01_without_ir.sql" "$WORK/01_at_060.sql"
fi

# 00_schemas.sql, per-database part: cluster-wide statements dropped, pg_cron replaced by a stub.
cat > "$WORK/cron_stub.sql" <<'SQL'
-- Stub of the pg_cron objects 01 and the migrations use (see the script header). Definer
-- functions, like pg_cron, so heart360tk can schedule without owning cron.job.
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE IF NOT EXISTS cron.job (
    jobid    bigserial PRIMARY KEY,
    schedule text NOT NULL,
    command  text NOT NULL,
    jobname  text UNIQUE
);
CREATE OR REPLACE FUNCTION cron.schedule(job_name text, schedule text, command text) RETURNS bigint
LANGUAGE sql SECURITY DEFINER AS $$
    INSERT INTO cron.job (jobname, schedule, command) VALUES (job_name, schedule, command)
    ON CONFLICT (jobname) DO UPDATE SET schedule = EXCLUDED.schedule, command = EXCLUDED.command
    RETURNING jobid;
$$;
CREATE OR REPLACE FUNCTION cron.schedule(schedule text, command text) RETURNS bigint
LANGUAGE sql SECURITY DEFINER AS $$ INSERT INTO cron.job (schedule, command) VALUES (schedule, command) RETURNING jobid; $$;
CREATE OR REPLACE FUNCTION cron.unschedule(job_name text) RETURNS boolean
LANGUAGE sql SECURITY DEFINER AS $$ WITH d AS (DELETE FROM cron.job WHERE jobname = job_name RETURNING 1) SELECT count(*) > 0 FROM d; $$;
CREATE OR REPLACE FUNCTION cron.unschedule(job_id bigint) RETURNS boolean
LANGUAGE sql SECURITY DEFINER AS $$ WITH d AS (DELETE FROM cron.job WHERE jobid = job_id RETURNING 1) SELECT count(*) > 0 FROM d; $$;
GRANT USAGE ON SCHEMA cron TO PUBLIC;
GRANT SELECT ON cron.job TO PUBLIC;
SQL
{
    grep -v -E '^[[:space:]]*(CREATE USER|ALTER ROLE|GRANT pg_read_server_files)' "$SCHEMAS" \
        | sed -e '/CREATE EXTENSION IF NOT EXISTS pg_cron;/{r '"$WORK/cron_stub.sql" -e 'd;}'
} > "$WORK/00_per_db.sql"
grep -q 'CREATE TABLE IF NOT EXISTS cron.job' "$WORK/00_per_db.sql" || fail "00_schemas.sql no longer creates pg_cron; update the stub step"

# Roles 00_schemas.sql creates must exist (cluster-wide, already there on the stack).
missing="$(psql_admin -At -c "SELECT string_agg(r, ', ') FROM unnest(ARRAY['grafana','heart360tk','heart360tk_cached']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)")"
[[ -z "$missing" ]] || fail "roles missing from the cluster: $missing (start the stack first)"

# 01 with every \ir inlined, as one script (the init's single psql -f session).
inline_ir() {
    local file="$1" dir line
    dir="$(dirname "$file")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\\ir[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            cat "$dir/${BASH_REMATCH[1]}"
            echo
        else
            printf '%s\n' "$line"
        fi
    done < "$file"
}
inline_ir "$TABLES" > "$WORK/fresh_install.sql"

# --------------------------------------------------------------------------- build
drop_dbs
for db in "$FRESH_DB" "$UPGRADE_DB"; do
    psql_admin -c "CREATE DATABASE $db;" >/dev/null
    psql_db "$db" < "$WORK/00_per_db.sql" >/dev/null
done

echo "fresh install: 00 + 01 with ${#CHAIN[@]} inlined files, one session"
psql_db "$FRESH_DB" < "$WORK/fresh_install.sql" > "$WORK/fresh.log" 2>&1 || { tail -20 "$WORK/fresh.log"; fail "fresh install"; }

echo "0.6.0 install: 00 + 01 at $BASE_REF"
psql_db "$UPGRADE_DB" < "$WORK/01_at_060.sql" > "$WORK/base.log" 2>&1 || { tail -20 "$WORK/base.log"; fail "0.6.0 install"; }

# Pass 1 stops at the first failing file. Pass 2 (re-run) tries every file and lists each failure:
# every migration is one transaction, so a failed file leaves nothing behind.
run_chain() {
    local pass="$1" f
    for f in "${CHAIN[@]}"; do
        if ! psql_db "$UPGRADE_DB" < "$INIT/$f" > "$WORK/chain.log" 2>&1; then
            if [[ "$pass" == "1" ]]; then
                tail -20 "$WORK/chain.log"; fail "upgrade pass 1: $f"
            fi
            echo "FAIL second chain run: $f: $(grep -m1 -E '^(psql:.*)?ERROR' "$WORK/chain.log" | sed 's/^psql:[^E]*//')"
            failures=$((failures + 1))
        fi
    done
}
failures=0
echo "upgrade pass 1: ${#CHAIN[@]} files in \\ir order"
run_chain 1

# --------------------------------------------------------------------------- compare
normalise() {
    # Drop comments, blank lines, session SETs, pg_dump's \restrict keys and sequence positions.
    grep -v -E '^(--|SET |SELECT pg_catalog\.set_config|SELECT pg_catalog\.setval|\\restrict|\\unrestrict|[[:space:]]*$)' || true
}
sort_copy_rows() {
    # Rows inside each COPY block are sorted: an UPDATE to the same values (ON CONFLICT DO UPDATE)
    # moves a row in the heap, which changes dump order but not content.
    awk '
        /^COPY / { print; inblock = 1; n = 0; next }
        inblock && /^\\\.$/ { fflush(); cmd = "sort"; for (i = 1; i <= n; i++) print rows[i] | cmd; close(cmd); print; inblock = 0; next }
        inblock { rows[++n] = $0; next }
        { print }
    '
}
dump() {
    local db="$1" kind="$2"
    # stderr kept aside: --data-only warns about the org_units self-reference on every run.
    "${PG_DUMP_CMD[@]}" -d "$db" "--$kind" --exclude-schema=cron 2> "$WORK/pg_dump.err" | normalise | sort_copy_rows \
        || { cat "$WORK/pg_dump.err" >&2; fail "pg_dump $kind $db"; }
}
jobs() {
    psql_db "$1" -At -c "SELECT jobname || ' | ' || schedule || ' | ' || command FROM cron.job ORDER BY jobname NULLS LAST, command"
}

compare() {
    local label="$1" a="$2" b="$3"
    if diff -u "$a" "$b" > "$WORK/diff.txt"; then
        echo "PASS $label ($(wc -l < "$a" | tr -d ' ') lines)"
    else
        echo "FAIL $label"
        head -60 "$WORK/diff.txt"
        failures=$((failures + 1))
    fi
}

dump "$FRESH_DB" schema-only > "$WORK/fresh.schema"
dump "$UPGRADE_DB" schema-only > "$WORK/upgrade.schema"
dump "$FRESH_DB" data-only > "$WORK/fresh.data"
dump "$UPGRADE_DB" data-only > "$WORK/upgrade.data"
jobs "$FRESH_DB" > "$WORK/fresh.jobs"
jobs "$UPGRADE_DB" > "$WORK/upgrade.jobs"
[[ -s "$WORK/fresh.schema" ]] || fail "empty schema dump from '$PG_DUMP'"

compare "schema: upgrade from 0.6.0 equals fresh install" "$WORK/fresh.schema" "$WORK/upgrade.schema"
compare "pg_cron jobs: upgrade equals fresh" "$WORK/fresh.jobs" "$WORK/upgrade.jobs"
compare "config data: upgrade equals fresh" "$WORK/fresh.data" "$WORK/upgrade.data"

echo "upgrade pass 2: the same chain again"
run_chain 2
dump "$UPGRADE_DB" schema-only > "$WORK/upgrade2.schema"
dump "$UPGRADE_DB" data-only > "$WORK/upgrade2.data"
jobs "$UPGRADE_DB" > "$WORK/upgrade2.jobs"
compare "schema: second chain run changes nothing" "$WORK/upgrade.schema" "$WORK/upgrade2.schema"
compare "data: second chain run changes nothing" "$WORK/upgrade.data" "$WORK/upgrade2.data"
compare "pg_cron jobs: second chain run changes nothing" "$WORK/upgrade.jobs" "$WORK/upgrade2.jobs"

echo "not checked here: empty-volume 'docker compose up -d --build' (runbook step, AC 7.4 part 3)"
if (( failures )); then
    fail "verify_upgrade_path ($failures checks)"
fi
echo "PASS verify_upgrade_path"
