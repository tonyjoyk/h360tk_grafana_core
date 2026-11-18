# Hypertension cascades: design decisions and data needs

**For:** HEARTS360 team · **Status:** draft for review · **Updated:** Nov. 17, 2026, after the Nov. 13 call with Chetan Kaanadka · **Owner:** Tony Joy

**Files**
- `HTN_Cascades_Indonesia_India_Ethiopia.html`: the shared design for three countries
- `HTN_DM_Screening_Cascade_Prototype_V1_4.html`: the India prototype, restyled for HEARTS360
- `HTN_DM_Screening_Cascade_Prototype_V1_5.html`: the India prototype, original design with a usability pass
- Turn on **Show design notes** in either file to see each numbered note on the chart it explains
- Open **Enter data for [country]** under each chart in the three-country file to change names, counts and targets
- `HTN_Cascade_Data.md`: the data file the three-country page reads and writes. Keep it in your Obsidian vault

## Summary

Every country gets one dashboard section with two charts side by side. The left chart tracks screening this year. The right chart tracks everyone ever put on treatment.

The screening chart has the same five slots in every country: **eligible, screened, raised BP, a facility step, then diagnosed with hypertension.** The facility step is optional and means something a little different in each country, so it can be hidden. Only the names, the base, the data source and the target change. A new country fills in one config table. It doesn't need a new design.

All values in both files are examples, not programme data.

## What changed after the call with Chetan

Chetan built the original India prototype. He focused on the logic, not the design or copy, and welcomed design help. The call settled five things.

| # | What we learned | What changes in the shared design |
|---|---|---|
| 1 | People already on treatment are left out of India's base on purpose. They don't need hypertension screening. The year target is fixed on 1 April and doesn't move as more people start treatment. | India's base is "Adults 30+ not on treatment," set on 1 April. Note 10 updated. |
| 2 | India's state reports add screening and examined. Chetan's mock also took away people referred from screening. Many people examined at a facility were already screened but not referred, or walked in. So both formulas can count the same person twice. | Screened uses the reported screening count only. Examined becomes its own bar, set apart. Notes 21 and 22. |
| 3 | In some states more people are examined than referred. People go straight to the PHC, or get checked during an OPD visit for something else. | Referred isn't shown. It isn't a clean step between screened and examined. |
| 4 | The "remaining screened adults" block isn't a gap. Most of it is people with normal BP, plus pending exams and records not yet synced. Chetan agreed. | The last bar is now "Diagnosed with hypertension" in every country. A diagnosis goal line replaces the false gap. Notes 20 and 23. |
| 5 | The gap block on screening performance was there to show "do we need to speed up?" | That message is now one line under the screened count: how far behind or ahead of this month's target. Note 24. |

Chetan also pointed out that India's current Power BI dashboard looks like a cascade but mixes annual and cumulative numbers. That backs the split we already use: screening this year on the left, every registered patient on the right.

### The diagnosis goal

Agreed in principle on the call:

**Diagnosis goal for the year = estimated adults with hypertension − adults already on treatment**

India spreads it by month, like the screening target. Indonesia shows it as a year goal, to match its screening target. Ethiopia doesn't use it, because its base is OPD visits, not population. Next step: work out the formula with Chetan using real Odisha numbers.

### Naming the last bar

"Diagnosed with hypertension" is the default, because every country counts diagnosis the same way. Other names that work, by country:

| Country | What the count is | Name options |
|---|---|---|
| Indonesia | New I10 registrations in puskesmas EHR | Diagnosed with hypertension · Newly diagnosed · New I10 diagnoses |
| India | NP-NCD new cases diagnosed | Diagnosed with hypertension · Newly diagnosed · Confirmed by doctor |
| Ethiopia | New entries in the HTN register | Diagnosed with hypertension · Newly registered · Newly diagnosed |

Avoid "Started treatment." India counts it separately, and in Ethiopia some people start with lifestyle changes. Avoid "Confirmed" alone, since it doesn't say confirmed as what.

To rename a bar, turn on **Edit bar names**, click the name and type. Press Enter to save. Names are saved in your browser per country. **Copy names as config** gives engineering the names in one block. **Reset names** goes back to the defaults.

## The five-slot standard

Each country's screening chart fills the same five slots. The name on each bar can differ. The meaning of the slot can't.

| Slot | Means | India | Indonesia | Ethiopia |
|---|---|---|---|---|
| 1 Eligible | Who the target is set against | Eligible for screening (adults 30+ not on treatment, set on 1 April) | Eligible for screening (adults 15+) | Adult OPD visits without known HTN |
| 2 Screened | BP measured this year | Screened (screening count only) | Screened (CKG) | BP measured |
| 3 Raised BP | Screened with a reading at or above 140/90 | Referred (raised BP) | Raised BP | Raised BP |
| 4 Facility step, optional | Seen by a doctor or clinic after raised BP | Examined by MO, **set apart**, includes walk-ins | Given starter medicine, **only if CKG reports it** | Linked to NCD clinic |
| 5 Diagnosed | Newly diagnosed with hypertension this year | Diagnosed with HTN (NP-NCD) | Diagnosed with HTN (new I10 in EHR), **set apart** | Diagnosed with HTN (HTN register) |

Rules for the slots:
- **Slots 1 to 3 are a true funnel everywhere.** Each is a subset of the one before.
- **Slot 4 is a funnel only in Ethiopia.** In India, examined includes walk-ins and OPD checks, so it can be bigger than referred. It sits apart and shows no "% of referred." In Indonesia, starter medicine is given only in community CKG, so it isn't the same as referral.
- **Slot 5 sits apart when it comes from another system** (Indonesia's EHR) or follows a step that isn't a subset (India).
- **Use one term in the meaning:** raised BP. India keeps "Referred" in the label because that's the word on its reports.
- **A warning shows** when a step is bigger than the one before it, or bigger than the base. It points to a data or definition problem, not a design one.

### Is Indonesia's referral the same as starter medicine?

No. They overlap but they aren't the same group.
- Starter medicine is given at community CKG posts only. People screened inside a puskesmas go straight to a full month of medicine and an I10 diagnosis.
- Not everyone referred gets starter medicine. Spot checks found 43% to 62% did.
- The number of days has been described as both 5 to 10 days and 2 weeks. Leave days out of the label.

Show "Given starter medicine" only if CKG reports it as an aggregate. If it doesn't, hide slot 4 for Indonesia.

## Entering data and saving to Markdown

Each country has an **Enter data for [country]** panel under its chart. You can change every bar name, count and target %, the period, the target month, the treatment date, the age group and the four treatment counts. The chart redraws as you type.

Where the data is saved:
- **In this browser**, every time, as a backup.
- **In a Markdown file**, when you link one. Use **Open .md file** or **Create .md file**. After that, every change is written to the file within half a second. This works in Chrome and Edge only.
- **Download .md** and **Load .md** do the same job by hand in any browser.

Using it with Obsidian:
- Obsidian shows the file but can't run the dashboard. Open the HTML page in Chrome or Edge, then link the `.md` file inside your vault.
- Browsers forget the link when the page closes. Click **Open .md file** again each session.
- The numbers live in the file's **properties** at the top, for example `ind_screened: 984000` or `idn_linked_label: "Given starter medicine"`. Obsidian's Properties view and Dataview can read them.
- You can edit the properties in Obsidian, then click **Load .md** in the page to pull them in.
- The tables under the properties are rebuilt on every save. Edits to the tables are not read back.

Property names follow one pattern: `{country}_{slot}`, `{country}_{slot}_label` and `{country}_{slot}_target_pct`. Country codes are `ind`, `idn` and `eth`. Slots are `eligible`, `screened`, `raised`, `linked` and `diagnosed`. Treatment counts are `{country}_t_estimated`, `_t_registered`, `_t_undercare` and `_t_controlled`. The file must keep `type: hypertension-cascade-data`, or the page won't load it.

## Why we made each choice

Numbers match the markers in the HTML files.

### Shared across all countries

**1. One section.** Screening and treatment sit in one card. Ministry feedback was that the two charts should read as one story.

**2. Time period under each title.** Screening counts this year only. Treatment counts every patient ever registered. The line under each title stops readers mixing them up. The year fills in by itself, for example "This year: Jan to Nov 2026."

**3. Same steps everywhere.** Eligible, screened, raised BP where a country records it, then diagnosed with hypertension. Each country fills one config table instead of getting a new design.

**4. Each half reads against its own first bar.** Bar heights and big percentages are a share of the first bar, so the y-axis stays true. The small grey text under each count is the step rate, or the gap to this month's target.

**5. Denominator in the subtitle.** This is HEARTS360 practice. Readers see the base before they read the bars, for example "Of 2,100,000 adults aged 15+..."

**6. Raised BP, not suspected.** It's one reading at or above 140/90. The label says what was measured, not what it might mean. Indonesia can switch to "suspected" if the ministry insists.

**7. No split bars.** The India mock stacked two numbers in each pillar. Each part already has a home here: the target is a line on the screened bar, and people on treatment show in the treatment cascade.

**8. Base follows the official target.** If our base differs from the ministry's, our numbers won't match their reports and they'll stop trusting the dashboard.

### India

**9. India: diagnosed, not started treatment.** NP-NCD reports diagnosed and on treatment as separate counts. Nationally the gap is about 8% (5.13 crore diagnosed, 4.74 crore on treatment). The last bar now uses diagnosed, the same as Indonesia and Ethiopia.

**10. India: base set on 1 April.** People already on treatment don't need hypertension screening, so the base leaves them out. The year target is fixed on 1 April. It doesn't change as more people start treatment. Chetan confirmed this is intended. Still check that Odisha's own report uses the same base.

What we found in the guidelines:
- Known patients follow a separate track. Health workers follow them up for treatment, not rescreen them for the same disease.
- But the targets count everyone. The MoHFW planning deck asks for yearly BP screening of all 370 adults 30+ in a village of 1,000. Assam's guideline fills the risk checklist for every adult 30+ each year.
- Screening is per disease. A hypertension patient still needs diabetes screening once or twice a year.

So the exclusion is sound public health thinking, but it isn't national policy. Chetan confirmed it's intended for the India dashboard. If Odisha reports against all adults 30+, add a note so state staff know why our number differs.

**11. India: titles kept, subtitles added.** Staying close to the current template makes approval faster. Each subtitle says what the pillar answers:

| Title (kept) | Subtitle (new) |
|---|---|
| Treatment status | Who is already on treatment |
| Screening target | How many to screen by now |
| Screening performance | How many were screened |
| Screening outcomes | How many started treatment |

### Indonesia

**12. Indonesia: diagnosed sits apart.** It comes from the puskesmas EHR, not CKG, so it isn't a true subset of raised BP. Filter CKG to the same puskesmas before comparing. The bar has a dashed divider and a hatched fill so it reads as a different source.

### Ethiopia

**13. Ethiopia: base is OPD visits.** Screening happens at the facility. Counts are visits, not people, so one person can count twice.

**14. Ethiopia: one outcome bar.** Seeing a clinician and registering merge into diagnosed with hypertension. Some drop after raised BP is the protocol at work. The national protocol starts treatment the same day only at 160/100 or higher. Between 140/90 and 159/99, it rechecks on another day, or tries lifestyle changes first.

### Added after the call with Chetan

**20. Last bar: diagnosed with hypertension.** Every country counts diagnosis reliably: new I10 registrations in Indonesia, NP-NCD diagnosed in India, new HTN register entries in Ethiopia. The name can be changed per country.

**21. India: screened means the screening count.** The state adds screening and examined. The mock also took away people referred from screening. Both can count people twice, because many people examined at a facility were already screened but not referred. Screened now uses the reported screening count only.

**22. India: examined sits apart.** Facility exams include walk-ins and OPD checks, so examined isn't a subset of screened. Diagnosed is shown as a share of examined. A **Show examined** tick box hides the bar. When it's hidden, diagnosed says "Includes walk-ins" instead.

**23. Diagnosis goal.** Estimated adults with hypertension, minus those already on treatment, gives the number still to diagnose. It's drawn as a dashed line on the diagnosed bar.

**24. Behind or ahead of target.** The gap block in the India mock showed whether the programme needs to speed up. That's now one line under the count, for example "109,880 behind Nov target."

### Added for the five-slot standard

**25. Five slots, names by country.** Every country fills the same five slots. The meaning is fixed and the label is free. That lets one chart serve three countries without hiding real differences.

**26. Slot 4 is optional.** A **Show** tick box hides it per country. When it's hidden, slot 5 reads as a share of slot 3, or says "Includes walk-ins" for India.

**27. Indonesia: starter medicine is not referral.** Starter medicine is community CKG only, and not everyone referred gets it. Label it as what it is, or hide it.

**28. Data lives in a Markdown file.** Numbers are saved as properties in a `.md` file so they can sit in an Obsidian vault and be read by Dataview. The browser copy is a backup only.

### India prototype file only

**15. Reviewer tools stay visible.** Data checks, scenario inputs, programme assumptions, the 12-month table, the data contract and the exports let reviewers test the logic. They keep their original place and names. An earlier draft hid them in a closed panel. That was a mistake: hidden tools don't get used.

**16. Plain labels.** Terms like FYTD and SC-11 stay in the data table and contract, not in what people read first.

**17. One color family per pillar.** The darker shade is the number to watch. The lighter shade is the rest of the pillar.

**18. Official report wins.** When the dashboard's treatment count differs from the official report, the report is used. This logic is unchanged.

**19. Labels never overlap.** When a segment is too small to hold its number, the number moves above the pillar with a color swatch. Labels stack with fixed spacing, and any segment above zero is at least 3px tall. Tested across all 144 views (2 conditions, 2 years, 12 months, 3 scenarios): no overlaps, no clipped labels, and every data check still passes. The original file had label problems in 77 of those views.

## India prototype V1.5: a usability pass on the original

**File:** `HTN_DM_Screening_Cascade_Prototype_V1_5.html`

V1.5 keeps the original V1.3.5 design: same header, colors, four pillars, names and order. It's a usability pass, not a redesign. Use it for review with the author of the original. Turn on **What changed in V1.5** in the header to see each change in place.

What changed:
1. **Numbers moved into the bars.** The five number tiles repeated the bar values. Each number now appears once, inside or next to its segment, with a short label.
2. **Legend cards removed.** They repeated the bars too. Their two info notes stay below the chart.
3. **One headline number per pillar,** under its name: adults aged 30+, the year target, the share of this month's target screened, and the share of screened adults who started treatment.
4. **Monthly target explained.** Dark red now reads "due by September." Light red reads "rest of the year."
5. **Gaps drawn as dotted outlines.** "Still to screen" and "no treatment yet" keep their place and numbers, but no longer compete with the main numbers.
6. **Small numbers never overlap.** Tested across all 144 views. The original had label problems in 77.
7. **Everything else unchanged:** calculations, data checks, inputs, assumptions, the 12-month table, the data contract and the exports.

Open for the meeting: the "no treatment yet" group is mostly people with normal BP. V1.5 keeps it, de-emphasized, and explains it in an info note. Whether to replace it with a suspected-to-diagnosed step is a question for the program team (see the critique file, notes 11 and 12).

## What changes by country

| | Indonesia | India | Ethiopia |
|---|---|---|---|
| Base | Adults 15+ | Adults 30+ not on treatment, set on 1 April | Adult OPD visits without known hypertension |
| Unit | People | People | Visits |
| Period | Jan to Dec | Apr to Mar | Ethiopian fiscal year |
| Target | Annual line (to confirm) | Pro-rated to the month | Annual line, set by the Ethiopia team |
| Raised BP | From CKG | Referred (raised BP), NP-NCD | From facility records |
| Slot 4, optional | Given starter medicine, if CKG reports it | Examined by MO, set apart | Linked to NCD clinic |
| Diagnosed with hypertension | New I10 registrations, EHR | New cases diagnosed, NP-NCD | New HTN register entries |
| Diagnosis goal | Year goal (proposed) | Due by month | Not used |
| Bars set apart | Diagnosed | Examined and diagnosed | None |
| Can slot 4 exceed slot 3? | No | Yes, walk-ins | No |

To add a country, fill in this table. The chart code reads it as config.

## Loading the data into Grafana

Data falls into three groups, by how often it changes.

| Group | Fields | How it gets in | Who does it |
|---|---|---|---|
| Yearly load | Adult population by age group and org unit. Estimated adults with hypertension. Screening target. | One CSV upload per year, stored in the database | Country admin |
| Monthly upload | Screened, raised BP or examined, diagnosed. Year-to-date counts by org unit and month. | One aggregate CSV per month | Country data team |
| Already in HEARTS360 | Registered, under care, BP controlled | No change | Automatic |

Rules for the monthly file:
- One row per org unit per month, with org unit codes, not names.
- Counts are year to date, so each month's file replaces the last.
- The chart treats a missing month as "no data," not zero.

### Indonesia

| Field | Source | Level | How often |
|---|---|---|---|
| Adults 15+ | Pusdatin or BPS estimate | Puskesmas | Yearly |
| Estimated adults with hypertension | Prevalence × population (use the SPM figure) | Puskesmas | Yearly |
| Screening target | Ministry | National or district | Yearly |
| Adults screened (BP measured) | CKG aggregate | Puskesmas | Monthly |
| Adults with raised BP | CKG aggregate | Puskesmas | Monthly |
| New I10 registrations this year | EHR aggregate | Puskesmas | Monthly |

Watch out for:
- Filter CKG to the puskesmas that send EHR data. Otherwise diagnosed looks far too low.
- Walk-ins diagnosed in the regular clinic show in registrations but not in CKG. Registrations can run high.
- CKG's 130 million target covers all ages. Confirm the adult target before showing a line.

### India

| Field | Source | Level | How often |
|---|---|---|---|
| Adults 30+ | State population estimate | District or block | Yearly |
| Adults on HTN treatment on 1 April | NP-NCD cumulative report | District or block | Yearly, frozen on 1 April |
| Estimated adults with hypertension | Prevalence × population | District or block | Yearly |
| Annual screening target | State plan | State | Yearly |
| Adults screened for HTN, year to date | NP-NCD screening report (screening count only) | District or block | Monthly |
| Adults examined for HTN, year to date | NP-NCD report | District or block | Monthly |
| New HTN cases diagnosed, year to date | NP-NCD report | District or block | Monthly |

Watch out for:
- Don't add examined to screened, and don't take referred away. Load each count as reported.
- The year resets on April 1. The base and target are frozen then. Treatment numbers carry forward.
- Referred from screening is reported, but isn't loaded for this chart.

### Ethiopia

| Field | Source | Level | How often |
|---|---|---|---|
| Estimated adults with hypertension | Prevalence × catchment population | Facility or woreda | Yearly |
| Screening target (% of visits) | Ethiopia team | National | Yearly |
| Adult OPD visits without known HTN | Facility register or DHIS2 | Facility | Monthly |
| Visits with BP measured | Facility register | Facility | Monthly |
| Visits with raised BP | Facility register | Facility | Monthly |
| New HTN registrations | HTN register | Facility | Monthly |

Watch out for:
- Counts are visits. Say so in the info icon.
- Confirm the age cutoff. The protocol says 30+. Some programmes screen from 18.

## Visual design

- **Colors** follow the HEARTS360 dashboard: blue for diagnosed and registered, purple for under care, green for BP controlled, red for raised BP. Screened is indigo. Examined is teal, so it reads as its own step.
- **Targets** are dashed lines in the color of the bar they belong to, with a light tint up to the line.
- **Corners** are small: 6px on cards, 2px on bars.
- **Numbers** sit under each bar in the bar's color. Percentages sit inside the bar when it's tall enough, above it when it isn't.
- **Phones:** the India pillar chart scrolls sideways instead of shrinking, and info tooltips stay on screen.

## How to test before sharing widely

Run a 30-minute session with 5 people from the India program team or state NCD cells, using the India prototype. Ask them to:

1. Say whether Odisha is on track for screening this month.
2. Find how many adults still need screening this year.
3. Find how many people were diagnosed with hypertension this year, and whether that's on track.

Success: 4 of 5 people answer each task in under a minute without help. Then ask: "Should people already on treatment count in the screening target?"

## Open questions

| # | Question | Who answers | Blocks build? |
|---|---|---|---|
| 1 | Does Odisha's own report count all adults 30+, or only those not on treatment? Chetan's design leaves out people on treatment. | India program team | No, but add a note if they differ |
| 2 | Will the state accept screened as the screening count only, without adding examined? | India program team, with Chetan | Yes, for India |
| 7 | What prevalence and month spread should the India diagnosis goal use? | Chetan | No, hide the line until agreed |
| 8 | Is a diagnosis goal useful for Indonesia, or only for India? | Indonesia team | No |
| 3 | What is Indonesia's official adult screening target? | Kemenkes | No, hide the line until known |
| 4 | Does CKG count unique people or visits, and at puskesmas level with matching codes? | Pusdatin | Yes, for Indonesia |
| 5 | Ethiopia: 18+ or 30+? | Ethiopia team | No |
| 6 | Who signs off the target shown on each dashboard? | Each country lead | Yes |
| 9 | Does CKG report referrals or starter medicine as an aggregate count, by puskesmas? | Pusdatin | Yes, for Indonesia slot 4 |
| 10 | Is "linked to NCD clinic" its own field in Ethiopia's register, or inferred from the HTN register? | Ethiopia team | Yes, for Ethiopia slot 4 |
| 11 | In India, by state, how often is examined bigger than referred? If it's common, should slot 4 be "seen at facility" with no link to referral? | Chetan, with state data | No |
| 12 | Should slot 3 be "raised BP" or "referred" in India? NP-NCD reports referred, which may include people referred for other reasons. | India program team | No |
| 13 | Should the facility step be named the same everywhere (for example "Seen at clinic") with the local term in the info icon? | HEARTS360 team | No |
