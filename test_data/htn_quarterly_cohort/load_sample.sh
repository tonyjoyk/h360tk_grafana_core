#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
docker exec -i postgres psql -v ON_ERROR_STOP=1 -U h360tk_root -d heart360tk_database \
  -f /docker-entrypoint-initdb.d/migrations/0.5.0_to_htn_cohort_q1.sql
docker cp "$root/test_data/htn_quarterly_cohort/seed.sql" postgres:/tmp/cohort_seed.sql
docker exec -i postgres psql -v ON_ERROR_STOP=1 -U h360tk_root -d heart360tk_database <<'SQL'
BEGIN;
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
\ir /tmp/cohort_seed.sql
COMMIT;
SQL
docker exec -i postgres psql -v ON_ERROR_STOP=1 -U h360tk_root -d heart360tk_database \
  -c "SET ROLE heart360tk; SELECT heart360tk_reporting.refresh_all_reporting_tables();"
docker exec -i postgres psql -U h360tk_root -d heart360tk_database -c \
  "SELECT id, name, level, parent_id FROM heart360tk_schema.org_units WHERE name IN ('Cohort Sample District', 'Cohort Sample Facility', 'Cohort Empty Facility') ORDER BY level;"
