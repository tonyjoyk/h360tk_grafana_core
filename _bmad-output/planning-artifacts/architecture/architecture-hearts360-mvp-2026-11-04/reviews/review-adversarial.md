# Review — adversary: two compliant units that still build incompatibly

Run inline (no subagents in this run).

**Verdict:** pass after fixes. Nine incompatible pairs were found and closed. No open pair remains that the spine's level owns.

| # | Pair (both obey every AD) | Clash | Fix |
| --- | --- | --- | --- |
| 1 | Chat API unit and chat widget unit | Undefined `reasons` / `plan` / `place` shapes | AD-30 fixes every field |
| 2 | Report-common unit and the five report units | `report_flags` in `0.6.8_to_0.6.9` would reference functions created later (SQL bodies validate at create time) | `report_flags` moved to `0.6.13_to_0.6.14`; tab units depend on U12 |
| 3 | Security migration unit and the `h360-api` compose unit | Different literal passwords for the new roles | Conventions fix the MVP literals |
| 4 | Security unit and write-path unit | Unclear owner of `save_call_result` / `h360_access_allows` / audit table | All in `0.6.5_to_0.6.6`, owned by U2 |
| 5 | Write-path unit and the existing overdue list | Different allowed status strings | AD-16 lists the 11 strings |
| 6 | Widget on the drug stock board and the Reports tabs | The board's `reporting_month` defaults to the current month, so chat numbers would not match Reports | The widget sends the month only on `heart360_reports` |
| 7 | Tab JSON unit and adherence SQL unit | `include_new` variable values vs the function parameter | AD-28 fixes `false` / `true` |
| 8 | Calling SQL unit and the seed unit | Returns for month M can never be "known" on data ending 2026-10-13, so the tab would show nothing | CR-6 measures returns over window calls with completed follow-up |
| 9 | Report units and verify fixtures | Small fixtures fall under the A37 minimums and could return NULL measures | The companion states measures are always computed; `too_few` only switches display |

Also checked, no clash:
- Two owners of `docker-compose.yml`: U2 and U3 are sequential.
- Program dashboard: one owner (U3) for the save path and the link.
- `01_heart360_tables.sql`: U1 only.
- Seeds vs migrations: seeds only insert, and drug stock goes through `drug_stock_pull_apply`.
- Chat numbers vs tabs: the same `report_*` functions, and the same scope node in links.
