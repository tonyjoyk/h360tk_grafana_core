#!/usr/bin/env bash
# Run every check for the shipped features, in a fixed order (story 7.1, FR-18, NFR-1, NFR-9,
# AD-35, PD-17, PD-22). Stops at the first failure and names it. One green run freezes the demo.
#
#   ./scripts/verify_all.sh                 every check below, against the running stack
#   ./scripts/verify_all.sh --with-demo-up  first runs ./scripts/demo_up.sh twice and fails if the
#                                           patients, encounters, prescriptions or call_results
#                                           counts differ between the two runs (PD-17). It
#                                           restarts containers and re-runs the seeds.
#   ./scripts/verify_all.sh --list          print the checks and exit
#   ./scripts/verify_all.sh --skip NAME     skip one check (repeatable); the summary names it
#   ./scripts/verify_all.sh --keep-going    run every check and list all failures at the end
#
# PSQL (AD-35). Per-rule scripts read PSQL. When PSQL is unset and there is no psql on PATH (this
# Mac), PSQL="docker exec -i postgres psql -U h360tk_root". Scripts that call plain `psql` with a
# DSN (verify_security.sh, verify_dashboard_queries.py fallback, demo_users.sh, the drug stock
# scripts' local mode) get a temporary `psql` shim on PATH that runs psql in the postgres
# container: a host file given with -f is sent on stdin and \i / \ir lines naming host files are
# inlined, so host paths work there too.
#
# The shipped list is explicit. When a report is cut (stub rule PD-2, PD-22), delete its
# verify_<topic>.sh line below in the same change that stubs it.
# Not in the list: pg_init_scripts/migrations/verify_protocol_drug_config.sh (pre-merge 0.5.1
# fixture: hard-codes `sudo -u postgres psql`, ignores PSQL, and runs DROP ROLE / CREATE ROLE
# heart360tk, which is unsafe on a shared cluster). Its migration, 0.6.0_to_0.6.1, is loaded and
# exercised by the verify_drug_stock_* scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MIG="pg_init_scripts/migrations"

# name | command (run with bash -c from the repo root). Order: static file checks, per-rule
# fixtures in scratch databases, the migration chain, then checks against the live stack.
CHECKS=(
  "build_reports_dashboard|python3 scripts/build_reports_dashboard.py --check"
  "check_htn_dm_untouched|python3 scripts/check_htn_dm_untouched.py"
  "verify_seeds_insert_only|bash scripts/verify_seeds_insert_only.sh"
  "verify_banned_words_self_test|python3 scripts/verify_banned_words.py --self-test"
  "h360_api_tests|run_h360_api_tests"
  # Per-rule fixtures (AD-35). Drug stock (Epic 3).
  "verify_drug_stock_on_hand|bash $MIG/verify_drug_stock_on_hand.sh"
  "verify_drug_stock_form_cohort|bash $MIG/verify_drug_stock_form_cohort.sh"
  "verify_drug_stock_patient_days|bash $MIG/verify_drug_stock_patient_days.sh"
  "verify_drug_stock_pull|bash $MIG/verify_drug_stock_pull.sh"
  "verify_drug_stock_fixes|bash $MIG/verify_drug_stock_fixes.sh"
  "verify_drug_stock_entry|bash $MIG/verify_drug_stock_entry.sh"
  # Medicine data (Epic 4).
  "verify_medicine_model|bash $MIG/verify_medicine_model.sh"
  # Reports (Epic 5). One line per shipped report; a cut report's line leaves with it.
  "verify_report_common|bash $MIG/verify_report_common.sh"
  "verify_adherence|bash $MIG/verify_adherence.sh"
  "verify_titration|bash $MIG/verify_titration.sh"
  "verify_fudging|bash $MIG/verify_fudging.sh"
  "verify_statins|bash $MIG/verify_statins.sh"
  "verify_calling|bash $MIG/verify_calling.sh"
  "verify_new_patients|bash $MIG/verify_new_patients.sh"
  "verify_report_flags|bash $MIG/verify_report_flags.sh"
  "verify_audit_reports|bash $MIG/verify_audit_reports.sh"
  # Chat SQL (Epic 6).
  "verify_chat_levers|bash $MIG/verify_chat_levers.sh"
  # Migration chain (7.4).
  "verify_upgrade_path|bash scripts/verify_upgrade_path.sh"
  # Live stack.
  "verify_dashboard_queries|python3 scripts/verify_dashboard_queries.py"
  "verify_security_g1a|bash scripts/verify_security.sh --g1a"
  "verify_security_g1b|bash scripts/verify_security.sh"
  "verify_seed_targets|run_if_present scripts/verify_seed_targets.sh"
  "verify_banned_words|python3 scripts/verify_banned_words.py"
  "verify_chat|bash scripts/verify_chat.sh"
)

WITH_DEMO_UP=0
KEEP_GOING=0
LIST=0
SKIPS=()
while (($#)); do
  case "$1" in
    --with-demo-up) WITH_DEMO_UP=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    --list) LIST=1 ;;
    --skip) SKIPS+=("${2:?--skip needs a check name}"); shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if (( LIST )); then
  ((WITH_DEMO_UP)) && echo "demo_up_twice_row_counts"
  for c in "${CHECKS[@]}"; do echo "${c%%|*}"; done
  exit 0
fi
for s in "${SKIPS[@]+"${SKIPS[@]}"}"; do
  printf '%s\n' "${CHECKS[@]%%|*}" "demo_up_twice_row_counts" | grep -qx "$s" || { echo "unknown check to skip: $s" >&2; exit 2; }
done

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/verify_all.XXXXXX")"
SHIM=""
cleanup() { [[ -n "$SHIM" ]] && rm -rf "$SHIM"; return 0; }
trap cleanup EXIT

# ------------------------------------------------------------------------------ psql setup
if ! command -v psql >/dev/null 2>&1; then
  : "${PSQL:=docker exec -i postgres psql -U h360tk_root}"
  PG_USER="$(docker exec postgres printenv POSTGRES_USER 2>/dev/null || true)"
  SHIM="$(mktemp -d "${TMPDIR:-/tmp}/verify_all_bin.XXXXXX")"
  cat > "$SHIM/psql" <<'SH'
#!/usr/bin/env bash
# Temporary psql shim from verify_all.sh: psql inside the postgres container.
container="${H360_PG_CONTAINER:-postgres}"
args=(); infile=""; has_c=0
while (($#)); do
  case "$1" in
    -f|--file) if [[ -f "${2:-}" ]]; then infile="$2"; shift 2; continue; fi ;;
    --file=*) if [[ -f "${1#--file=}" ]]; then infile="${1#--file=}"; shift; continue; fi ;;
    -c|--command|--command=*|-c?*) has_c=1 ;;
  esac
  args+=("$1"); shift
done
envs=(-e "PGUSER=${PGUSER:-${H360_PG_USER:-h360tk_root}}")
for v in PGCONNECT_TIMEOUT PGOPTIONS PGPASSWORD; do [[ -n "${!v:-}" ]] && envs+=(-e "$v"); done
if (( has_c )) && [[ -z "$infile" ]]; then
  exec docker exec -i "${envs[@]}" "$container" psql "${args[@]}"
fi
[[ -n "$infile" ]] && exec < "$infile"
set -o pipefail
python3 -c '
import os, re, sys
pat = re.compile(r"^\s*\\(ir?|include(?:_relative)?)\s+(\S+)\s*$")
def emit(lines, base):
    for line in lines:
        m = pat.match(line)
        if m:
            p = m.group(2).strip("\x27\"")
            rel = m.group(1) in ("ir", "include_relative")
            full = p if os.path.isabs(p) else os.path.join(base if rel else os.getcwd(), p)
            if os.path.isfile(full):
                with open(full, encoding="utf-8") as fh:
                    emit(fh.read().splitlines(True), os.path.dirname(os.path.abspath(full)))
                sys.stdout.write("\n")
                continue
        sys.stdout.write(line)
base = os.path.dirname(os.path.abspath(sys.argv[1])) if sys.argv[1] else os.getcwd()
emit(sys.stdin, base)
' "$infile" | docker exec -i "${envs[@]}" "$container" psql "${args[@]}"
SH
  chmod +x "$SHIM/psql"
  export PATH="$SHIM:$PATH"
  export H360_PG_USER="${PG_USER:-h360tk_root}"
fi
export PSQL="${PSQL:-}"
[[ -n "$PSQL" ]] || unset PSQL

run_h360_api_tests() {
  local image
  image="$(docker inspect -f '{{.Config.Image}}' h360-api 2>/dev/null || echo h360tk_grafana_core-demo-h360-api)"
  docker run --rm -u 0 -v "$ROOT/h360_api:/src/h360_api:ro" -w /src -e PYTHONPATH=/src "$image" \
    python -m unittest discover -s h360_api/tests -t /src
}
run_if_present() {
  if [[ -f "$1" ]]; then bash "$1"; else echo "not present: $1 (skipped)"; fi
}
export -f run_h360_api_tests run_if_present
export ROOT

# ------------------------------------------------------------------------------ runner
FAILED=()
SKIPPED=()
N=0
is_skipped() { local s; for s in "${SKIPS[@]+"${SKIPS[@]}"}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

run_check() {
  local name="$1" cmd="$2" log start secs
  N=$((N + 1))
  if is_skipped "$name"; then
    printf '%-34s SKIP\n' "$name"
    SKIPPED+=("$name")
    return 0
  fi
  log="$LOGS/$(printf '%02d' "$N")_$name.log"
  start=$SECONDS
  printf '%-34s ' "$name"
  if bash -c "$cmd" > "$log" 2>&1; then
    secs=$((SECONDS - start))
    printf 'PASS  %3ss  %s\n' "$secs" "$(grep -v '^[[:space:]]*$' "$log" | tail -1 | cut -c1-90)"
  else
    secs=$((SECONDS - start))
    printf 'FAIL  %3ss\n' "$secs"
    echo "----- last lines of $log"
    tail -25 "$log" | sed 's/^/  /'
    echo "-----"
    FAILED+=("$name")
    if (( ! KEEP_GOING )); then
      echo "FAIL verify_all: stopped at $name (log: $log)"
      exit 1
    fi
  fi
}

counts() {
  docker exec -i postgres sh -c 'psql -U "$POSTGRES_USER" -d heart360tk_database -X -qAt' <<'SQL'
SELECT 'patients ' || count(*) FROM heart360tk_schema.patients
UNION ALL SELECT 'encounters ' || count(*) FROM heart360tk_schema.encounters
UNION ALL SELECT 'prescriptions ' || count(*) FROM heart360tk_schema.prescriptions
UNION ALL SELECT 'call_results ' || count(*) FROM heart360tk_schema.call_results;
SQL
}
demo_up_twice() {
  ./scripts/demo_up.sh
  counts > "$LOGS/counts_1.txt"
  echo "after run 1: $(tr '\n' ' ' < "$LOGS/counts_1.txt")"
  ./scripts/demo_up.sh
  counts > "$LOGS/counts_2.txt"
  echo "after run 2: $(tr '\n' ' ' < "$LOGS/counts_2.txt")"
  diff "$LOGS/counts_1.txt" "$LOGS/counts_2.txt" || { echo "row counts changed on the second demo_up.sh"; return 1; }
  echo "row counts equal after two runs: $(tr '\n' ' ' < "$LOGS/counts_2.txt")"
}
export -f counts demo_up_twice
export LOGS

echo "verify_all: PSQL=${PSQL:-<script defaults>}${SHIM:+ (psql shim on PATH)}; logs in $LOGS"
if (( WITH_DEMO_UP )); then
  run_check "demo_up_twice_row_counts" "demo_up_twice"
fi
for c in "${CHECKS[@]}"; do
  run_check "${c%%|*}" "${c#*|}"
done

skipped=""
(( ${#SKIPPED[@]} )) && skipped=" (skipped: ${SKIPPED[*]})"
if (( ${#FAILED[@]} )); then
  echo "FAIL verify_all: ${FAILED[*]}$skipped"
  exit 1
fi
echo "PASS verify_all: $((N - ${#SKIPPED[@]})) checks$skipped"
