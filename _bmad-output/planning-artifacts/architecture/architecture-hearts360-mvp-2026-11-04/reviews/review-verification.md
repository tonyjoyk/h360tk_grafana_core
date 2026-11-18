# Review — every committed decision web-researched or reality-checked

Run inline (no subagents in this run).

**Verdict:** pass after one design change. One decision rested on an unverified plugin behaviour, and checking it disproved it.

| Decision | How it was checked | Result |
| --- | --- | --- |
| Grafana 13.3.0 | `grafana server -v` in the running container | Confirmed |
| `index.html` injection | grep in container: one `</body>`, `nonce="[[.Nonce]]"`, `grafanaBootData`, `isSignedIn` in the bundle | Confirmed |
| Tab deep links `-dtab=` | Grafana PR 123159 and TabsLayoutManager tests (`dtab` key; nested key `<row>-dtab`); repo `home.json` uses `-dtab=Hypertension` | Confirmed |
| Infinity `keepCookies` forwarding `grafana_session` | Infinity PR 1258 discussion and Grafana `cookies_middleware.go` (login cookie is in `skipCookiesNames`) | **Disproved.** AD-17 changed: `panel-ov-1` becomes read-only (A59) |
| `ALTER DEFAULT PRIVILEGES` revoke from PUBLIC | PostgreSQL 18 docs: per-schema defaults cannot revoke the global default | Confirmed; AD-15 uses the global form |
| Python deps (FastAPI 0.162.0, uvicorn 0.54.0, psycopg 3.3.6, httpx 0.28.1, anthropic 2.4.0) and model ids | Web lookup during grounding (2026-11-04) | Confirmed at authoring |
| Plugin versions | `plugin.json` in the container: tree 1.7.7, Business Text 6.3.1, ECharts 7.3.0, Business Table 3.6.9 | Recorded; the Dockerfile installs unpinned (Deferred) |
| Session cookie reaches `:8090` | Cookies are not port-scoped; `SameSite=Lax` and same-site across ports | Reasoned from the cookie spec, not exercised. `verify_security.sh` exercises it |
| `get_descendant_ids` semantics | Live query: includes self, 0 = all, no pinned search path | Confirmed; AD-15 notes it |
| Demo data facts (levels, dates, SBP gaps, empty tables) | Live read-only queries | Confirmed |

Still unverified (accepted, with a test named): the h360-api session check against `/api/user/teams` with a forwarded cookie, covered by `verify_security.sh`. Grafana's CSP is off by default in `grafana.ini`, covered by the browser check in the verification swarm.
