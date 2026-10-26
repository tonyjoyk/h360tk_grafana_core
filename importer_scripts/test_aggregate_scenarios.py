"""Scenario checks for direct EHR aggregate JSON.

Run inside the importer image, against the central Postgres:

    python3 test_aggregate_scenarios.py
"""

import os
import sys

import psycopg2

from psycopg2 import sql

from import_versions.aggregate_json import _chain_for_create, import_aggregate_json_file

DB = {
    'host': os.getenv('POSTGRES_HOST', 'postgres'),
    'database': os.getenv('POSTGRES_DB', 'heart360tk_database'),
    'user': os.getenv('POSTGRES_USER', 'heart360tk'),
    'password': os.getenv('POSTGRES_PASSWORD', ''),
}

FIXTURES = os.getenv('FIXTURE_DIR', '/fixtures')


def load(conn, name):
    return import_aggregate_json_file(conn, os.path.join(FIXTURES, name))


def one(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        row = cur.fetchone()
        return None if row is None else row[0]


def row(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def check(name, ok, detail):
    print(f'{"PASS" if ok else "FAIL"} {name}: {detail}')
    return ok


TABLES = (
    'heart360_patients_category',
    'heart360_patients_registered',
    'heart360_patients_under_care',
    'heart360_blood_sugar_controlled',
    'heart360_blood_sugar_severity',
    'heart360_blood_sugar_missed_visits',
    'heart360_dm_bp_control',
    'heart360_dm_patients_under_care',
    'heart360_dm_patients_catagory',
)


def reset(conn):
    with conn.cursor() as cur:
        for table in TABLES:
            cur.execute(
                sql.SQL(
                    'DELETE FROM heart360tk_reporting.{} '
                    'WHERE org_unit_id IN (1, 3) AND ref_month >= DATE %s'
                ).format(sql.Identifier(table)),
                ('2026-07-01',),
            )
        cur.execute(
            '''
            DELETE FROM heart360tk_reporting.external_aggregate_rejection_log
            WHERE source_key IN (
                'scenario-ehr', 'demo-ehr', 'source-ehr-a', 'source-ehr-b'
            )
            '''
        )


def scenario_counts_only(conn):
    load(conn, 'counts_only.json')
    values = row(
        conn,
        '''
        SELECT nb_patients_controlled, nb_patients_uncontrolled, nb_patients_no_visit,
               total_number_of_patients
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 3 AND ref_month = DATE '2026-09-01'
        ''',
    )
    return check(
        'counts only, no invented denominator',
        values == (40, 20, 10, None),
        values,
    )


def scenario_gap(conn):
    load(conn, 'visit_without_bp.json')
    values = row(
        conn,
        '''
        SELECT nb_patients_controlled, nb_patients_uncontrolled, nb_patients_no_visit,
               nb_patients_visit_no_bp, total_number_of_patients,
               nb_patients_newly_registered, nb_patients_lost_to_follow_up,
               round(100.00 * nb_patients_controlled / NULLIF(GREATEST(0,
                   total_number_of_patients - nb_patients_newly_registered
                   - nb_patients_lost_to_follow_up), 0), 2),
               round(100.00 * nb_patients_uncontrolled / NULLIF(GREATEST(0,
                   total_number_of_patients - nb_patients_newly_registered
                   - nb_patients_lost_to_follow_up), 0), 2),
               round(100.00 * nb_patients_no_visit / NULLIF(GREATEST(0,
                   total_number_of_patients - nb_patients_newly_registered
                   - nb_patients_lost_to_follow_up), 0), 2)
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 3 AND ref_month = DATE '2026-09-01'
        ''',
    )
    return check(
        'percents stay 50, 30, 10 when 10 visits have no BP',
        values == (50, 30, 10, 10, 120, 10, 10, 50, 30, 10),
        values,
    )


def scenario_registrations(conn):
    load(conn, 'registrations_by_month.json')
    values = row(
        conn,
        '''
        SELECT string_agg(pr.nb_new_patients::text, ',' ORDER BY pr.ref_month),
               string_agg(uc.nb_patients_under_care::text, ',' ORDER BY pr.ref_month)
        FROM heart360tk_reporting.heart360_patients_registered pr
        JOIN heart360tk_reporting.heart360_patients_under_care uc
          ON uc.org_unit_id = pr.org_unit_id AND uc.ref_month = pr.ref_month
        WHERE pr.org_unit_id = 3
          AND pr.ref_month BETWEEN DATE '2026-07-01' AND DATE '2026-09-01'
        ''',
    )
    return check(
        'three months of new registrations and under care',
        values == ('5,7,8', '70,80,90'),
        values,
    )


def scenario_diabetes(conn):
    load(conn, 'diabetes.json')
    values = row(
        conn,
        '''
        SELECT c.diabetes_controlled, c.diabetes_patients_under_care,
               s.uncontrolled_moderate, s.uncontrolled_high, s.diabetes_patients_under_care,
               m.missed_visit, m.diabetes_patients_under_care,
               b.bp_controlled_140_90, b.bp_controlled_130_80, b.dm_patients_under_care,
               u.nb_dm_patients_under_care, u.nb_new_dm_patients,
               d.total_number_of_patients, d.nb_patients_lost_to_follow_up
        FROM heart360tk_reporting.heart360_blood_sugar_controlled c
        JOIN heart360tk_reporting.heart360_blood_sugar_severity s
          ON s.org_unit_id = c.org_unit_id AND s.ref_month = c.ref_month
        JOIN heart360tk_reporting.heart360_blood_sugar_missed_visits m
          ON m.org_unit_id = c.org_unit_id AND m.ref_month = c.ref_month
        JOIN heart360tk_reporting.heart360_dm_bp_control b
          ON b.org_unit_id = c.org_unit_id AND b.ref_month = c.ref_month
        JOIN heart360tk_reporting.heart360_dm_patients_under_care u
          ON u.org_unit_id = c.org_unit_id AND u.ref_month = c.ref_month
        JOIN heart360tk_reporting.heart360_dm_patients_catagory d
          ON d.org_unit_id = c.org_unit_id AND d.ref_month = c.ref_month
        WHERE c.org_unit_id = 3 AND c.ref_month = DATE '2026-09-01'
        ''',
    )
    expected = (40, 80, 15, 5, 80, 10, 80, 24, 12, 80, 80, 6, 100, 8)
    return check('diabetes counts land on each dashboard table', values == expected, values)


def scenario_partial(conn):
    load(conn, 'partial_reject.json')
    kept = one(
        conn,
        '''
        SELECT nb_patients_controlled
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 3 AND ref_month = DATE '2026-09-01'
        ''',
    )
    reason = one(
        conn,
        '''
        SELECT reason FROM heart360tk_reporting.external_aggregate_rejection_log
        WHERE submission_id = 'partial_reject'
        ORDER BY entry_index
        LIMIT 1
        ''',
    )
    created = one(
        conn,
        '''
        SELECT nb_patients_controlled
        FROM heart360tk_reporting.heart360_patients_category c
        JOIN heart360tk_schema.org_units ou ON ou.id = c.org_unit_id
        WHERE ou.name = 'JSON Partial Clinic' AND c.ref_month = DATE '2026-09-01'
        ''',
    )
    return check(
        'a clinic with a display name is created and a row with no display is skipped',
        kept == 11
        and created == 4
        and reason
        and 'orgUnit.display is required to create a clinic' in reason,
        (kept, created, reason),
    )


def scenario_percent_ignored(conn):
    load(conn, 'percent_sent.json')
    stored = one(
        conn,
        '''
        SELECT nb_patients_controlled
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 3 AND ref_month = DATE '2026-09-01'
        ''',
    )
    reason = one(
        conn,
        '''
        SELECT reason FROM heart360tk_reporting.external_aggregate_rejection_log
        WHERE submission_id = 'percent_sent'
        ''',
    )
    return check(
        'a percentage is ignored and the count is kept',
        stored == 33 and reason and 'percentage' in reason,
        (stored, reason),
    )


def scenario_correction(conn):
    load(conn, 'correction_first.json')
    first = one(
        conn,
        '''
        SELECT nb_patients_controlled
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 3 AND ref_month = DATE '2026-09-01'
        ''',
    )
    load(conn, 'correction_second.json')
    second = one(
        conn,
        '''
        SELECT nb_patients_controlled
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 3 AND ref_month = DATE '2026-09-01'
        ''',
    )
    return check('a corrected file replaces 120 with 100', first == 120 and second == 100, (first, second))


def scenario_negative(conn):
    load(conn, 'negative_value.json')
    stored = row(
        conn,
        '''
        SELECT nb_patients_controlled, nb_patients_uncontrolled
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 3 AND ref_month = DATE '2026-09-01'
        ''',
    )
    return check(
        'a negative count is ignored and the valid count remains',
        stored == (9, None),
        stored,
    )


def scenario_chain_helpers(conn):
    names, levels, error = _chain_for_create('infokes', {'display': 'Clinic A'})
    named_parents = _chain_for_create(
        'infokes',
        {
            'display': 'Clinic A',
            'level': 3,
            'parents': [
                {'display': 'Central', 'level': 1},
                {'name': 'South', 'level': 2},
            ],
        },
    )
    return check(
        'missing parents become source-scoped unknown ancestors',
        error is None
        and names == ['UNKNOWN (infokes)', 'UNKNOWN (infokes)', 'Clinic A']
        and levels == [1, 2, 3]
        and named_parents[0] == ['Central', 'South', 'Clinic A']
        and named_parents[1] == [1, 2, 3]
        and named_parents[2] is None,
        (names, levels, error, named_parents),
    )


def _org_unit_row(conn, name):
    return row(
        conn,
        '''
        SELECT id, level, parent_id
        FROM heart360tk_schema.org_units
        WHERE name = %s
        ORDER BY id
        LIMIT 1
        ''',
        (name,),
    )


def scenario_create_with_parents(conn):
    load(conn, 'create_with_parents.json')
    clinic = _org_unit_row(conn, 'JSON Create Clinic')
    district = _org_unit_row(conn, 'JSON Create District')
    region = _org_unit_row(conn, 'JSON Create Region')
    stored = one(
        conn,
        '''
        SELECT nb_patients_controlled
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = %s AND ref_month = DATE '2026-09-01'
        ''',
        (clinic[0] if clinic else None,),
    )
    mapped = one(
        conn,
        '''
        SELECT central_org_unit_id
        FROM heart360tk_reporting.external_org_unit_mapping
        WHERE source_key = 'scenario-ehr' AND external_code = 'JSON-CREATE-CLINIC'
        ''',
    )
    return check(
        'a new clinic is created under the parents in the file',
        clinic is not None
        and district is not None
        and region is not None
        and region[1] == 1
        and region[2] is None
        and district[1] == 2
        and district[2] == region[0]
        and clinic[1] == 3
        and clinic[2] == district[0]
        and stored == 17
        and mapped == clinic[0],
        (clinic, district, region, stored, mapped),
    )


def scenario_create_without_parents(conn):
    load(conn, 'create_without_parents.json')
    clinic = _org_unit_row(conn, 'JSON Fallback Clinic')
    parent = row(
        conn,
        '''
        SELECT id, name, level, parent_id
        FROM heart360tk_schema.org_units
        WHERE id = %s
        ''',
        (clinic[2] if clinic else None,),
    )
    region = row(
        conn,
        '''
        SELECT id, name, level, parent_id
        FROM heart360tk_schema.org_units
        WHERE id = %s
        ''',
        (parent[3] if parent else None,),
    )
    stored = one(
        conn,
        '''
        SELECT nb_patients_controlled
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = %s AND ref_month = DATE '2026-09-01'
        ''',
        (clinic[0] if clinic else None,),
    )
    return check(
        'a new clinic without parents sits under UNKNOWN (source_key)',
        clinic is not None
        and clinic[1] == 3
        and parent is not None
        and parent[1] == 'UNKNOWN (scenario-ehr)'
        and parent[2] == 2
        and region is not None
        and region[1] == 'UNKNOWN (scenario-ehr)'
        and region[2] == 1
        and region[3] is None
        and stored == 9,
        (clinic, parent, region, stored),
    )


def scenario_create_two_sources(conn):
    load(conn, 'create_source_a.json')
    load(conn, 'create_source_b.json')
    region_a = one(
        conn,
        '''
        SELECT COUNT(*) FROM heart360tk_schema.org_units
        WHERE name = 'UNKNOWN (source-ehr-a)' AND level = 1 AND parent_id IS NULL
        ''',
    )
    region_b = one(
        conn,
        '''
        SELECT COUNT(*) FROM heart360tk_schema.org_units
        WHERE name = 'UNKNOWN (source-ehr-b)' AND level = 1 AND parent_id IS NULL
        ''',
    )
    clinic_a = _org_unit_row(conn, 'Source A Clinic')
    clinic_b = _org_unit_row(conn, 'Source B Clinic')
    return check(
        'two EHRs get separate unknown regions',
        region_a == 1
        and region_b == 1
        and clinic_a is not None
        and clinic_b is not None
        and clinic_a[0] != clinic_b[0]
        and clinic_a[2] != clinic_b[2],
        (region_a, region_b, clinic_a, clinic_b),
    )


def scenario_create_idempotent(conn):
    load(conn, 'create_with_parents.json')
    first = _org_unit_row(conn, 'JSON Create Clinic')
    load(conn, 'create_with_parents.json')
    second = _org_unit_row(conn, 'JSON Create Clinic')
    copies = one(
        conn,
        '''
        SELECT COUNT(*) FROM heart360tk_schema.org_units
        WHERE name = 'JSON Create Clinic'
        ''',
    )
    return check(
        'replaying the same JSON file keeps one clinic id',
        first is not None and first == second and copies == 1,
        (first, second, copies),
    )


def scenario_old_shape(conn):
    load(conn, 'legacy_extensions.json')
    values = row(
        conn,
        '''
        SELECT nb_patients_controlled, nb_patients_under_care, total_number_of_patients,
               nb_patients_newly_registered, nb_patients_lost_to_follow_up
        FROM heart360tk_reporting.heart360_patients_category
        WHERE org_unit_id = 1 AND ref_month = DATE '2026-09-01'
        ''',
    )
    return check(
        'column names fill the hypertension percent inputs',
        values == (120, 180, 203, 14, 9),
        values,
    )


SCENARIOS = [
    scenario_counts_only,
    scenario_gap,
    scenario_registrations,
    scenario_diabetes,
    scenario_partial,
    scenario_percent_ignored,
    scenario_correction,
    scenario_negative,
    scenario_old_shape,
    scenario_chain_helpers,
    scenario_create_with_parents,
    scenario_create_without_parents,
    scenario_create_two_sources,
    scenario_create_idempotent,
]


def main():
    conn = psycopg2.connect(**DB)
    conn.autocommit = False
    failed = 0
    try:
        for scenario in SCENARIOS:
            conn.rollback()
            reset(conn)
            try:
                ok = scenario(conn)
            except Exception as exc:
                conn.rollback()
                ok = check(scenario.__name__, False, exc)
            if not ok:
                failed += 1
        conn.rollback()
    finally:
        conn.close()
    print(f'{len(SCENARIOS) - failed}/{len(SCENARIOS)} scenarios passed')
    return failed


if __name__ == '__main__':
    sys.exit(main())
