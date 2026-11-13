# Review — rubric walker (good-spine checklist)

Run inline and sequentially: this headless subagent run may not spawn subagents. That means it lacks the independent context the gate prefers. Findings were applied in the same pass.

**Verdict:** pass after fixes. The spine fixes the divergence points for the level below. Every AD carries Binds / Prevents / Rule, and lint reports 0 findings.

## Checklist

| Check | Result |
| --- | --- |
| Real divergence points fixed for units one level down | Yes: migration chain ownership, grant matrix, report contract, window, classifier, chat shapes, seed ownership |
| Every Rule enforceable | Yes. Each rule has a named verify script or a checkable artifact (`check_htn_dm_untouched.py`, `build_reports_dashboard.py --check`, `verify_security.sh`, per-rule fixtures) |
| Deferred cannot let units diverge | Yes: Deferred items are out of scope for this build (RLS, pinning, plugin port, real data) |
| Named tech verified current | See `review-verification.md` |
| Ratifies brownfield | Yes: keeps datasource uids, `isAllowed` SQL, `get_descendant_ids`, `-dtab` deep links, `demo_up.sh` seed hook, `drug_stock_pull_apply` |
| Covers the spec | FR-15 to FR-49 and NFR-1 to NFR-9 mapped |
| Parent ADs not weakened | AD-5 and AD-8 superseded explicitly; AD-4 clause made true; the rest kept |
| Operational envelope | Deploy envelope, compose services, env vars, logging, secrets and the demo entry point covered |

## Findings and resolution

1. **High.** Upgrade/verify order was "name order", but lexical order puts `0.6.10` before `0.6.2`. Fixed: AD-13 now says version order = the `\ir` list.
2. **High.** `0.6.5_to_0.6.6` needs superuser for `CREATE ROLE` / `ALTER ROLE SET`, but AD-13 required `SET ROLE heart360tk`. Fixed: AD-14 now starts that file with `RESET ROLE`.
3. **High.** Adherence strict/lenient used `patients.registration_date`, but the reverse-engineered tool uses the earliest visit (they differ for 2333 demo patients). Fixed in CR-2 and the companion fixture.
4. **Medium.** `grafana.ini` path was wrong (`grafana_provisioning/config/grafana.ini`). Fixed.
5. **Medium.** AD-27's standard columns did not fit the selection-only and patient-list functions. Exception stated.
6. **Medium.** NFR-2, NFR-4, NFR-5, NFR-7 and NFR-8 were missing from the capability map. Added.
7. **Low.** The logging and `.env.example` conventions were missing. Added.
