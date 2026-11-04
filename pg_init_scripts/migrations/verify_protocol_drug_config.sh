#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.5.1_to_0.5.2.sql"
DB_NAME="${PROTOCOL_DRUG_VERIFY_DB:-protocol_drug_config_verify}"

if [[ ! -f "$MIGRATION" ]]; then
    echo "missing migration: $MIGRATION" >&2
    exit 1
fi

drop_db() {
    sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
        "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null
}

drop_db
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 <<SQL
DROP ROLE IF EXISTS heart360tk;
CREATE ROLE heart360tk LOGIN;
CREATE DATABASE ${DB_NAME} OWNER heart360tk;
SQL

sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 <<SQL
CREATE SCHEMA heart360tk_schema AUTHORIZATION heart360tk;
SQL

echo "apply 1"
sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null

sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
DECLARE
    v_protocol TEXT;
    v_drugs INT;
    v_tracked INT;
BEGIN
    SELECT protocol_code INTO v_protocol
    FROM programme_protocols
    WHERE country_code = 'India' AND programme_code = 'IHCI';

    IF v_protocol IS DISTINCT FROM 'AATTCC' THEN
        RAISE EXCEPTION 'India/IHCI protocol_code is %, expected AATTCC', v_protocol;
    END IF;

    SELECT COUNT(*) INTO v_drugs
    FROM protocol_drugs
    WHERE country_code = 'India' AND programme_code = 'IHCI';

    IF v_drugs <> 6 THEN
        RAISE EXCEPTION 'India/IHCI drug count is %, expected 6', v_drugs;
    END IF;

    SELECT COUNT(*) INTO v_tracked
    FROM protocol_drugs
    WHERE country_code = 'India'
      AND programme_code = 'IHCI'
      AND stock_tracked
      AND (drug_name, dosage, rxnorm_code, drug_category) IN (
          ('Amlodipine', '5 mg', '329528', 'CCB'),
          ('Amlodipine', '10 mg', '329526', 'CCB'),
          ('Telmisartan', '40 mg', '316764', 'ARB'),
          ('Telmisartan', '80 mg', '316765', 'ARB'),
          ('Chlorthalidone', '12.5 mg', '331132', 'Diuretic'),
          ('Chlorthalidone', '25 mg', '197499', 'Diuretic')
      );

    IF v_tracked <> 6 THEN
        RAISE EXCEPTION 'India/IHCI tracked drug set mismatch, matched % of 6', v_tracked;
    END IF;

    IF EXISTS (
        SELECT 1 FROM protocol_drugs
        WHERE drug_category NOT IN ('CCB', 'ARB', 'Diuretic', 'Other')
    ) THEN
        RAISE EXCEPTION 'seed stored a drug_category outside {CCB, ARB, Diuretic, Other}';
    END IF;
END $$;

DO $$
BEGIN
    INSERT INTO protocol_drugs (
        country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked
    ) VALUES (
        'India', 'IHCI', 'Rejected', '1 mg', 'bad-category', 'hypertension_ccb', TRUE
    );
    RAISE EXCEPTION 'CHECK accepted drug_category hypertension_ccb';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END $$;

BEGIN;
INSERT INTO protocol_drugs (
    country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked
) VALUES (
    'India', 'IHCI', 'Other probe', '1 mg', 'other-probe', 'Other', FALSE
);
ROLLBACK;

DO $$
DECLARE
    v_active_country TEXT;
    v_active_programme TEXT;
    v_view INT;
BEGIN
    SELECT country_code, programme_code
    INTO v_active_country, v_active_programme
    FROM deploy_setting
    WHERE setting_name = 'active_programme';

    IF v_active_country IS DISTINCT FROM 'India'
       OR v_active_programme IS DISTINCT FROM 'IHCI' THEN
        RAISE EXCEPTION 'active_programme setting is %/%', v_active_country, v_active_programme;
    END IF;

    SELECT COUNT(*) INTO v_view FROM active_stock_tracked_drugs;
    IF v_view <> 6 THEN
        RAISE EXCEPTION 'active view returned % rows, expected 6', v_view;
    END IF;

    IF EXISTS (
        SELECT 1 FROM active_stock_tracked_drugs
        WHERE country_code IS DISTINCT FROM 'India'
           OR programme_code IS DISTINCT FROM 'IHCI'
           OR NOT stock_tracked
           OR drug_category NOT IN ('CCB', 'ARB', 'Diuretic', 'Other')
    ) THEN
        RAISE EXCEPTION 'active view returned a row outside India/IHCI tracked drugs';
    END IF;
END $$;

BEGIN;
INSERT INTO programme_protocols (country_code, programme_code, protocol_code)
VALUES ('Bangladesh', 'NCDC', 'ATTACC');
INSERT INTO protocol_drugs (
    country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked
) VALUES
    ('Bangladesh', 'NCDC', 'Amlodipine', '5 mg', '329528', 'CCB', TRUE),
    ('India', 'IHCI', 'Untracked', '1 mg', 'untracked-probe', 'Other', FALSE);
UPDATE deploy_setting
SET country_code = 'India', programme_code = 'IHCI'
WHERE setting_name = 'active_programme';
DO $$
DECLARE
    v_view INT;
    v_other INT;
    v_untracked INT;
BEGIN
    SELECT COUNT(*) INTO v_view FROM active_stock_tracked_drugs;
    SELECT COUNT(*) INTO v_other
    FROM active_stock_tracked_drugs
    WHERE country_code IS DISTINCT FROM 'India'
       OR programme_code IS DISTINCT FROM 'IHCI';
    SELECT COUNT(*) INTO v_untracked
    FROM active_stock_tracked_drugs
    WHERE rxnorm_code = 'untracked-probe';
    IF v_view <> 6 OR v_other <> 0 OR v_untracked <> 0 THEN
        RAISE EXCEPTION 'active view leaked rows: view % other % untracked %', v_view, v_other, v_untracked;
    END IF;
END $$;
UPDATE deploy_setting
SET country_code = 'Bangladesh', programme_code = 'NCDC'
WHERE setting_name = 'active_programme';
DO $$
DECLARE
    v_view INT;
    v_programme TEXT;
BEGIN
    SELECT COUNT(*), MIN(programme_code)
    INTO v_view, v_programme
    FROM active_stock_tracked_drugs;
    IF v_view <> 1 OR v_programme IS DISTINCT FROM 'NCDC' THEN
        RAISE EXCEPTION 'active view did not follow deploy_setting: % rows programme %', v_view, v_programme;
    END IF;
END $$;
ROLLBACK;

DO $$
BEGIN
    INSERT INTO programme_protocols (country_code, programme_code, protocol_code)
    VALUES ('India', 'OTHER', 'AATTH');
    RAISE EXCEPTION 'CHECK accepted protocol_code AATTH';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END $$;

BEGIN;
INSERT INTO programme_protocols (country_code, programme_code, protocol_code)
VALUES ('India', 'ATTACC-PROBE', 'ATTACC');
ROLLBACK;
SQL

echo "apply 2"
sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null

sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
DECLARE
    v_programmes INT;
    v_drugs INT;
BEGIN
    SELECT COUNT(*) INTO v_programmes FROM programme_protocols;
    SELECT COUNT(*) INTO v_drugs FROM protocol_drugs;
    IF v_programmes <> 1 OR v_drugs <> 6 THEN
        RAISE EXCEPTION 'second apply drifted to % programmes and % drugs', v_programmes, v_drugs;
    END IF;
END $$;

UPDATE protocol_drugs
SET stock_tracked = FALSE,
    drug_category = 'Other'
WHERE country_code = 'India' AND programme_code = 'IHCI' AND rxnorm_code = '329528';

UPDATE programme_protocols
SET protocol_code = 'ATTACC'
WHERE country_code = 'India' AND programme_code = 'IHCI';

INSERT INTO programme_protocols (country_code, programme_code, protocol_code)
VALUES ('Bangladesh', 'NCDC', 'ATTACC');

INSERT INTO protocol_drugs (
    country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked
) VALUES (
    'Bangladesh', 'NCDC', 'Amlodipine', '5 mg', '329528', 'CCB', TRUE
);

UPDATE deploy_setting
SET country_code = 'Bangladesh', programme_code = 'NCDC'
WHERE setting_name = 'active_programme';
SQL

echo "apply 3"
sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null

sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
DECLARE
    v_protocol TEXT;
    v_tracked BOOLEAN;
    v_category TEXT;
    v_active_country TEXT;
    v_active_programme TEXT;
    v_view INT;
    v_other INT;
BEGIN
    SELECT protocol_code INTO v_protocol
    FROM programme_protocols
    WHERE country_code = 'India' AND programme_code = 'IHCI';

    SELECT stock_tracked INTO v_tracked
    FROM protocol_drugs
    WHERE country_code = 'India' AND programme_code = 'IHCI' AND rxnorm_code = '329528';

    SELECT drug_category INTO v_category
    FROM protocol_drugs
    WHERE country_code = 'India' AND programme_code = 'IHCI' AND rxnorm_code = '329528';

    SELECT country_code, programme_code
    INTO v_active_country, v_active_programme
    FROM deploy_setting
    WHERE setting_name = 'active_programme';

    SELECT COUNT(*) INTO v_view FROM active_stock_tracked_drugs;
    SELECT COUNT(*) INTO v_other
    FROM active_stock_tracked_drugs
    WHERE country_code IS DISTINCT FROM 'India'
       OR programme_code IS DISTINCT FROM 'IHCI';

    IF v_protocol IS DISTINCT FROM 'AATTCC'
       OR v_tracked IS DISTINCT FROM TRUE
       OR v_category IS DISTINCT FROM 'CCB'
       OR v_active_country IS DISTINCT FROM 'India'
       OR v_active_programme IS DISTINCT FROM 'IHCI'
       OR v_view <> 6
       OR v_other <> 0 THEN
        RAISE EXCEPTION
            're-seed did not converge: protocol % tracked % category % active %/% view % other %',
            v_protocol, v_tracked, v_category, v_active_country, v_active_programme, v_view, v_other;
    END IF;
END $$;
SQL

drop_db
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
    "CREATE DATABASE ${DB_NAME} OWNER heart360tk;" >/dev/null
sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c \
    "CREATE SCHEMA heart360tk_schema AUTHORIZATION heart360tk;" >/dev/null

INCLUDE_DIR="$(mktemp -d)"
chmod 755 "$INCLUDE_DIR"
cat > "$INCLUDE_DIR/01_include.sql" <<EOF
\\ir $MIGRATION
EOF
chmod 644 "$INCLUDE_DIR/01_include.sql"
echo "apply via \\ir"
sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$INCLUDE_DIR/01_include.sql" >/dev/null
rm -rf "$INCLUDE_DIR"

if ! grep -q '\\ir migrations/0.5.1_to_0.5.2.sql' "$ROOT/pg_init_scripts/01_heart360_tables.sql"; then
    echo "01_heart360_tables.sql does not include the migration" >&2
    exit 1
fi

INCLUDED="$(sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -c \
"SELECT p.country_code || '/' || p.programme_code || ' ' || p.protocol_code || ' drugs=' || (SELECT COUNT(*)::text FROM heart360tk_schema.protocol_drugs) || ' active=' || (SELECT COUNT(*)::text FROM heart360tk_schema.active_stock_tracked_drugs) || ' setting=' || s.country_code || '/' || s.programme_code FROM heart360tk_schema.programme_protocols p JOIN heart360tk_schema.deploy_setting s ON s.setting_name = 'active_programme';")"
if [[ "$INCLUDED" != "India/IHCI AATTCC drugs=6 active=6 setting=India/IHCI" ]]; then
    echo "\\ir path produced '$INCLUDED'" >&2
    exit 1
fi

drop_db
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS heart360tk;" >/dev/null

echo "protocol drug config verified"
