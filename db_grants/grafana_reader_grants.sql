-- grafana_reader grants on Grafana's own tables (AD-14, ASSUMPTION A60).
-- Grafana creates grafana_schema tables at its first start, after the init scripts ran, so these
-- grants cannot live in a migration. db_grants/apply.sh runs this file as the superuser on every
-- `docker compose up`. Idempotent: it resets grafana_reader to exactly these column grants.
BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader') THEN
        RAISE EXCEPTION 'role grafana_reader is missing; apply migration 0.6.5_to_0.6.6 first';
    END IF;
    IF to_regclass('grafana_schema."user"') IS NULL
       OR to_regclass('grafana_schema.team') IS NULL
       OR to_regclass('grafana_schema.team_member') IS NULL THEN
        RAISE EXCEPTION 'grafana_schema tables are missing; start Grafana first';
    END IF;
END $$;

GRANT USAGE ON SCHEMA grafana_schema TO grafana_reader;

-- Revoking a table privilege also revokes every column privilege on that table.
REVOKE ALL ON ALL TABLES    IN SCHEMA grafana_schema FROM grafana_reader;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA grafana_schema FROM grafana_reader;
REVOKE ALL ON ALL ROUTINES  IN SCHEMA grafana_schema FROM grafana_reader;

-- Only what the isAdmin / isAllowed / home-redirect queries and get_user_visible_org_units read.
-- Never password, salt, rands, email or any other column.
GRANT SELECT (id, login, is_admin, org_id) ON grafana_schema."user"      TO grafana_reader;
GRANT SELECT (id, name, org_id)            ON grafana_schema.team        TO grafana_reader;
GRANT SELECT (user_id, team_id, org_id)    ON grafana_schema.team_member TO grafana_reader;

COMMIT;
