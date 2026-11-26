-- Demo-only screening figures for the Screening-to-treatment cascade.
-- Treatment rows still come from live registered / under care / controlled.
CREATE TABLE IF NOT EXISTS heart360tk_schema.demo_screening_cascade (
  id integer PRIMARY KEY,
  eligible_adults integer NOT NULL,
  screened_adults integer NOT NULL,
  suspected_htn integer NOT NULL,
  screening_target_pct integer NOT NULL
);
INSERT INTO heart360tk_schema.demo_screening_cascade (
  id, eligible_adults, screened_adults, suspected_htn, screening_target_pct
) VALUES (1, 30500, 14030, 7320, 46)
ON CONFLICT (id) DO UPDATE SET
  eligible_adults = EXCLUDED.eligible_adults,
  screened_adults = EXCLUDED.screened_adults,
  suspected_htn = EXCLUDED.suspected_htn,
  screening_target_pct = EXCLUDED.screening_target_pct;
GRANT SELECT ON heart360tk_schema.demo_screening_cascade TO heart360tk;
GRANT SELECT ON heart360tk_schema.demo_screening_cascade TO heart360tk_cached;
