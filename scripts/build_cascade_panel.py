#!/usr/bin/env python3
"""Write the screening and treatment cascades into the Hypertension tab (story 14.3).

Sources (dashboard_src/cascade/):
  cascade.js   drawing code and the per-country config (COUNTRIES, ACTIVE)
  cascade.css  styles, prefix csc-
  panel.sql    the panel query: one row of numbers

Output: element panel-stc in the program dashboard, and the place and size of panel-stc and panel-1
in the Overview indicators row (LAYOUT). Nothing else in the file changes.

  python3 scripts/build_cascade_panel.py          # write
  python3 scripts/build_cascade_panel.py --check  # exit 1 if the dashboard is stale

After a change, re-pin panel-stc in scripts/check_htn_dm_untouched.py (--print-hashes).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "dashboard_src" / "cascade"
DASHBOARD = ROOT / "grafana_provisioning" / "dashboards" / "HEARTS360 Dashboards" / "heart360.hypertension-diabetes.program.json"
SQL = SRC / "panel.sql"
ELEMENT = "panel-stc"
# Overview indicators row, as in the baseline: the cascades take 2 of 3 columns, "Patients
# protected" (panel-1) the third. The compact card (DESIGN.md) fits this.
LAYOUT = {
    "panel-stc": {"x": 0, "y": 0, "width": 16, "height": 9},
    "panel-1": {"x": 16, "y": 0, "width": 8, "height": 9},
}

# No panel title: the two charts carry their own titles, and the header row is space the card needs.
TITLE = ""
DESCRIPTION = (
    "Screening cascade: adults screened this year, from eligible to newly diagnosed with hypertension. "
    "Each percent above a bar is a share of the first bar. The grey line under a bar is the share of the step before it. "
    "Steps 1 to 3 come from CKG. Newly diagnosed counts new I10 registrations in puskesmas EHR data, a different system, "
    "so that bar has no step rate. Targets are for the full year. "
    "Treatment cascade: estimated adults with hypertension, then registered, under care and BP controlled. "
    "Each percent is a share of the estimate. Under care means at least one visit in the last 12 months. "
    "BP controlled means below 140/90 at the last visit. "
    "Both charts use the location you picked and the latest completed month. "
    "Population, prevalence and screening counts are example data, not program data."
)

AFTER_RENDER_TAIL = r"""
// Hypertension tab, panel-stc: one row of numbers from dashboard_src/cascade/panel.sql.
const root = context.element.querySelector('.csc-root');
if (!root) { return; }
const series = (context.panelData && context.panelData.series) || [];
const frame = series.find((s) => s.refId === 'A') || series[0];
const row = frame && frame.fields.length && frame.fields[0].values.length
  ? Object.fromEntries(frame.fields.map((f) => [f.name, Array.from(f.values)[0]])) : null;
if (!row) {
  const state = context.panelData && context.panelData.state;
  root.innerHTML = '<div class="csc-note">' + (state === 'Loading' ? 'Loading the cascades…' : 'No data for this place.') + '</div>';
  return;
}
cascade.draw(root, row);
"""


def render(dashboard: dict) -> dict:
    js = (SRC / "cascade.js").read_text().rstrip("\n")
    css = (SRC / "cascade.css").read_text().rstrip("\n")
    sql = "\n".join(line for line in SQL.read_text().splitlines() if not line.startswith("--")).strip()
    element = dashboard["spec"]["elements"][ELEMENT]
    spec = element["spec"]
    spec["title"] = TITLE
    spec["description"] = DESCRIPTION
    query = spec["data"]["spec"]["queries"][0]["spec"]["query"]
    query["datasource"] = {"name": "postgres-hypertension-cached"}
    query["spec"]["rawSql"] = sql
    options = spec["vizConfig"]["spec"]["options"]
    options["content"] = options["defaultContent"] = '<div class="csc csc-flat csc-root"></div>'
    options["afterRender"] = js + "\n" + AFTER_RENDER_TAIL.lstrip("\n")
    options["styles"] = css
    options["editors"] = ["styles", "afterRender"]
    options["renderMode"] = "allRows"
    found = 0
    for row in dashboard["spec"]["layout"]["spec"]["rows"]:
        for tab in row["spec"]["layout"]["spec"].get("tabs", []):
            for trow in tab["spec"]["layout"]["spec"].get("rows", []):
                items = trow["spec"]["layout"]["spec"].get("items", [])
                if any(i["spec"]["element"]["name"] == ELEMENT for i in items):
                    for item in items:
                        item["spec"].update(LAYOUT.get(item["spec"]["element"]["name"], {}))
                        found += 1
    if not found:
        raise SystemExit(f"{ELEMENT} is not in any layout row")
    return dashboard


def main(argv: list[str]) -> int:
    # --dashboard PATH and --sql PATH write the card into another checkout (for example H360-321
    # with dashboard_src/cascade/panel_placeholder.sql). Defaults: this branch.
    global DASHBOARD, SQL
    if "--dashboard" in argv:
        DASHBOARD = Path(argv[argv.index("--dashboard") + 1]).resolve()
    if "--sql" in argv:
        SQL = Path(argv[argv.index("--sql") + 1]).resolve()
    text = DASHBOARD.read_text()
    out = json.dumps(render(json.loads(text)), indent=2, ensure_ascii=True) + "\n"
    if "--check" in argv:
        if out != text:
            print(f"stale: {DASHBOARD} (run scripts/build_cascade_panel.py)")
            return 1
        print(f"ok: {DASHBOARD} is up to date")
        return 0
    DASHBOARD.write_text(out)
    print(f"wrote {ELEMENT} in {DASHBOARD}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
