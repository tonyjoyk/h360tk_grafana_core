WITH me AS (
  SELECT u.id, u.is_admin FROM "user" u WHERE u.id = ${__user.id}
),
my_teams AS (
  SELECT t.name
  FROM me
  JOIN team_member tm ON tm.user_id = me.id
  JOIN team t ON tm.team_id = t.id
  WHERE NOT me.is_admin
),
specific_units AS (
  SELECT hc.level, ou.id, ou.name
  FROM my_teams mt
  JOIN heart360tk_schema.hierarchy_config hc
    ON mt.name ~ ('^heart360tk_' || hc.var_name || '_view_(patients|aggregated)_')
    AND mt.name NOT LIKE '%\_ALL' ESCAPE '\'
  JOIN heart360tk_schema.org_units ou
    ON ou.level = hc.level
    AND regexp_replace(lower(trim(ou.name)), '\s+', '_', 'g') =
        regexp_replace(mt.name, '^heart360tk_' || hc.var_name || '_view_(patients|aggregated)_', '')
),
all_access_level AS (
  SELECT MIN(hc.level) AS level
  FROM my_teams mt
  JOIN heart360tk_schema.hierarchy_config hc
    ON mt.name IN ('heart360tk_' || hc.var_name || '_view_patients_ALL',
                   'heart360tk_' || hc.var_name || '_view_aggregated_ALL')
),
all_access_units AS (
  SELECT ou.level, ou.id, ou.name
  FROM all_access_level al
  JOIN heart360tk_schema.org_units ou ON ou.level = al.level
  WHERE al.level > 1
),
candidates AS (
  SELECT * FROM specific_units
  UNION ALL
  SELECT * FROM all_access_units
)
SELECT COALESCE(
  (SELECT id::text FROM candidates ORDER BY level ASC, name ASC LIMIT 1),
  ''
)
