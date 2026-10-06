#!/bin/sh
# Prove the quarter-1 cohort oracle. Rolls back. Does not keep fixture patients.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
docker cp "$root/test_data/htn_quarterly_cohort/seed.sql" postgres:/tmp/cohort_seed.sql
docker cp "$root/test_data/htn_quarterly_cohort/assert.sql" postgres:/tmp/cohort_assert.sql
docker exec -i postgres psql -v ON_ERROR_STOP=1 -U h360tk_root -d heart360tk_database <<'SQL'
BEGIN;
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
\ir /docker-entrypoint-initdb.d/sql/cohort_q1_view.sql
\ir /tmp/cohort_seed.sql
\ir /tmp/cohort_assert.sql
ROLLBACK;
SQL
echo cohort_q1_oracle_ok
