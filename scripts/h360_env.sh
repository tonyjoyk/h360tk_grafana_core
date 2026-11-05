# Source this file from bash (not zsh) to get this checkout's ports and container names.
#
# Two stacks can run side by side (for example a demo and another leaf node) when one of them sets,
# in its git-ignored .env:
#   H360_CONTAINER_PREFIX=demo-   GRAFANA_PORT=3100   POSTGRES_PORT=5532
#   H360_API_PORT=8190            PGADMIN_PORT=5150   FILEBROWSER_PORT=8180
#   H360_ALLOWED_ORIGINS=http://localhost:3100,http://127.0.0.1:3100
# docker compose reads the same .env. Browser code finds h360-api at Grafana's port + 5090.
# Values already in the environment win over .env. Defaults match a stock install.

_h360_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$_h360_root/.env" ]]; then
    while IFS='=' read -r _k _v; do
        [[ -z "${!_k:-}" ]] && export "$_k=$_v"
    done < <(grep -E '^(H360_CONTAINER_PREFIX|GRAFANA_PORT|POSTGRES_PORT|H360_API_PORT|PGADMIN_PORT|FILEBROWSER_PORT)=' "$_h360_root/.env")
fi
unset _k _v

export H360_CONTAINER_PREFIX="${H360_CONTAINER_PREFIX:-}"
export H360_PG_CONTAINER="${H360_CONTAINER_PREFIX}postgres"
export GRAFANA_URL="${GRAFANA_URL:-http://localhost:${GRAFANA_PORT:-3000}}"
export H360_API_URL="${H360_API_URL:-http://localhost:${H360_API_PORT:-8090}}"
export H360_ORIGIN="${H360_ORIGIN:-$GRAFANA_URL}"
# Scripts that connect from the host (verify_dashboard_queries.py and others) default to
# localhost:5432, which may belong to another stack. Point them at this checkout's database.
export DATABASE_URL="${DATABASE_URL:-postgres://h360tk_root:NGE5ZjljYjM1ZWEyNDI5N2I0YmZiZGM0@localhost:${POSTGRES_PORT:-5432}/heart360tk_database}"
