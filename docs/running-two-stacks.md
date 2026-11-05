# Running two HEARTS360 stacks on one machine

Every stack from this repo uses the same host ports and container names by default. Two stacks
(for example the demo and another leaf node) can only run side by side if one of them moves.

## Defaults (stock install)

| Service | Host port | Container |
| --- | --- | --- |
| Grafana | 3000 | `grafana` |
| Postgres | 5432 | `postgres` |
| h360-api | 8090 | `h360-api` |
| pgAdmin | 5050 | `pgadmin` |
| filebrowser | 8080 | `filebrowser-quantum` |

Other containers: `file-upload-trigger`, `db-grants`, `h360tk-exporter`, `h360tk-importer`.

## Move one stack

Add these lines to that checkout's git-ignored `.env`:

```bash
H360_CONTAINER_PREFIX=demo-
GRAFANA_PORT=3100
POSTGRES_PORT=5532
H360_API_PORT=8190
PGADMIN_PORT=5150
FILEBROWSER_PORT=8180
H360_ALLOWED_ORIGINS=http://localhost:3100,http://127.0.0.1:3100
```

Then recreate the stack from that checkout with `docker compose up -d`, or run `./scripts/demo_up.sh`.

The two values that matter:

- **`H360_API_PORT` must equal `GRAFANA_PORT + 5090`.** The chat widget, the Enter stock form and the
  Overdue list save find h360-api at Grafana's port plus 5090 (3000 gives 8090, 3100 gives 8190).
- **`H360_ALLOWED_ORIGINS` must name the new Grafana port.** h360-api refuses browser calls from other
  origins.

How the pieces read these values:

- `docker-compose.yml` reads every value above, with the stock values as defaults.
- The scripts read them through `scripts/h360_env.sh`. That covers `demo_up.sh`, `demo_users.sh`
  and the `verify_*` scripts. It exports `GRAFANA_URL`, `H360_API_URL`, `H360_ORIGIN` and
  `H360_PG_CONTAINER`.
- Compose services still reach each other by service name (`postgres`, `grafana`), so nothing inside
  the stack changes.

## Revert to the original ports

1. Delete the lines above from `.env`.
2. Stop the other stack if it holds 3000, 5432, 8090, 5050 or 8080.
3. From this checkout, run `docker compose up -d` (or `./scripts/demo_up.sh`).

Compose recreates the containers with the stock names and ports. Database data lives in the
postgres container's volume. If the volume is not carried over to the renamed container, run
`./scripts/demo_up.sh`; it reloads the demo data and is safe to re-run.

## Current use

On 2026-11-05 the `h360tk_grafana_core-demo` worktree (branch `cursor/hearts360-mvp-7579`) was moved
to the values above, so the owner could run another leaf node on the stock ports. The demo is at
http://localhost:3100.
