#!/usr/bin/env bash
# Bring the toolkit up with demo data (story 1.2, AD-34, PD-16). Safe to re-run:
# it only adds data and never deletes patient rows.
#   ./scripts/demo_up.sh          start, load demo data if the database is empty
#   ./scripts/demo_up.sh --fresh  drop the volumes first (wipes the local demo database)
#
# Every wait has a timeout. On a timeout the script names what it was waiting
# for, says what to do next, and exits 1. Override a timeout in seconds with
#   DEMO_PG_TIMEOUT (300)  DEMO_WATCHER_TIMEOUT (900)  DEMO_INGEST_TIMEOUT (1200)
#   DEMO_GRANTS_TIMEOUT (300)  DEMO_API_TIMEOUT (180)
set -euo pipefail
cd "$(dirname "$0")/.."

PINNED_MONTH="2026-10-01"
source "$(dirname "$0")/h360_env.sh"
GRAFANA="$GRAFANA_URL"
API="$H360_API_URL"
P="$H360_CONTAINER_PREFIX"
T0=$SECONDS
TMP="$(mktemp -d "${TMPDIR:-/tmp}/demo_up.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PG_TIMEOUT="${DEMO_PG_TIMEOUT:-300}"
WATCHER_TIMEOUT="${DEMO_WATCHER_TIMEOUT:-900}"
INGEST_TIMEOUT="${DEMO_INGEST_TIMEOUT:-1200}"
GRANTS_TIMEOUT="${DEMO_GRANTS_TIMEOUT:-300}"
API_TIMEOUT="${DEMO_API_TIMEOUT:-180}"

# Over TCP on purpose: the temporary server Postgres runs during its init
# scripts listens on the socket only, so TCP means init is finished (R-02).
psql_root() {
  docker exec -i "${P}postgres" sh -c \
    'psql -h 127.0.0.1 -U "$POSTGRES_USER" -d heart360tk_database -X -v ON_ERROR_STOP=1 -qtA'
}
q() { echo "$1" | psql_root; }

elapsed() { echo "$((SECONDS - T0))s"; }
say() { echo "[$(elapsed)] $*"; }

fail() {
  echo "" >&2
  echo "FAIL: $1" >&2
  echo "Next step: $2" >&2
  exit 1
}

if [[ "${1:-}" == "--fresh" ]]; then
  docker compose down -v
  rm -rf data/.h360_ingested  # done markers would skip the reload into the new empty database
elif [[ -n "${1:-}" ]]; then
  echo "usage: $0 [--fresh]" >&2
  exit 2
fi

say "Starting containers..."
docker compose up -d --build

# --- Postgres -----------------------------------------------------------
say "Waiting for Postgres to accept TCP connections and finish its init scripts (up to ${PG_TIMEOUT}s)..."
deadline=$((SECONDS + PG_TIMEOUT))
until docker exec "${P}postgres" pg_isready -q -h 127.0.0.1 -p 5432 >/dev/null 2>&1 \
  && [[ "$(q "select to_regclass('heart360tk_schema.org_units') is not null" 2>/dev/null)" == "t" ]]; do
  (( SECONDS < deadline )) || fail "Postgres was not ready over TCP after ${PG_TIMEOUT}s." \
    "Run 'docker logs ${P}postgres' and look for an error in the init scripts. Then re-run this script."
  sleep 3
done
say "Postgres is ready."

count_patients() { q "select count(*) from heart360tk_schema.patients"; }

# --- Demo cohort ----------------------------------------------------------
patients="$(count_patients)"
if [[ "$patients" == "0" ]]; then
  say "Waiting for the file watcher in file-upload-trigger (up to ${WATCHER_TIMEOUT}s; the first start installs Python packages)..."
  deadline=$((SECONDS + WATCHER_TIMEOUT))
  while :; do
    started="$(docker inspect -f '{{.State.StartedAt}}' "${P}file-upload-trigger" 2>/dev/null || true)"
    if [[ -n "$started" ]] && docker logs --since "$started" ${P}file-upload-trigger 2>&1 | grep -q "running /inotifywait.sh"; then
      break
    fi
    (( SECONDS < deadline )) || fail "The file watcher did not start within ${WATCHER_TIMEOUT}s." \
      "Run 'docker logs ${P}file-upload-trigger'. If pip is still installing, re-run with DEMO_WATCHER_TIMEOUT=1800."
    sleep 3
  done
  say "Watcher is running."

  say "Loading the demo cohort from test_data/demo/demo_generated.xlsx..."
  mkdir -p data/upload
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cp test_data/demo/demo_generated.xlsx data/upload/

  # Done when the ingest prints its summary and the patient count stops growing.
  # No fixed patient number: a skipped row must not make this wait forever (R-02).
  deadline=$((SECONDS + INGEST_TIMEOUT))
  last=-1
  stable=0
  last_print=0
  while :; do
    now="$(count_patients 2>/dev/null || echo "$last")"
    if [[ "$now" == "$last" ]]; then stable=$((stable + 1)); else stable=0; fi
    last="$now"
    summary=0
    log="$(docker logs --since "$since" ${P}file-upload-trigger 2>&1)"
    if grep -qE "Error loading file|CONNECTION ERROR" <<<"$log"; then
      fail "The demo cohort failed to load." \
        "Run 'docker logs --since $since ${P}file-upload-trigger', fix the error, then 'docker compose restart file-processor' and re-run this script."
    fi
    if grep -q -- "--- EXECUTION SUMMARY ---" <<<"$log"; then
      summary=1
    fi
    if (( summary == 1 && stable >= 2 && now > 0 )); then
      break
    fi
    if (( SECONDS - last_print >= 30 )); then
      say "  ingest running: ${now} patients so far"
      last_print=$SECONDS
    fi
    (( SECONDS < deadline )) || fail "The demo cohort did not finish loading within ${INGEST_TIMEOUT}s (${now} patients, summary line seen: ${summary})." \
      "Run 'docker logs --since $since ${P}file-upload-trigger' and look for 'Error loading file' or 'CONNECTION ERROR'. Fix it, then 'docker compose restart file-processor' and re-run this script."
    sleep 5
  done
  say "Ingest finished: ${last} patients."
else
  say "Database already has ${patients} patients. Skipping the cohort load."
fi

# --- Seeds ----------------------------------------------------------------
# Each seed checks its own demo_seed_marker row, so a second run adds nothing.
run_sql() {
  local file="$1" label="$2" t0=$SECONDS next=30 pid status
  echo "[$(elapsed)]   ${label} ..."
  psql_root < "$file" > "$TMP/out.log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if (( SECONDS - t0 >= next )); then
      echo "[$(elapsed)]     still running ${label} ($((SECONDS - t0))s)"
      next=$((next + 30))
    fi
  done
  if wait "$pid"; then status=0; else status=$?; fi
  grep -E "NOTICE" "$TMP/out.log" | grep -v "already exists, skipping" | sed -e 's/^.*NOTICE: */      /' || true
  if (( status != 0 )); then
    tail -n 20 "$TMP/out.log" >&2
    fail "${label} failed (psql exit ${status})." \
      "Read the error above, fix the seed, and re-run. Seeds that already finished are skipped."
  fi
  echo "[$(elapsed)]   ${label} done in $((SECONDS - t0))s"
}

# The demo file carries patients, visits and medicines; the seeds add call results and drug stock.
# Retired seeds in test_data/demo/seeds/retired/ are not run.
say "Loading demo seeds (call results and drug stock)..."
run_sql test_data/demo/seed_screening_cascade.sql "seed_screening_cascade.sql"
for seed in test_data/demo/seeds/*.sql; do
  [[ -e "$seed" ]] || continue
  run_sql "$seed" "$(basename "$seed")"
done

say "Refreshing reporting tables..."
t_refresh=$SECONDS
q "set role heart360tk; select heart360tk_reporting.run_refresh_with_status('demo_up');" >"$TMP/refresh.log" 2>&1 \
  || { tail -n 20 "$TMP/refresh.log" >&2; fail "The reporting refresh failed." "Read the error above, then re-run this script."; }
say "Refresh done in $((SECONDS - t_refresh))s."

# --- Services ---------------------------------------------------------------
say "Waiting for db-grants to finish (up to ${GRANTS_TIMEOUT}s)..."
deadline=$((SECONDS + GRANTS_TIMEOUT))
retried=0
while :; do
  state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${P}db-grants" 2>/dev/null || echo "missing")"
  case "$state" in
    "exited 0") break ;;
    exited*)
      if (( retried == 0 )); then
        say "  db-grants exited with '${state#exited }'. Running it once more now that Postgres is ready..."
        docker compose start db-grants >/dev/null
        retried=1
      else
        fail "db-grants exited with code ${state#exited }." \
          "Run 'docker logs ${P}db-grants', fix the error, then 'docker compose start db-grants' and re-run this script."
      fi
      ;;
  esac
  (( SECONDS < deadline )) || fail "db-grants did not finish within ${GRANTS_TIMEOUT}s (state: ${state})." \
    "Run 'docker logs ${P}db-grants'. It waits for Grafana's tables; check 'docker logs ${P}grafana'."
  sleep 3
done
say "db-grants exited 0."

say "Waiting for h360-api ${API}/healthz (up to ${API_TIMEOUT}s)..."
deadline=$((SECONDS + API_TIMEOUT))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${API}/healthz" || true)" == "200" ]]; do
  (( SECONDS < deadline )) || fail "h360-api did not answer 200 on /healthz within ${API_TIMEOUT}s." \
    "Run 'docker logs ${P}h360-api'. Then re-run this script."
  sleep 3
done
say "h360-api is healthy."

say "Waiting for Grafana ${GRAFANA}/api/health (up to ${API_TIMEOUT}s)..."
deadline=$((SECONDS + API_TIMEOUT))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${GRAFANA}/api/health" || true)" == "200" ]]; do
  (( SECONDS < deadline )) || fail "Grafana did not answer on /api/health within ${API_TIMEOUT}s." \
    "Run 'docker logs ${P}grafana'. Then re-run this script."
  sleep 3
done

say "Creating demo users..."
./scripts/demo_users.sh | sed -e 's/^/      /' \
  || fail "scripts/demo_users.sh failed." "Read the error above, then run ./scripts/demo_users.sh on its own."

# --- Links ------------------------------------------------------------------
org_id() { q "select id from heart360tk_schema.org_units where name = '$1' order by id limit 1"; }
district_d="$(org_id District-D)"
phc_e="$(org_id PHC-E)"
phc_a="$(org_id PHC-A)"
[[ -n "$district_d" && -n "$phc_e" && -n "$phc_a" ]] \
  || fail "District-D, PHC-E or PHC-A is missing from org_units." "Check the demo cohort loaded, then re-run."

counts="$(q "select (select count(*) from heart360tk_schema.patients) || ' patients, ' || (select count(*) from heart360tk_schema.encounters) || ' encounters, ' || (select count(*) from heart360tk_schema.prescriptions) || ' prescriptions, ' || (select count(*) from heart360tk_schema.call_results) || ' call results'")"

cat <<EOF

Ready in $(elapsed). ${counts}.

Reporting month: ${PINNED_MONTH} (Oct-2026). Reports should open on this month.
Open only ${GRAFANA} (not 127.0.0.1 or another host name).
Grafana admin: admin / admin. Demo Viewers: district.d / demo, nurse.phc-a / demo.

1. Reports, District-D, BP readings check (sign in as admin or district.d):
   ${GRAFANA}/d/heart360_reports?var-org_unit=${district_d}&var-reporting_month=${PINNED_MONTH}&-dtab=BP-readings-check

2. PHC-E on the program dashboard, then click "Ask HEARTS360" at the bottom right to open the chat (admin):
   ${GRAFANA}/d/heart360_showcase?var-org_unit=${phc_e}

3. Overdue list as nurse.phc-a (password demo):
   ${GRAFANA}/d/heart360_showcase?var-org_unit=${phc_a}&-dtab=Overdue-list
EOF
