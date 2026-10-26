# Epics and stories: JSON org unit create

Source artifacts:

- `_bmad-output/planning-artifacts/prds/prd-h360-json-org-unit-create-2026-10-26/prd.md`
- `_bmad-output/planning-artifacts/ux-designs/ux-h360-json-org-unit-create-2026-10-26/EXPERIENCE.md`
- `_bmad-output/planning-artifacts/architecture/architecture-h360-json-org-unit-create-2026-10-26/ARCHITECTURE-SPINE.md`
- `_bmad-output/planning-artifacts/reviews/json-org-unit-create-party-mode-2026-10-26.md`

## Epic 1. JSON resolve can create an org unit

Goal. A JSON entry that names a new clinic writes `org_units` with the same unique key the ZIP path uses, then stores the counts on that clinic.

Stories.

- [x] E1-S1 Keep match-by-id and match-by-mapped-code. Ignore an id that does not exist and continue.
- [x] E1-S2 When `orgUnit.parents` is present, upsert that chain plus the clinic through `heart360tk_schema.upsert_org_unit_chain`.
- [x] E1-S3 When `parents` is omitted and `display` matches exactly one existing org unit, keep using that org unit. Do not create a parallel unknown chain.
- [x] E1-S4 When `display` is new, fill missing levels `1 .. level-1` with `UNKNOWN ({source_key})`, default `level` to 3, then upsert the chain.
- [x] E1-S5 Reject an entry that has no existing id, no mapped code, and no display. Other entries in the file still load.
- [x] E1-S6 Remember `orgUnit.code` in `external_org_unit_mapping` after create.

Exit criteria.

- New clinic with parents appears under those parents.
- New clinic without parents appears under source-scoped unknown ancestors.
- Existing unique `H360_AUDIT_PHC` fixtures still match org unit 3.
- Replay of the same file does not insert a second clinic.

## Epic 2. Prove the behaviour

Goal. Scenario tests fail if create, match, unknown-parent scoping, or rejects regress.

Stories.

- [x] E2-S1 Fixture and test: create with region and district names.
- [x] E2-S2 Fixture and test: create with facility name only. Assert `UNKNOWN ({source_key})` at levels 1 and 2.
- [x] E2-S3 Fixture and test: two source keys omit parents. Assert two unknown regions.
- [x] E2-S4 Fixture and test: import twice. Assert one clinic id.
- [x] E2-S5 Update `partial_reject` so a display name creates, and a row with no display is still skipped.
- [x] E2-S6 Run `test_aggregate_scenarios.py` in the importer image. All scenarios pass and roll back.

Exit criteria.

- The runner prints every scenario passed.
- The database is unchanged after the run.

## Epic 3. Vendor and operator docs

Goal. A vendor can send parents, and can predict the unknown-parent fallback, without reading Python.

Stories.

- [x] E3-S1 Update `docs/ehr-aggregate-indicator-requirements.md` facility rules.
- [x] E3-S2 Update `docs/ehr-aggregate-json-ingest-mvp.md` and the vendor checklist.
- [x] E3-S3 Replace the investigation flag with the shipped rule.
- [x] E3-S4 Update `.cursor/skills/verify-h360tk-grafana-core/features/central-aggregate-json.md`.

Exit criteria.

- Docs say match first, then create.
- Docs say missing parents become `UNKNOWN ({ehr-name})`.
- Docs say ZIP import is unchanged.

## Out of this delivery

- ZIP `import_org_units` changes.
- Clinic merge UI.
- HTTP ingest.
- Grafana dashboard JSON edits.
- Letting JSON choose `org_units.id`.
