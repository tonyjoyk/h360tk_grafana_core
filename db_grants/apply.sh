#!/bin/sh
# One-shot `db-grants` compose service (AD-14, ASSUMPTION A60).
# Waits until the security migration has created grafana_reader and Grafana has created its
# tables, then applies grafana_reader_grants.sql and the h360_api password.
# Connection comes from the standard PG* environment variables.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
MAX_TRIES="${DB_GRANTS_MAX_TRIES:-200}"
SLEEP_SECONDS="${DB_GRANTS_SLEEP_SECONDS:-3}"

ready_sql="SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader')
  AND to_regclass('grafana_schema.\"user\"') IS NOT NULL
  AND to_regclass('grafana_schema.team') IS NOT NULL
  AND to_regclass('grafana_schema.team_member') IS NOT NULL"

tries=0
until [ "$(psql -X -tA -c "$ready_sql" 2>/dev/null || true)" = "t" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$MAX_TRIES" ]; then
        echo "db-grants: gave up after $tries tries waiting for grafana_reader and grafana_schema.team_member" >&2
        exit 1
    fi
    sleep "$SLEEP_SECONDS"
done

psql -X -q -v ON_ERROR_STOP=1 -f "$DIR/grafana_reader_grants.sql"
echo "db-grants: grafana_reader grants applied"

if [ -n "${H360_API_DB_PASSWORD:-}" ]; then
    psql -X -q -v ON_ERROR_STOP=1 -v h360_api_password="$H360_API_DB_PASSWORD" -f "$DIR/h360_api_password.sql"
    echo "db-grants: h360_api password set"
fi
