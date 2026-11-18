# Review — ad-hoc security lens

Run inline (no subagents in this run).

**Verdict:** the stated hole (Viewer SQL writes through `/api/ds/query`) is closed by privileges, not by `isAllowed`. The remaining exposures are recorded in Deferred and are acceptable on a fake-data laptop demo only.

| Threat | Status |
| --- | --- |
| Viewer writes through any Postgres datasource | Closed. Datasources use roles with no write privilege (AD-14). `default_transaction_read_only` is only a second layer, and the gate tests switching it off (AD-18) |
| Viewer escalates through `grafana_schema."user"` | Closed. `grafana_reader` has column SELECT only |
| Admin escalation through `GrafanaApi` basic-auth datasource | Closed. Deleted, plus `deleteDatasources` |
| New users become org Admin and edit datasources | Closed. `auto_assign_org_role = Viewer` |
| Definer function callable by everyone via PUBLIC | Closed. Global default revoke, explicit grants, allowlist test (AD-15) |
| Search-path hijack in definer functions | Closed. Pinned `search_path` |
| Spoofed identity in a write | Closed. Identity comes only from Grafana's `/api/user` with the forwarded session cookie (AD-16) |
| CSRF from another site | Closed. Custom header and JSON content type force a CORS preflight; Origin allowlist |
| Patient data to Claude | Closed. Facts JSON holds aggregates and place names only (AD-32) |
| Prompt injection changing numbers | Mitigated. Number and banned-word checks, offline fallback, server-appended honesty line |
| Cross-location reads by direct API | Open, accepted (A24). Deferred: RLS or API-mediated reads before real data |
| Compromised `h360-api` can call `save_call_result` with any identity | Accepted for MVP. The role can do nothing else |
| `:5432` exposed, `admin/admin`, passwords in repo | Accepted for local demo; Deferred |
| Aggregated-access teams can write call results | Accepted (mirrors `isAllowed`); Deferred |
