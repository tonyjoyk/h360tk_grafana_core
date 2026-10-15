# Central aggregate verification map

This directory is the maintained source for verifying direct EHR aggregate JSON on the central node. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Grafana is on `http://localhost:3000` with user `admin` and password `admin`.
- Postgres service name is `postgres`, database `heart360tk_database`, user `heart360tk`.
- The importer container is `h360tk-importer` on network `h360tk_grafana_core_default`.
- Compose project name is `h360tk_grafana_core`.
- Org units in the demo database: `1` Demo Region, `2` AUDIT_DIST, `3` H360_AUDIT_PHC.
- Scenario fixtures live in `test_data/aggregate_scenarios/`.
- Do not run a scenario test against the live dashboard rows without a rollback. `importer_scripts/test_aggregate_scenarios.py` rolls back.

## Driving conventions

- Start from the baseline unless a feature says otherwise.
- Prove a JSON import by the rows in `heart360tk_reporting`, then by the Grafana panel that reads those rows.
- The dashboard time range must include the `ref_month` values in the file. The big numbers are the latest month inside that range.

## Proof and skip reporting

- Capture the file that was imported and the reporting-table row it produced.
- UI proof includes the panel title and the number on screen.
- Record the feature ID with every artifact.
- Report an unreachable path with the command that failed.

## Features

- [Send aggregate JSON to the central node](./central-aggregate-json.md) covers a file drop, month placement, partial counts, diabetes fan-out, and the dashboard result.
