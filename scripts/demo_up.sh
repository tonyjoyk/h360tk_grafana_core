#!/usr/bin/env bash
# Bring the toolkit up with demo data. Safe to re-run: it only adds data and never deletes patient rows.
#   ./scripts/demo_up.sh          start, load demo data if the database is empty
#   ./scripts/demo_up.sh --fresh  drop the volumes first (wipes the local demo database)
set -euo pipefail
cd "$(dirname "$0")/.."

psql_root() { docker exec -i postgres sh -c 'psql -U "$POSTGRES_USER" -d heart360tk_database -v ON_ERROR_STOP=1 -qtA'; }

if [[ "${1:-}" == "--fresh" ]]; then
  docker compose down -v
fi
docker compose up -d --build

echo "Waiting for Postgres to finish its init scripts..."
until echo "select 1 from heart360tk_schema.org_units limit 1" | psql_root >/dev/null 2>&1; do sleep 3; done

patients=$(echo "select count(*) from heart360tk_schema.patients" | psql_root)
if [[ "$patients" == "0" ]]; then
  echo "Loading the demo cohort (about 8,000 patients)..."
  mkdir -p data/upload
  cp test_data/demo/demo_generated.xlsx data/upload/
  until [[ "$(echo "select count(*) from heart360tk_schema.patients" | psql_root)" -ge 8000 ]]; do sleep 5; done
  sleep 10
fi

echo "Loading demo seeds..."
psql_root < test_data/demo/seed_screening_cascade.sql >/dev/null
for seed in test_data/demo/seeds/*.sql; do
  [[ -e "$seed" ]] || continue
  echo "  $(basename "$seed")"
  psql_root < "$seed" >/dev/null
done

echo "Refreshing reporting tables..."
echo "set role heart360tk; select heart360tk_reporting.run_refresh_with_status('demo_up');" | psql_root >/dev/null

echo "Ready. Grafana: http://localhost:3000 (admin / admin)"
